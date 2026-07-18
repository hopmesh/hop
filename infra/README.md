# Hop production infrastructure

The runtime root in `infra/` manages the relay and public example services, load
balancer, DNS, certificates, observability, and runtime datasets. The
administrator-only root in `infra/bootstrap/` manages APIs, IAM, service accounts,
secrets, Workload Identity Federation, Firestore policy, Artifact Registry,
provenance resources, and trusted Cloud Build triggers. The isolated
`infra/billing/` root manages only the Stripe catalog.

## Trusted deployment architecture

The active source trigger is `hop-source-build`. Its build definition is stored
inline in the already-applied Cloud Build trigger. It does not load
`infra/cloudbuild.trigger.yaml` or any other build script from the candidate
checkout. The checked-in YAML file is a fail-closed retired sentinel.

The source trigger runs as `hop-cloudbuild`. Candidate Dockerfiles execute only
under this low-privilege identity. Two images are built and pushed with the full
40-character source SHA. No `latest` or short-SHA tag is published.

The trusted inline source definition performs these steps:

1. Prove the effective build identity has no administrative, runtime-secret,
   service-account-token, source-repository-token, or broad storage authority.
2. Build the relay and example images under the source-build identity.
3. Query GitHub by numeric repository and workflow id for the exact source SHA.
4. Verify a `push` run on canonical `main`, the current run attempt, exact workflow
   path and bootstrap-owned content digest, exact job set, repository identity, and
   the GitHub Actions App id.
5. Resolve both pushed tags to immutable `sha256:` digests.
6. Archive only the runtime Terraform root, excluding `infra/bootstrap`.
7. Create a canonical provenance manifest containing source SHA, image tags and
   digests, repository id, builder identity, Cloud Build id, environment, runtime
   archive hash, and KMS key version.
8. Sign the manifest with the bootstrap KMS key and create immutable provenance
   objects in the control bucket.
9. Publish a wake-up message to the deployment topic.

The message is not trusted. `hop-runtime-deploy` is a separate inline Pub/Sub
trigger running as `hop-deploy`. It also requires control-plane approval from the
configured approver group. After approval it independently validates GitHub CI,
the source Build record, source trigger id, builder identity, signed manifest,
archive hash, image digests, bootstrap contract, and canonical `main`. It also
downloads GitHub's tarball for the exact gated SHA and requires every runtime
archive path and byte to match that source tree. Before OpenTofu starts, it also
rejects provider or backend credential endpoints, untrusted executable resources,
and any Cloud Run image or identity not bound to the signed deployment inputs.

Only then does it extract the runtime archive and invoke OpenTofu with digest-only
image references. The deployment trigger never runs bootstrap. The runtime deploy
identity has no permission to change project IAM, service-account IAM, custom
roles, secret IAM, APIs, Cloud Build triggers, or the bootstrap state.

The authenticated deploy-provenance job set currently requires these exact jobs
from `.github/workflows/ci.yml`:

- `Detect changed areas`
- `Rust (test · clippy · fmt)`
- `Kotlin SDK tests (BearerManager)`
- `Android bearers + driver (JVM unit tests)`
- `Apple bearers + driver + app (build-only)`
- `WASM sim (wasm32 build + swarm invariants)`
- `Web + sim (Astro build · scenario-check · link check)`
- `Contract purity + header drift + C smoke`
- `Terraform (fmt · validate · plan)`
- `Automation authority guards`
- `Docs token guard (banned copy)`
- `Node endpoint SDK (proofs)`
- `Python endpoint SDK (proofs)`
- `Go endpoint SDK (race)`
- `Ruby endpoint SDK (proofs)`
- `Crystal endpoint SDK (spec)`
- `Elixir endpoint SDK (mix test)`
- `CI gate`

This is intentionally separate from branch protection. GitHub branch protection
on `main` requires the single `CI gate` context. That aggregate job depends on the
change detector and every internal CI job, runs with `if: always()`, fails when any
needed job fails or is cancelled, and accepts jobs skipped by a path filter. Using
one live required context prevents an unrelated path-filtered job from remaining
pending forever.

The deploy path does not trust that display context by itself. Both inline triggers
authenticate the numeric repository, workflow id and path, GitHub Actions App id,
canonical `main` ref, source SHA, bootstrap-owned workflow digest, current run
attempt, and the complete job set above. `tools/check-required-checks.sh` keeps the
aggregate branch-protection contract and this deploy-provenance contract synchronized
independently.

## Global deployment lease

The deployer atomically creates `leases/global.json` in the versioned control
bucket with `ifGenerationMatch=0`. This lease is separate from the GCS OpenTofu
state lock. It records the deploy build id, source SHA, manifest digest,
acquisition time, and expiry.

After acquiring the lease, the trigger re-reads canonical `main`. It repeats that
check immediately before apply, verifies lease ownership, and renews the lease.
An older delayed build therefore fails once a newer SHA is canonical. A live lease
causes bounded contention. An expired lease is removed only with an exact GCS
generation precondition. Malformed abandoned leases become recoverable after the
same bounded TTL. Every acquire, contention, renewal, recovery, and release emits
a structured Cloud Build log, and bucket versioning retains prior lease objects.

The apply step is allowed to fail so the trusted release step still runs. A final
trusted step restores the failed build verdict. A build-level timeout can still
leave a lease, but it expires within the configured bound and is recovered with an
audited generation check.

## Service-account grants

`hop-cloudbuild` project roles:

- `roles/logging.logWriter`

`hop-cloudbuild` resource-scoped grants:

- `roles/artifactregistry.writer` on the `hop` repository
- `roles/cloudkms.signerVerifier` on the provenance key
- `roles/secretmanager.secretAccessor` on `hop-ci-readtoken` only
- `roles/pubsub.publisher` on `hop-deploy-requests`
- `roles/storage.objectCreator` on the control bucket's `provenance/` prefix

`hop-deploy` project roles:

- `roles/certificatemanager.editor`
- `roles/cloudbuild.builds.viewer`
- `roles/compute.loadBalancerAdmin`
- `roles/dns.admin`
- `roles/logging.configWriter`
- `roles/logging.logWriter`
- `roles/monitoring.editor`
- `roles/run.developer`
- `roles/serviceusage.serviceUsageConsumer`

`hop-deploy` resource-scoped grants:

- `roles/artifactregistry.reader` on the `hop` repository
- `roles/cloudkms.publicKeyViewer` on the provenance key
- `roles/secretmanager.secretAccessor` on `hop-ci-readtoken` only
- `roles/storage.objectViewer` on the bootstrap contract and provenance objects
- `roles/storage.objectUser` on the single global lease object
- `roles/storage.objectUser` on the runtime state prefix only
- `roles/iam.serviceAccountUser` on `hop-relay` and `hop-example` only

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

`billing-catalog-apply` has no project role and no Stripe credential. GitHub OIDC
may impersonate it only for the repository configured by `github_repository`. Its
only GCP data permission is `roles/storage.objectAdmin` under the `billing/` prefix
of `runtime_state_bucket`, enforced by an IAM condition.

The public example account has no relay seed access, Firestore role, fleet
identity permission, or ability to impersonate the relay. A project IAM deny
policy blocks relay seed version access for every principal except `hop-relay`.

Neither build identity has `Editor`, `Owner`, Project IAM Admin, Service Account
Admin, Run Admin, Storage Admin, Secret Manager Admin, or a role-creation path.
The legacy `hopCloudBuildSecrets` role remains only so bootstrap can remove its
old `secretmanager.secrets.setIamPolicy` permission. It is not granted to either
build identity.

## Required external configuration

Bootstrap intentionally fails at plan time when the required ids or resource
names are absent. Populate `infra/bootstrap/terraform.tfvars` from the example.

Required inputs and resources:

1. A versioned GCS state bucket named by `runtime_state_bucket`. The current
   backend uses `hop-mesh-tfstate`, with `bootstrap`, `relay-fleet`, and `billing`
   prefixes.
2. A Cloud Build v2 GitHub App connection in `us-central1`. Set its connection
   name in `build_connection_name`.
3. The numeric GitHub repository id, GitHub Actions App id, CI workflow id, and the
   SHA-256 of the separately reviewed `.github/workflows/ci.yml` bytes.
4. A fine-grained GitHub token limited to `hopmesh/hop` with Actions read,
   Checks read, Contents read, and Metadata read. Add it out of band to
   `hop-ci-readtoken`, then pin its numeric version.
5. Numeric versions for both identity secrets. The relay seed must be exactly 32
   random bytes. The example identity must match the committed public address.
6. A restricted Google group for `deploy_approver_group`. Bootstrap grants that
   group `roles/cloudbuild.builds.approver`. Build and deploy service accounts must
   not belong to it.
7. A globally unique `control_bucket_name` distinct from the state bucket, a
   runtime state prefix outside the reserved `bootstrap` and `billing`
   namespaces, and a non-empty `deployment_environment`.
8. The `GCP_BILLING_WIF_PROVIDER` and `GCP_BILLING_SERVICE_ACCOUNT` GitHub
   repository variables, populated exactly from the `github_wif_provider` and
   `github_wif_service_account` bootstrap outputs after a reviewed apply.
9. GitHub branch protection on canonical `main`, requiring pull requests, an
   up-to-date branch, and exactly the aggregate `CI gate` status context.

Retrieve immutable GitHub ids with an administrator-read token:

```sh
gh api repos/hopmesh/hop --jq .id
gh api repos/hopmesh/hop/actions/workflows/ci.yml --jq .id
gh api repos/hopmesh/hop/commits/main/check-suites \
  --jq '.check_suites[] | select(.app.slug == "github-actions") | .app.id' | sort -u
shasum -a 256 .github/workflows/ci.yml
```

The workflow digest is an explicit bootstrap migration boundary. A change to
`.github/workflows/ci.yml` remains ineligible for deployment until an administrator
reviews the exact bytes, updates `github_ci_workflow_sha256` in the external bootstrap
tfvars, and manually reapplies `infra/bootstrap`. The source or runtime deployment
cannot authorize its own replacement workflow digest.

GitHub Environment required reviewers are repository settings. This Terraform
does not create or claim to create them. The enforced human gate here is Cloud
Build approval by `deploy_approver_group`. If policy also requires a GitHub
`production` environment, create its reviewer rules manually in repository
settings and audit them separately.

The bootstrap operator itself needs administrator permissions to create APIs,
service accounts, IAM and deny policy, secrets, KMS, Pub/Sub, Artifact Registry,
Firestore policy, buckets, and triggers. Do not grant those roles to either build
identity. Invoke bootstrap manually from a reviewed checkout.

## One-time billing authority migration

The billing secrets, identities, IAM grants, and GitHub WIF resources were
originally tracked by the automatically applied `relay-fleet` state. Move their
state ownership to `bootstrap` before this revision reaches `main`. Do not let a
runtime deploy or billing-catalog workflow run during the migration. The BigQuery
dataset `google_bigquery_dataset.usage` stays in runtime state.

The preferred path moves bindings between local snapshots of both remote states.
It does not call a resource API or recreate a live object. Push the destination
state first: a failure before the source push then leaves duplicate state bindings,
which are recoverable, rather than an orphaned live resource.

```sh
tofu -chdir=infra init -input=false
tofu -chdir=infra/bootstrap init -input=false

migration_dir="$(mktemp -d)"
tofu -chdir=infra state pull > "$migration_dir/runtime.tfstate"
tofu -chdir=infra/bootstrap state pull > "$migration_dir/bootstrap.tfstate"

for address in \
  google_secret_manager_secret.stripe_api_key \
  google_secret_manager_secret.stripe_account_key \
  google_service_account.billingd \
  google_secret_manager_secret_iam_member.billingd_stripe \
  google_project_iam_member.billingd_firestore_read \
  google_project_iam_member.billingd_logs \
  google_project_iam_member.billingd_bigquery \
  google_iam_workload_identity_pool.github \
  google_iam_workload_identity_pool_provider.github \
  google_service_account.billing_catalog_apply \
  google_service_account_iam_member.billing_catalog_wif \
  google_storage_bucket_iam_member.billing_catalog_state
do
  tofu -chdir=infra state mv \
    -state="$migration_dir/runtime.tfstate" \
    -state-out="$migration_dir/bootstrap.tfstate" \
    "$address" "$address"
done

tofu -chdir=infra/bootstrap state push "$migration_dir/bootstrap.tfstate"
tofu -chdir=infra state push "$migration_dir/runtime.tfstate"
```

Verify every listed address is present only in bootstrap state, then review both
plans. The runtime plan must retain `google_bigquery_dataset.usage` and show none
of the moved resources being destroyed. The bootstrap plan may update the pool
description and provider condition, and replace only the old WIF IAM membership
with the principal selected by the validated `github_repository` value. It must
not replace either secret, either service account, the pool, or the provider. Apply
bootstrap manually only after that review.

If a listed source address is absent from runtime state, do not create a second
object with the same name. Check whether the object exists in GCP. Import a live,
untracked object directly into bootstrap; otherwise let the reviewed bootstrap
apply create it. These are the import forms for the production defaults. Replace
`PROJECT_NUMBER`, project, repository, or bucket values when external bootstrap
tfvars differ.

```sh
tofu -chdir=infra/bootstrap import google_secret_manager_secret.stripe_api_key \
  projects/hop-mesh/secrets/stripe-api-key
tofu -chdir=infra/bootstrap import google_secret_manager_secret.stripe_account_key \
  projects/hop-mesh/secrets/stripe-account-key
tofu -chdir=infra/bootstrap import google_service_account.billingd \
  projects/hop-mesh/serviceAccounts/hop-billingd@hop-mesh.iam.gserviceaccount.com
tofu -chdir=infra/bootstrap import google_secret_manager_secret_iam_member.billingd_stripe \
  "projects/hop-mesh/secrets/stripe-api-key roles/secretmanager.secretAccessor serviceAccount:hop-billingd@hop-mesh.iam.gserviceaccount.com"
tofu -chdir=infra/bootstrap import google_project_iam_member.billingd_firestore_read \
  "hop-mesh roles/datastore.viewer serviceAccount:hop-billingd@hop-mesh.iam.gserviceaccount.com"
tofu -chdir=infra/bootstrap import google_project_iam_member.billingd_logs \
  "hop-mesh roles/logging.logWriter serviceAccount:hop-billingd@hop-mesh.iam.gserviceaccount.com"
tofu -chdir=infra/bootstrap import google_project_iam_member.billingd_bigquery \
  "hop-mesh roles/bigquery.dataEditor serviceAccount:hop-billingd@hop-mesh.iam.gserviceaccount.com"
tofu -chdir=infra/bootstrap import google_iam_workload_identity_pool.github \
  projects/hop-mesh/locations/global/workloadIdentityPools/github-actions
tofu -chdir=infra/bootstrap import google_iam_workload_identity_pool_provider.github \
  projects/hop-mesh/locations/global/workloadIdentityPools/github-actions/providers/github
tofu -chdir=infra/bootstrap import google_service_account.billing_catalog_apply \
  projects/hop-mesh/serviceAccounts/billing-catalog-apply@hop-mesh.iam.gserviceaccount.com
tofu -chdir=infra/bootstrap import google_service_account_iam_member.billing_catalog_wif \
  "projects/hop-mesh/serviceAccounts/billing-catalog-apply@hop-mesh.iam.gserviceaccount.com roles/iam.workloadIdentityUser principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions/attribute.repository/hopmesh/monorepo"
tofu -chdir=infra/bootstrap import google_storage_bucket_iam_member.billing_catalog_state \
  "b/hop-mesh-tfstate roles/storage.objectAdmin serviceAccount:billing-catalog-apply@hop-mesh.iam.gserviceaccount.com billing-state-prefix-only"
```

Never remove a runtime state binding until the matching bootstrap `state show`
succeeds. When import is used instead of `state mv` for a still-tracked object,
import it first, verify the bootstrap plan, then run
`tofu -chdir=infra state rm ADDRESS` for that address only.

After the bootstrap apply, wire the billing workflow to exact bootstrap outputs
and remove the superseded project-number variable if it exists:

```sh
gh variable set GCP_BILLING_WIF_PROVIDER --repo hopmesh/hop \
  --body "$(tofu -chdir=infra/bootstrap output -raw github_wif_provider)"
gh variable set GCP_BILLING_SERVICE_ACCOUNT --repo hopmesh/hop \
  --body "$(tofu -chdir=infra/bootstrap output -raw github_wif_service_account)"
gh variable delete GCP_PROJECT_NUMBER --repo hopmesh/hop 2>/dev/null || true
```

## One-time migration from the old trigger

The old `hop-relayd-image` trigger executes a candidate-loaded filename. Neutralize
it before applying any candidate revision: set its Cloud Build `disabled` field to
`true` in the Cloud Console or trigger API. Confirm no build is running under
`hop-cloudbuild` before changing its grants.

Initialize bootstrap and import existing create-only resources before its first
apply. Replace the connection name in the repository import id.

```sh
tofu -chdir=infra/bootstrap init
tofu -chdir=infra/bootstrap import google_service_account.build \
  projects/hop-mesh/serviceAccounts/hop-cloudbuild@hop-mesh.iam.gserviceaccount.com
tofu -chdir=infra/bootstrap import google_service_account.relay \
  projects/hop-mesh/serviceAccounts/hop-relay@hop-mesh.iam.gserviceaccount.com
tofu -chdir=infra/bootstrap import google_artifact_registry_repository.hop \
  projects/hop-mesh/locations/us-central1/repositories/hop
tofu -chdir=infra/bootstrap import google_cloudbuildv2_repository.hop \
  projects/hop-mesh/locations/us-central1/connections/CONNECTION/repositories/hop
tofu -chdir=infra/bootstrap import google_firestore_database.relay \
  projects/hop-mesh/databases/'(default)'
tofu -chdir=infra/bootstrap import google_firestore_field.bundle_ttl \
  projects/hop-mesh/databases/'(default)'/collectionGroups/bundles/fields/expireAt
tofu -chdir=infra/bootstrap import google_firestore_field.presence_ttl \
  projects/hop-mesh/databases/'(default)'/collectionGroups/presence/fields/expireAt
tofu -chdir=infra/bootstrap import google_firestore_field.registry_ttl \
  projects/hop-mesh/databases/'(default)'/collectionGroups/registry/fields/expireAt
tofu -chdir=infra/bootstrap import google_secret_manager_secret.relay_identity \
  projects/hop-mesh/secrets/hop-relay-identity
tofu -chdir=infra/bootstrap import google_secret_manager_secret.example_identity \
  projects/hop-mesh/secrets/hop-example-identity
tofu -chdir=infra/bootstrap import google_secret_manager_secret.ci_readtoken \
  projects/hop-mesh/secrets/hop-ci-readtoken
tofu -chdir=infra/bootstrap import google_project_iam_custom_role.build_secrets \
  projects/hop-mesh/roles/hopCloudBuildSecrets
```

Import each already-enabled API tracked by the old runtime state with this form:

```sh
tofu -chdir=infra/bootstrap import \
  'google_project_service.this["run.googleapis.com"]' \
  hop-mesh/run.googleapis.com
```

After imports, review `tofu -chdir=infra/bootstrap plan` but do not apply it yet.
While the old trigger is disabled and no build is running, remove the old broad
grants from `hop-cloudbuild`. Remove every old role except
`roles/logging.logWriter`:

```text
roles/cloudbuild.builds.builder
roles/artifactregistry.writer
roles/editor
roles/resourcemanager.projectIamAdmin
roles/iam.serviceAccountAdmin
roles/iam.serviceAccountUser
roles/run.admin
roles/storage.admin
roles/cloudbuild.connectionAdmin
roles/logging.admin
projects/hop-mesh/roles/hopCloudBuildSecrets
```

Also remove its `roles/storage.objectAdmin` grant from `hop-mesh-tfstate`.
Now apply bootstrap manually. Repository-scoped Artifact Registry write,
provenance object creation, KMS signing, CI-token access, and Pub/Sub publication
are installed in the same apply that creates the new triggers. Confirm both new
triggers contain inline build definitions and confirm the deploy trigger requires
approval before allowing another push to `main`.

Move ownership out of the old runtime state without destroying remote resources:

```sh
tofu -chdir=infra state rm google_project_service.this
tofu -chdir=infra state rm google_artifact_registry_repository.hop
tofu -chdir=infra state rm google_firestore_database.relay
tofu -chdir=infra state rm google_firestore_field.bundle_ttl
tofu -chdir=infra state rm google_firestore_field.presence_ttl
tofu -chdir=infra state rm google_firestore_field.registry_ttl
tofu -chdir=infra state rm google_secret_manager_secret.relay_identity
tofu -chdir=infra state rm google_service_account.relay
tofu -chdir=infra state rm google_project_iam_member.relay_firestore
tofu -chdir=infra state rm google_project_iam_member.relay_logs
tofu -chdir=infra state rm google_secret_manager_secret_iam_member.relay_identity
tofu -chdir=infra state rm 'google_cloudbuildv2_repository.hop[0]'
tofu -chdir=infra state rm 'google_service_account.build[0]'
tofu -chdir=infra state rm google_project_iam_member.build
tofu -chdir=infra state rm 'google_project_iam_custom_role.build_secrets[0]'
tofu -chdir=infra state rm 'google_storage_bucket_iam_member.build_state[0]'
tofu -chdir=infra state rm 'google_secret_manager_secret.ci_readtoken[0]'
tofu -chdir=infra state rm 'google_secret_manager_secret_iam_member.build_ci_readtoken[0]'
tofu -chdir=infra state rm 'google_cloudbuild_trigger.image[0]'
```

Delete the disabled `hop-relayd-image` trigger only after `hop-source-build` and
`hop-runtime-deploy` are applied and inspected. Run `tools/infra-authority-guard.py`
and inspect the live IAM policy before re-enabling push-to-main builds.

## Verification

```sh
tofu -chdir=infra fmt -check -recursive
tofu -chdir=infra init -backend=false -input=false
tofu -chdir=infra validate
tofu -chdir=infra/bootstrap init -backend=false -input=false
tofu -chdir=infra/bootstrap validate
tofu -chdir=infra/billing init -backend=false -input=false
tofu -chdir=infra/billing validate
bash tools/require-ci-gate.test.sh
bash tools/deploy-provenance.test.sh
bash tools/infra-authority-guard.test.sh
python3 tools/infra-authority-guard.py
bash tools/executable-reference-guard.test.sh
python3 tools/executable-reference-guard.py
actionlint .github/workflows/billing-catalog.yml
bash tools/check-required-checks.test.sh
bash tools/check-required-checks.sh
```
