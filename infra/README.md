# Hop production infrastructure

The runtime root in `infra/` manages the relay and public example services, load
balancer, DNS, certificates, observability, and the BigQuery usage dataset. The
administrator-only root in `infra/bootstrap/` manages APIs, IAM, service accounts,
secrets, Workload Identity Federation, Firestore policy, and Artifact Registry. The
isolated `infra/billing/` root manages only the Stripe catalog.

## GitHub is change management, GCP is plumbing

The only human gate on any production change is the pull request that merges it to
`main`. GitHub decides whether a change ships, what ships, and who approved it. Google
Cloud runs what GitHub blessed and verifies nothing about the change: no signing, no
second approval, no provenance re-check. Every apply is keyless (GitHub OIDC exchanged
for short-lived credentials through Workload Identity Federation), so there are no
service-account keys to store or rotate.

Each root is applied by exactly one GitHub Actions workflow:

| Root | Workflow | Trigger |
| --- | --- | --- |
| `infra/bootstrap` | `.github/workflows/bootstrap-apply.yml` | manual dispatch, `confirm=apply` |
| `infra/` (runtime) | `.github/workflows/runtime-deploy.yml` | automatic on merge to `main` after CI is green |
| `infra/billing` | `.github/workflows/billing-catalog.yml` | manual dispatch, `confirm=apply` |

A local `tofu apply` against any of these is a destroy operation whenever the checkout
is behind: everything in remote state but absent from the local files is planned for
deletion, and bootstrap owns IAM, service accounts, and secrets. `prevent_destroy` does
not save you there, it only strands the root half applied. Always apply through the
workflow, where the input is a reviewed commit rather than whatever you last pulled.

## Runtime deployment

A merge to `main` runs the `CI` workflow. When CI COMPLETES SUCCESSFULLY on that push,
`runtime-deploy.yml` fires. It authenticates as `hop-deploy` over WIF, builds and pushes
the `hop-relayd`, `hop-example`, `hop-accountd`, and `hop-console` images tagged with the
full source SHA, resolves each pushed tag to an immutable `@sha256` digest, and runs
`tofu apply` on the runtime root with digest-only image references. All four runtime image
variables reject anything that is not an `@sha256` reference.

Before doing any of that, a supersession guard reads the current `main` tip with
`git ls-remote`. If a newer commit already landed, the run SKIPS every remaining step
(the job still succeeds and applies nothing) so a stale build cannot overwrite a newer
tree. The `runtime-deploy` concurrency group serializes deploys so two quick merges
cannot apply at once.

## Branch protection

GitHub branch protection on `main` requires the single `CI gate` context. That aggregate
job depends on the change detector and every internal CI job, runs with `if: always()`,
fails when any needed job fails or is cancelled, and accepts jobs skipped by a path
filter. Using one live required context prevents an unrelated path-filtered job from
remaining pending forever. `tools/check-required-checks.sh` keeps that aggregate honest
(it must depend on every job and fail closed); `tools/check-branch-protection.sh` asserts
the live rule requires exactly the `CI gate` context. CI going green on `main` is the
deploy signal, so there is no separate GCP-side job allowlist to keep in sync.

## Service-account grants

`hop-deploy` (the runtime applier, impersonated by `runtime-deploy.yml`) project roles:

- `roles/bigquery.dataEditor`
- `roles/certificatemanager.editor`
- `roles/compute.loadBalancerAdmin`
- `roles/dns.admin`
- `roles/logging.configWriter`
- `roles/logging.logWriter`
- `roles/monitoring.editor`
- `roles/run.developer`
- `roles/serviceusage.serviceUsageConsumer`

`hop-deploy` resource-scoped grants:

- `roles/artifactregistry.writer` and `roles/artifactregistry.reader` on the `hop` repository
- `roles/iam.serviceAccountUser` on `hop-relay` and `hop-example` only
- `roles/storage.objectUser` on the runtime state prefix only
- `roles/iam.workloadIdentityUser`, bound to the exact subject
  `repo:hopmesh/monorepo:ref:refs/heads/main`

`hop-deploy` has no project, service-account, or secret IAM admin, no API enablement, no
role mutation, and no read of the bootstrap or billing state. The legacy `hop-cloudbuild`
Cloud Build identity is retired: it is dropped from bootstrap management with a
`removed {}` block (`destroy = false`) and torn down out of band.

`hop-relay` project roles and secret grant:

- `roles/datastore.user`
- `roles/logging.logWriter`
- `roles/secretmanager.secretAccessor` on `hop-relay-identity`

`hop-example` project roles and secret grant:

- `roles/logging.logWriter`
- `roles/secretmanager.secretAccessor` on `hop-example-identity`

`hop-billingd` project roles and secret grant:

- `roles/datastore.viewer`
- `roles/bigquery.dataEditor`
- `roles/logging.logWriter`
- `roles/secretmanager.secretAccessor` on `stripe-api-key`

`stripe-account-key` is bootstrap-owned and has no IAM accessor until its
invoice/account service lands.

`billing-catalog-apply` has no project role and no Stripe credential. GitHub OIDC may
impersonate it only for the repository configured by `github_repository`. Its only GCP
data permission is `roles/storage.objectAdmin` under the `billing/` prefix of
`runtime_state_bucket`, enforced by an IAM condition.

The public example account has no relay seed access, Firestore role, fleet identity
permission, or ability to impersonate the relay. A project IAM deny policy blocks relay
seed version access for every principal except `hop-relay`.

`bootstrap-apply` (impersonated by `bootstrap-apply.yml`) is a project IAM administrator,
which is what applying that root requires. Its project roles are
`serviceusage.serviceUsageAdmin`, `iam.serviceAccountAdmin`,
`resourcemanager.projectIamAdmin`, `iam.roleAdmin`, `iam.denyAdmin`,
`iam.workloadIdentityPoolAdmin`, `artifactregistry.admin`, `datastore.owner`, plus the
custom `hopBootstrapApplySecrets` role (secret container create/update/get/list/IAM, no
version access, no delete). Its only storage grant is `roles/storage.objectAdmin`
conditioned to the `bootstrap/` state prefix. It is bound to a single exact OIDC subject,
`repo:hopmesh/monorepo:ref:refs/heads/main`, so a pull request ref mints no credentials.
It is kept entirely separate from `hop-deploy`, which gains no permission from that root.

## Required external configuration

Bootstrap intentionally fails at plan time when the required identifiers or resource
names are absent. Populate `infra/bootstrap/terraform.tfvars` from the example, and store
the same contents in the `BOOTSTRAP_TFVARS` repository secret, which is what the apply
workflow writes to `ci.auto.tfvars` at run time. Keep the two in step; the secret is the
one the applies actually use.

Required inputs and resources:

1. A versioned GCS state bucket named by `runtime_state_bucket`. The current backend uses
   `hop-mesh-tfstate`, with `bootstrap`, `relay-fleet`, and `billing` prefixes.
2. Numeric versions for both identity secrets. The relay seed must be exactly 32 random
   bytes. The example identity must match the committed public address.
3. A non-empty `deployment_environment`.
4. The `github-actions` Workload Identity Federation pool and its `github` provider,
   scoped to `github_repository`. These plus the three applier service accounts and their
   OIDC bindings are the one-time owner seed below.
5. Repository variables, populated exactly from the reviewed bootstrap outputs:
   - `GCP_RUNTIME_WIF_PROVIDER` / `GCP_RUNTIME_SERVICE_ACCOUNT` from
     `runtime_wif_provider` / `runtime_wif_service_account`.
   - `GCP_BOOTSTRAP_WIF_PROVIDER` / `GCP_BOOTSTRAP_SERVICE_ACCOUNT` from
     `bootstrap_wif_provider` / `bootstrap_wif_service_account`.
   - `GCP_BILLING_WIF_PROVIDER` / `GCP_BILLING_SERVICE_ACCOUNT` from
     `github_wif_provider` / `github_wif_service_account`.
   Until the runtime pair is set, `runtime-deploy.yml` stays neutral and applies nothing.
6. The `BOOTSTRAP_TFVARS` repository secret.
7. GitHub branch protection on `main`, requiring pull requests, an up-to-date branch, and
   exactly the aggregate `CI gate` status context.

## Applying bootstrap

Bootstrap is applied by manual dispatch of `.github/workflows/bootstrap-apply.yml`, never
from a terminal:

```sh
gh workflow run bootstrap-apply.yml --ref main -f confirm=plan   # review the plan in the run log
gh workflow run bootstrap-apply.yml --ref main -f confirm=seed   # one-time state imports, then plan
gh workflow run bootstrap-apply.yml --ref main -f confirm=apply  # apply the reviewed bytes
```

`--ref main` is enforced, not a convention: `bootstrap-apply` is bound to the single OIDC
subject `repo:hopmesh/monorepo:ref:refs/heads/main`. A dispatch from any other branch, or
from a pull request, mints no credentials. Both the plan and apply jobs run from `main`;
the apply is gated by the manual `confirm=apply`, not by a GitHub environment. The pull
request path of the workflow is deliberately credential free: `fmt`, `validate`, and the
authority guards only.

## The one-time owner seed (gcloud + gh, never a local tofu apply)

Federation cannot bootstrap itself. The WIF pool, its GitHub OIDC provider, and the three
service accounts a workflow authenticates as (`bootstrap-apply`, `hop-deploy`,
`billing-catalog-apply`) plus their OIDC bindings and repository variables must exist
before any workflow can apply. There is no KMS key, deploy-control bucket, Pub/Sub topic,
or approver group in the seed: those were part of the deleted GCP-side deploy trust
apparatus.

Create the pool, provider, and applier identities with an administrator credential, bind
the exact OIDC subjects (`repo:hopmesh/monorepo:ref:refs/heads/main` for bootstrap-apply
and hop-deploy; the repository attribute for billing-catalog-apply), then run
`bootstrap-apply.yml -f confirm=seed` to import the create-only resources (the pool, the
provider, the `bootstrap-apply` service account, and the `hopBootstrapApplySecrets` role)
into state, review the plan, and dispatch `confirm=apply`. The apply job prints all six
WIF outputs in its final step; wire them into the repository variables:

```sh
gh variable set GCP_RUNTIME_WIF_PROVIDER      --repo hopmesh/monorepo --body "<runtime_wif_provider>"
gh variable set GCP_RUNTIME_SERVICE_ACCOUNT   --repo hopmesh/monorepo --body "<runtime_wif_service_account>"
gh variable set GCP_BOOTSTRAP_WIF_PROVIDER    --repo hopmesh/monorepo --body "<bootstrap_wif_provider>"
gh variable set GCP_BOOTSTRAP_SERVICE_ACCOUNT --repo hopmesh/monorepo --body "<bootstrap_wif_service_account>"
gh variable set GCP_BILLING_WIF_PROVIDER      --repo hopmesh/monorepo --body "<github_wif_provider>"
gh variable set GCP_BILLING_SERVICE_ACCOUNT   --repo hopmesh/monorepo --body "<github_wif_service_account>"
```

## Verification

```sh
tofu -chdir=infra fmt -check -recursive
tofu -chdir=infra init -backend=false -input=false
tofu -chdir=infra validate
tofu -chdir=infra/bootstrap init -backend=false -input=false
tofu -chdir=infra/bootstrap validate
tofu -chdir=infra/billing init -backend=false -input=false
tofu -chdir=infra/billing validate
bash tools/infra-authority-guard.test.sh
python3 tools/infra-authority-guard.py
bash tools/executable-reference-guard.test.sh
python3 tools/executable-reference-guard.py
actionlint .github/workflows/runtime-deploy.yml .github/workflows/bootstrap-apply.yml
bash tools/check-required-checks.test.sh
bash tools/check-required-checks.sh
```
