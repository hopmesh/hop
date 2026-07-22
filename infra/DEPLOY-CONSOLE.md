# Deploying the console (hop-accountd + hop-console)

This is the ordered plan to bring the two console services up on `hop-mesh`. It provisions **billed
production infra** (Cloud SQL, two Cloud Run services, one more LB host rule) and it widens
`tools/infra-authority-guard.py` from two runtime services to four, so **read the guard diff and both
plans before applying anything**.

**Nothing here is applied from a terminal.** Every apply is a workflow dispatch or a merge to `main`.
There is no deploy-control bucket, no KMS signing, no Pub/Sub deployment request, no provenance
manifest, and no approval gate anywhere in this path: GitHub is change management, GCP is plumbing. The
pull request that merges these bytes is the only human gate.

## How each root gets applied

| Root | Applied by | Trigger |
| --- | --- | --- |
| `infra/bootstrap` | `.github/workflows/bootstrap-apply.yml` | manual dispatch, `confirm=apply` |
| `infra/` (runtime) | `.github/workflows/runtime-deploy.yml` | automatic, on merge to `main` once CI is green |
| `infra/billing` | `.github/workflows/billing-catalog.yml` | manual dispatch, `confirm=apply` |

All three authenticate keylessly (GitHub OIDC to Workload Identity Federation). None has a GitHub
environment or a reviewer gate. `bootstrap-apply` and `runtime-deploy` are bound to a single exact OIDC
subject, a run on `refs/heads/main`, so a pull request ref mints no credentials at all.

A local `tofu apply` against any of these is a **destroy operation** whenever the checkout is behind:
everything in remote state but absent from the local files is planned for deletion, and bootstrap owns
IAM, service accounts, and secrets. `prevent_destroy` does not save you there, it just strands the root
half applied.

```sh
gh workflow run bootstrap-apply.yml --ref main -f confirm=plan   # review the plan in the run log
gh workflow run bootstrap-apply.yml --ref main -f confirm=apply  # applies immediately, no approval step
```

All three roots are already applied and live, so nothing below is a first-time bootstrap. The one-time
federation seeding (the WIF pool, its provider, the `bootstrap-apply` identity, its two custom roles,
and the state-bucket self-binding) is done and imported; `bootstrap-apply.yml`'s `confirm=seed` path is
the recipe if the project is ever rebuilt.

## What deploys

- **hop-accountd**: the console backend (auth, orgs, billing, keys, console reads, team, tenant-sync
  writer). `min=1`, `cpu_idle=false`: it runs the Firestore tenant-sync thread plus a persistent
  Postgres pool, both outside request scope. The console front reaches it over its `run.app` URI; every
  route is authenticated at the app layer.
- **hop-console**: the Next.js front at `dashboard.hopme.sh`. Public through the SHARED global LB (one
  more host rule and one more SNI cert-map entry, not a second load balancer). `min=0`, `cpu_idle=true`.
- **Cloud SQL**: one `db-f1-micro` Postgres 16 instance, `deletion_protection = true`.
- **Fleet sync**: `HOP_TENANT_SYNC_PROJECT` on accountd activates the tenant-registry projection into
  Firestore; the relays already read that registry.

## Secrets: what is generated, what a human seeds

Three containers hold credentials a third party issues to a human. All three are **already seeded** in
`hop-mesh` and their bytes never enter any OpenTofu state: `stripe-account-key`, `hop-resend-apikey`,
`hop-github-oauth-client-secret`.

Three are machine generated, so there is no `gcloud secrets versions add` step at all:

- `hop-api-token` and `console-db-url` are created AND written by the bootstrap apply
  (`infra/bootstrap/console.tf`). `console-db-url` is composed from the generated Postgres password and
  the instance connection name, so the database user and the DSN can never drift apart.
- `stripe-webhook-secret`: the container is bootstrap-owned (`infra/bootstrap/billing.tf`); the VALUE is
  written by the `infra/billing` apply (`infra/billing/webhook_secret.tf`), the root that owns the
  Stripe webhook endpoint the signing secret belongs to.

Stated plainly: those three generated values DO live in OpenTofu state (bootstrap state for the first
two, billing state for the third, where the endpoint's computed attribute has always put it). That is a
deliberate, owner-approved tradeoff for zero manual seeding; the access-controlled `hop-mesh-tfstate`
bucket is the boundary protecting them. `GITHUB_CLIENT_ID` and `RESEND_FROM` are public config, not
secrets, and ride as plain Cloud Run env from `infra/variables.tf`.

## What this change adds

**`infra/bootstrap/console.tf`** (administrator-owned, applied by dispatch)

1. Two runtime identities: `hop-accountd`, `hop-console`.
2. accountd project roles `cloudsql.client`, `datastore.user`, `logging.logWriter`; console gets only
   `logging.logWriter` (it holds no secrets).
3. `secretAccessor` for accountd on all six secrets it reads.
4. The `hop-api-token` and `console-db-url` containers plus their generated versions, and the scoped
   version authority the applier needs to write exactly those two (see Permissions below).
5. Cloud SQL: instance, `hop_console` database, `hop_console` user, generated password.
6. `serviceAccountUser` for `hop-deploy` on both new identities, so the runtime apply may attach them to
   Cloud Run. Mirrors `deploy_uses_relay` / `deploy_uses_example` in `iam.tf`.
7. A READ-ONLY `storage.objectViewer` grant for `hop-deploy` on the `billing/` state prefix, because the
   runtime root reads the Stripe price ids out of that state.

**`infra/console.tf`** (runtime, applied on merge to main)

The two `google_cloud_run_v2_service` resources plus the `dashboard.hopme.sh` LB set: serverless NEG,
backend service, DNS authorization, managed cert, an entry on the shared `certificate_map.relay`, A and
AAAA to the existing anycast addresses, and a host rule on BOTH `url_map.relay` and `url_map.off` so the
console stays reachable while `relays_enabled=false`.

**`.github/workflows/runtime-deploy.yml`**

Two more images built, pushed, and digest-pinned exactly like the relay and example ones:
`services/hop-accountd/Dockerfile` (which builds `--features live,firestore`) and
`apps/web/console/Dockerfile` (the Next.js standalone image). Their resolved `@sha256` references pass
as `TF_VAR_accountd_image` and `TF_VAR_console_image`.

**`tools/infra-authority-guard.py`** (and its `.test.sh`)

The runtime allowlist goes from two services to four: the Cloud Run declarations, the `var.*_image`
bindings, the `local.*_service_account` bindings, and the `data.tf` identity pins. Two relaxations, both
deliberate: `terraform_remote_state` joins the allowed runtime data sources and
`terraform.io/builtin/terraform` joins the expected provider sources, so the runtime can read the
isolated billing state for the price ids. The image-digest check was tightened in the same pass to read
each variable's validation CONDITION instead of merely finding `@sha256` somewhere in the block.

## Permissions the applies need

`bootstrap-apply` gains two things it did not have, both declared in `infra/bootstrap`:

- `roles/cloudsql.admin`, for the instance, database, and user. Cloud SQL has no narrower create role
  (`cloudsql.editor` cannot create an instance; `cloudsql.client` is connect-only). It is a
  control-plane role: it manages instances, databases, and users, and reads no table contents.
- `secretVersionAdder` plus `secretAccessor` scoped to `hop-api-token` and `console-db-url` only. The
  project-level `hopBootstrapApplySecrets` custom role stays container-only on purpose, so applying
  bootstrap still cannot read the Stripe keys, the relay seed, or the OAuth client secret.

Both are granted by the same apply that uses them. `depends_on` orders the grant before the use, but IAM
propagation can still lag a few seconds on a first run; if a step fails 403, re-dispatch `confirm=apply`
and it succeeds.

`hop-deploy` (the runtime applier) already holds what the two Cloud Run services and the LB, DNS, and
certificate resources need: `run.developer` plus the narrow `hopRuntimeDeployRunIam`
(`run.services.getIamPolicy` / `setIamPolicy`, required by `invoker_iam_disabled`),
`compute.loadBalancerAdmin`, `dns.admin`, `certificatemanager.editor`, and now `serviceAccountUser` on
the two new identities.

**One open item.** Attaching the Cloud SQL socket (the `run.googleapis.com/cloudsql-instances`
annotation) may require the DEPLOYING principal to hold `cloudsql.instances.get` on the instance, not
just the runtime service account's `cloudsql.client`. `hop-deploy` holds no Cloud SQL role today. If the
first apply fails with a permission error naming the instance, add `roles/cloudsql.viewer` to
`local.deploy_project_roles` in `infra/bootstrap/iam.tf` AND to `EXPECTED_DEPLOY_PROJECT_ROLES` in
`tools/infra-authority-guard.py` (the guard pins that set exactly), then re-dispatch bootstrap. It is
left out here rather than guessed at: granting the applier a role it does not need is the worse error.

## Operator sequence

1. Merge this PR. The merge alone does not finish the job: the runtime apply it triggers fails until
   step 2 has run, because the two console identities and the `console-db-url` secret do not exist yet.
2. `gh workflow run bootstrap-apply.yml --ref main -f confirm=plan`, read the plan in the run log (it
   must show only the intended creates and nothing destroyed), then `-f confirm=apply`. This creates the
   identities, the secret containers and their generated values, Cloud SQL, and the IAM.
3. `gh workflow run billing-catalog.yml --ref main -f confirm=apply` to write `stripe-webhook-secret`
   from the Stripe webhook endpoint. Bootstrap must have run first, since the container is bootstrap
   owned.
4. Re-run the runtime deploy (push any commit to `main`, or re-run the `Runtime deploy` workflow run for
   the merge commit). Review the apply output: two services, the console NEG, backend, cert, cert-map
   entry, and DNS records, nothing destroyed.
5. Confirm the `dashboard.hopme.sh` managed cert goes ACTIVE (the DNS-auth CNAME must resolve first).
6. Register the GitHub OAuth callback `https://dashboard.hopme.sh/api/auth/github/callback`.
7. Smoke: `https://dashboard.hopme.sh`, magic-link signup, dashboard loads, usage and billing populate.

## First-apply risks to confirm

- accountd ingress is `ALL` (app-layer auth on every route). To make it private, switch to
  `INTERNAL_ONLY` and add a Direct VPC egress on the console so its calls are classified internal. That
  needs the live VPC and subnet to validate, hence deferred.
- `console_db_connection_name` is a pinned string (`hop-mesh:us-central1:hop-console-db`) rather than a
  resource reference, because the instance is bootstrap-owned. If the instance is ever renamed or moved
  regions, update that variable in the same change.
- Cloud SQL bills continuously from the moment step 2 applies, whether or not the console is live.

## Not in this deploy (follow-ups)

- Email invites (team management is otherwise complete).
- Exact Stripe billing-period alignment for the usage window (currently a rolling 30 days).
