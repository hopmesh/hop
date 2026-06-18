# infra/bootstrap — Spacelift ↔ GCP OIDC

One-time setup that lets Spacelift run `infra/` against GCP with **no static keys**.
It creates a Workload Identity Pool that trusts our Spacelift account's OIDC tokens,
a `spacelift` service account, and the binding letting runs in space `root`
impersonate that SA (auth mode: **service account impersonation**).

## Why it's separate

This module *grants* Spacelift its access, so it can't run *in* Spacelift
(chicken-and-egg). Apply it **once, locally, as a human**:

```sh
cd infra/bootstrap
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token --account jason@waldrip.net)
terraform init
terraform apply
```

State is local and holds no secrets.

## Wiring up the Spacelift stack

`terraform apply` writes `infra/spacelift-gcp-credentials.json` — a federation config
that holds **no secrets** (the real secret is the per-run OIDC token Spacelift drops
at `/mnt/workspace/spacelift.oidc`). It's **gitignored**: don't commit it; mount its
contents into the stack instead. On the Spacelift stack for `infra/`:

1. Mount the file into the stack (uploads the contents to Spacelift):
   ```sh
   spacectl stack environment mount --id <stack> \
     spacelift-gcp-credentials.json infra/spacelift-gcp-credentials.json
   ```
2. Set env var `GOOGLE_APPLICATION_CREDENTIALS=/mnt/workspace/spacelift-gcp-credentials.json`.
3. Ensure the stack lives in space `root` (or update `spacelift_space_id` and re-apply).

Spacelift drops the run's OIDC token at `/mnt/workspace/spacelift.oidc` automatically;
the provider exchanges it for an impersonated SA token. `provider "google" {}` in
`infra/` then just works.

## Inputs

| Variable | Default |
|----------|---------|
| `spacelift_hostname` | `hopmesh.app.us.spacelift.io` |
| `spacelift_space_id` | `root` |
| `sa_roles` | `["roles/owner"]` |
