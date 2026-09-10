# Hop production infrastructure

`hopmesh/hop` is the only deployment authority. No workflow in the private source repository or the
frozen legacy monorepo may apply these roots.

## Roots

- `infra/` owns runtime Cloud Run services, load balancing, DNS, certificates, observability, and the
  BigQuery usage dataset. State: `gs://hop-mesh-tfstate/relay-fleet`.
- `infra/bootstrap/` owns APIs, IAM, service accounts, secret containers, Cloud SQL, Firestore policy,
  Artifact Registry, and GitHub Actions federation. State: `gs://hop-mesh-tfstate/bootstrap`.
- The private billing root stays at the commit in `infra/private-source.lock`. It is applied only by a
  workflow defined in this repository. State: `gs://hop-mesh-tfstate/billing`.

The private commercial source also stays at that exact platform commit. `runtime-deploy.yml` checks it
out after public images are built, verifies the pin, stages exactly the 57 manifest files, and then
builds accountd and console. A platform commit cannot deploy until a reviewed hop PR changes the pin.

## Deployment

A green `CI` run on a push to `main` triggers `.github/workflows/runtime-deploy.yml`. The workflow
checks out the exact green commit, builds public images before private source enters the workspace,
then builds commercial images. All image inputs are immutable Artifact Registry digests. The runtime
apply records both `hop-source-sha` and `hop-private-source-sha` on every Cloud Run service and reads
them back before reporting success.

The relay fleet remains OFF. `RELAYS_ENABLED` stays false until the alerting, status, region, and spend
preconditions in `docs/runbooks/relay-enable-disable.md` are met and the owner flips the repository
variable.

Bootstrap changes use `.github/workflows/bootstrap-apply.yml` from hop `main`. The final authority
state admits only `hopmesh/hop` through the provider condition and only `refs/heads/main` through the
service-account bindings. Pull-request validation is credential-free.

Billing and Resend changes use workflows in hop and source from the pinned private commit. They fetch
vendor credentials from Secret Manager after WIF authentication. They never use GitHub repository
secrets for Stripe or Resend.

## Rules

- Never run local `tofu apply`. Deployment and bootstrap mutations run in reviewed GitHub Actions.
- Never commit commercial source, `infra/billing`, credentials, pricing values, or generated tfvars.
- Never read the private billing state from runtime. Billing publishes only three public Stripe price
  identifiers to the versioned `hop-billing-price-ids` Secret Manager container.
- Keep all backend bucket and prefix values exact. Changing a prefix creates a second state authority.
- Keep the 73 runtime resource addresses and 20 removed addresses equal to their manifests. Every
  removed block keeps `destroy = false`.
- Runtime images use digest references only. Missing digests are fatal.
- Run `python3 tools/infra-authority-guard.py` and its self-test for every infra change.
