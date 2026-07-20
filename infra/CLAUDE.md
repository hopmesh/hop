# infra/

GCP production infrastructure is split across two OpenTofu roots. The Stripe
catalog is isolated in the third root at `infra/billing/`:

- `infra/bootstrap/` is applied by manual dispatch of
  `.github/workflows/bootstrap-apply.yml`, never from a terminal. It owns APIs,
  IAM, service accounts, secrets, Firestore policy, Artifact Registry, KMS,
  provenance and lease storage, Pub/Sub, billing WIF and state authority, and
  both trusted inline Cloud Build triggers.
- `infra/` is the automatically applied runtime root. It owns services, load
  balancing, DNS, certificates, and observability. It must never contain project
  IAM, service-account IAM, secret IAM, custom roles, triggers, API enablement, or
  bootstrap resources.

## Deployment path

`hop-source-build` runs candidate Docker builds as the low-privilege
`hop-cloudbuild` identity. Its build definition is stored inline in the applied
trigger. `infra/cloudbuild.trigger.yaml` is a retired fail-closed sentinel and is
not an active security boundary.

The trusted source definition validates the exact GitHub Actions workflow run,
builds full-SHA tags, resolves digests, signs a provenance manifest, and publishes
a deployment request. `hop-runtime-deploy` runs as the separate `hop-deploy`
identity after control-plane approval. It revalidates CI, build provenance,
canonical main, and the global GCS lease before applying the runtime archive with
digest-only image references.

The fleet remains off with `relays_enabled=false` in bootstrap. The aggregate
`/healthz` readiness smoke runs only when it is enabled. Cloud Run liveness remains
on `/livez`; do not collapse readiness and liveness or add recurring external
region probes.

## Rules

- Never add `filename` or `git_file_source` to an active trigger.
- Never execute a candidate checkout under the deploy identity before the trusted
  gate and signed provenance verification.
- Never grant build or deploy `Editor`, Project IAM Admin, Service Account Admin,
  Run Admin, Storage Admin, Secret Manager Admin, or role mutation permissions.
- IAM and secret policy changes belong only in bootstrap.
- No root is applied from a terminal. Bootstrap goes through
  `bootstrap-apply.yml`, runtime through push to `main`, billing through
  `billing-catalog.yml`. A local apply from a stale checkout plans a partial destroy
  of whatever remote state holds and the local files no longer declare.
- Workload Identity Federation pools and providers belong only in bootstrap.
- Build tags use the full 40-character SHA. Runtime images use only `@sha256:`.
- The deploy lease is separate from OpenTofu state locking. Preserve both
  canonical-main checks and generation preconditions.
- Cloud Build substitutions still scan shell scripts. Escape shell dollars as
  doubled dollars in inline HCL scripts. Escape Terraform template percent markers
  where needed.
- `prevent_destroy` protects identity secrets, provenance keys, and the bootstrap
  contract.

## Verification

Run `tofu -chdir=infra fmt -check -recursive`, validate both roots with
`-backend=false`, run every `tools/*guard*.test.sh` relevant to the change, then run
the live guards. The required-check guard keeps CI job names synchronized with
`github_required_checks` in `infra/bootstrap/variables.tf`.
