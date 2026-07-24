# infra/

GCP production infrastructure is split across two OpenTofu roots. Keyed third-party
SaaS is isolated in the third root at `infra/billing/` (the Stripe billing catalog
and the Resend sending domain, `resend.tf`), so the relay-fleet apply never carries
those API keys:

- `infra/bootstrap/` is applied by manual dispatch of
  `.github/workflows/bootstrap-apply.yml`, never from a terminal. It owns APIs,
  IAM, service accounts, secrets, Cloud SQL, Firestore policy, Artifact Registry, the
  billing and runtime Workload Identity Federation pool + provider, and state authority.
- `infra/` is the automatically applied runtime root. It owns services, load
  balancing, DNS, certificates, observability, and the BigQuery usage dataset. It
  must never contain project IAM, service-account IAM, secret IAM, custom roles,
  API enablement, WIF, or bootstrap resources.

## Who decides what: GitHub is change management, GCP is plumbing

The only human gate on any change is the pull request that merges it to `main`.
GitHub decides whether, what, and who approved. Google Cloud runs what GitHub
blessed and verifies nothing about the change: no signing, no re-approval, no
provenance re-check. Every apply is keyless (GitHub OIDC to WIF), so there are no
service-account keys anywhere.

## Deployment path

A merge to `main` runs the `CI` workflow. When CI COMPLETES SUCCESSFULLY on that
push, `.github/workflows/runtime-deploy.yml` fires. It authenticates as `hop-deploy`
over WIF, builds and pushes the `hop-relayd`, `hop-example`, `hop-accountd`, and
`hop-console` images, resolves each to an immutable `@sha256` digest, and runs
`tofu apply` on the runtime root with digest-only image references. A supersession
guard reads the current `main` tip first: if a newer commit already landed, the run
SKIPS every remaining step (it succeeds and applies nothing) so an older tree can
never overwrite a newer one.

`hop-deploy` holds only the runtime roles the apply needs (Cloud Run, load balancer,
DNS, certificates, monitoring, logging, BigQuery data, Artifact Registry read/write,
and `serviceAccountUser` on the four runtime identities) plus `storage.objectUser`
scoped to the runtime state prefix and `storage.objectViewer` scoped READ-ONLY to the
`billing/` state prefix (the runtime root reads the Stripe price ids from that state).
It has no administrative authority: no project, service-account, or secret IAM admin,
no API enablement, no role mutation, and no write access to any state but its own.

The fleet remains off with `relays_enabled=false`. The aggregate `/healthz` readiness
smoke matters only when it is enabled. Cloud Run liveness stays on `/livez`; do not
collapse readiness and liveness or add recurring external region probes.

## Rules

- No root is applied from a terminal. Bootstrap goes through `bootstrap-apply.yml`
  (dispatch), runtime through `runtime-deploy.yml` (automatic on merge-to-main after
  green), billing through `billing-catalog.yml` (dispatch). A local apply from a stale
  checkout plans a partial destroy of whatever remote state holds and the local files
  no longer declare.
- IAM, secret policy, API enablement, custom roles, and WIF pools + providers belong
  only in bootstrap. The runtime root names the pre-created identities from `data.tf`
  but changes no policy.
- Runtime images use only `@sha256:` digests; the four runtime image variables
  (`relay_image`, `example_image`, `accountd_image`, `console_image`) reject anything
  else. The deploy workflow resolves the digests from the images it just pushed.
- The runtime root reads exactly one cross-root state, `infra/billing`, for the Stripe
  price ids, through the single `terraform_remote_state` data source the authority guard
  allows. Nothing else may read another root's state.
- `prevent_destroy` protects identity secrets and the Stripe secret containers.
- `tools/infra-authority-guard.py` enforces the runtime/bootstrap boundary and the
  bounded `hop-deploy` role set on every PR.

## Verification

Run `tofu -chdir=infra fmt -check -recursive`, validate all three roots with
`-backend=false`, run every `tools/*guard*.test.sh` relevant to the change, then run
the live guards. `tools/check-required-checks.sh` keeps the aggregate `CI gate` honest
(it must depend on every job and fail closed), and `tools/check-branch-protection.sh`
asserts the live rule on `main` requires exactly that one context.
