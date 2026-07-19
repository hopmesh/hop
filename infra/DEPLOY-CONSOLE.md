# Deploying the console (hop-accountd + hop-console)

This is the exact, ordered plan to deploy the two new runtime services to `hop-mesh`. It touches the
**supply-chain trusted guards** (`tools/infra-authority-guard.py`, `tools/deploy-provenance.py`) and
provisions **billed production infra** (Cloud SQL) on the same Cloud Build pipeline that ships the
relay fleet, so **review the `tofu plan` (runtime) + the guard diffs + a `bootstrap` plan before
applying**. The Dockerfiles (accountd built `--features live,firestore`; the console standalone image)
are already in this PR / #251.

## What deploys

- **hop-accountd** — the console backend (auth, orgs, billing, keys, console reads, team, tenant-sync
  writer). Internal ingress (the console proxies to it). `min=1`, `cpu_idle=false` (it runs the
  Firestore tenant-sync thread + a persistent PG pool).
- **hop-console** — the Next.js front (`dashboard.hopme.sh`). Public via the shared LB. `min=0`,
  `cpu_idle=true` (scale-to-zero, per Jason's call).
- **Cloud SQL** — a `db-f1-micro` Postgres 16 for accountd.
- **Fleet sync** — enabled by setting `HOP_TENANT_SYNC_PROJECT` on accountd; the relays already read
  the registry via their existing `--firestore var.project_id`.

## Step 0 — one-time secrets (out-of-band, values never in TF state)

`stripe-account-key` already exists (bootstrap/billing.tf). Create the rest as **empty containers in
`infra/bootstrap`** (see Step 1) and seed their values by hand:

```bash
for s in hop-api-token resend-api-key resend-from github-client-id console-db-url; do
  gcloud secrets create $s --project hop-mesh --replication-policy=automatic 2>/dev/null || true
done
# hop-resend-apikey + hop-github-oauth-client-secret are already set (done earlier).
printf %s "$(head -c 24 /dev/urandom | base64)" | gcloud secrets versions add hop-api-token --project hop-mesh --data-file=-  # >=16 bytes
printf %s 'noreply@hopme.sh'         | gcloud secrets versions add resend-from            --project hop-mesh --data-file=-
printf %s 'Ov23lidjG8DrCaoi8hT3'     | gcloud secrets versions add github-client-id       --project hop-mesh --data-file=-
# console-db-url is written AFTER Cloud SQL exists (Step 3): postgresql://hop_console:PASS@/hop_console?host=/cloudsql/<connection_name>
```

## Step 1 — `infra/bootstrap` (SAs, secret containers, IAM, image build steps)

The runtime guards FORBID `google_service_account`, `google_secret_manager_secret`,
`google_project_iam*`, `google_firestore_*` in the `infra/*.tf` root — all of this goes in
`infra/bootstrap/` (exempt), modeled on the existing `billingd` block (`bootstrap/billing.tf:39-68`):

1. **Two runtime SAs**: `hop-accountd`, `hop-console` (`google_service_account`).
2. **accountd IAM**: `roles/secretmanager.secretAccessor` on each secret it reads (stripe-account-key,
   hop-api-token, hop-resend-apikey, resend-from, github-client-id, hop-github-oauth-client-secret,
   console-db-url); `roles/cloudsql.client`; `roles/datastore.user` (registry sync writes Firestore);
   `roles/logging.logWriter`.
3. **console IAM**: `roles/logging.logWriter` only (it holds no secrets; HOP_ACCOUNTD_URL is plain env).
4. **Secret containers**: the ones from Step 0 (`google_secret_manager_secret`).
5. **Deploy attach**: `google_service_account_iam_member` `roles/iam.serviceAccountUser` for `hop-deploy`
   on each new SA (mirror `bootstrap/iam.tf:102-112`), and add `deploy_uses_accountd`/`deploy_uses_console`
   to the trigger `depends_on` (`bootstrap/triggers.tf:467-481`).
6. **Image repos + build/push steps** in `bootstrap/triggers.tf` (mirror `build-relayd`/`push-relayd`,
   `:65-113`): build `-f services/hop-accountd/Dockerfile` and `-f apps/web/console/Dockerfile`, tag
   `:$COMMIT_SHA`, add to `images` (`:146`) + the `image_repositories` contract (`:207`). Add
   `accountd_image_repository`/`console_image_repository` locals in `bootstrap/core.tf:24`.

## Step 2 — the two trusted guards (BOTH files + their `.test.sh` fixtures, same PR)

The allowlists are hardcoded Python sets mirrored in both guards. Extend each from 2 → 4:

- `tools/infra-authority-guard.py`: the Cloud Run set (`:192-196`) → add `("google_cloud_run_v2_service","accountd")`, `(...,"console")`; image bindings (`:197-199`) → add `var.accountd_image`, `var.console_image`; SA set (`:200-207`) → add `local.accountd_service_account`, `local.console_service_account`; the `data.tf` local pins (`:224-229`).
- `tools/deploy-provenance.py`: the identical mirror in `verify_runtime_archive()` (`:672-700`).
- **Price remote-state (a deliberate relaxation, review carefully):** to wire `HOP_STRIPE_*_PRICES`
  from `infra/billing`'s output, add `terraform_remote_state` to `ALLOWED_RUNTIME_DATA_SOURCES` and the
  `terraform.io/builtin/terraform` provider to `EXPECTED_RUNTIME_PROVIDER_SOURCES` in BOTH guards.
  Alternative (no relaxation): pass the 3 price ids as `TF_VAR_*` from the deploy trigger
  (`bootstrap/triggers.tf:380-388`) instead of remote-state.
- Update `tools/infra-authority-guard.test.sh` + `tools/deploy-provenance.test.sh` fixtures to the new
  4-service allowlist (they assert it exactly; CI `ci.yml:768,772` runs them).

## Step 3 — `infra/` runtime root

1. **`infra/data.tf`**: add `accountd_service_account`/`console_service_account` locals (the guard pins them).
2. **`infra/variables.tf`**: `accountd_image` + `console_image` (validate `@sha256:<64hex>`, like `relay_image` `:14-22`); `console_db_password` (or feed via the console-db-url secret only).
3. **`infra/cloud_sql.tf`** (new): the `db-f1-micro` Postgres 16 instance + database + user (Step 0/§5 of the infra map). `deletion_protection = true`.
4. **`infra/console.tf`** (new): the two `google_cloud_run_v2_service` resources + the LB/DNS wiring for
   `dashboard.hopme.sh` — copy the `example.hopme.sh` set verbatim (NEG, backend service, DNS-auth,
   managed cert + cert-map entry on the shared `certificate_map.relay`, A/AAAA to
   `google_compute_global_address.relay[_v6]`) and the `url_map.relay` host_rule (`load_balancer.tf:113`);
   add a matching host_rule to `url_map.off` so the console stays reachable while `relays_enabled=false`.
   - accountd: `ingress = INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`, `min=1`, `cpu_idle=false`, the
     `run.googleapis.com/cloudsql-instances` annotation, env-from-secret for the 7 secrets, plain env for
     `HOP_CONSOLE_BASE=https://dashboard.hopme.sh`, `HOP_FIRESTORE_PROJECT=var.project_id`,
     `HOP_TENANT_SYNC_PROJECT=var.project_id`, and `HOP_STRIPE_USAGE_PRICES` /
     `HOP_STRIPE_SCALE_METERED_PRICES` = `"<reach>,<observability>"`, `HOP_STRIPE_SCALE_BASE_PRICE=<base>`
     from the billing price_ids. **Note:** `HOP_TENANT_MAP` is for the legacy operator `/v1/*` invoice
     surface; the console uses `/console/*` (cookie-authed) so it can be omitted.
   - console: `min=0`, `cpu_idle=true`, public, one env `HOP_ACCOUNTD_URL` = accountd's internal URL
     (`google_cloud_run_v2_service.accountd.uri`).
   - Both carry the `deployment_source_sha` label + the three `hopmesh.dev/*` annotations (convention).
   - Health probes: accountd serves `/healthz` (not `/livez`) — point the probes there. The console has
     no health endpoint; use a TCP startup probe or Next's default (drop the http_get probe).

## Step 4 — apply order + verify

1. Merge the guard + Dockerfile + bootstrap PR first; `tofu -chdir=infra/bootstrap plan` (review), apply
   (creates SAs, secrets, image build steps).
2. Seed `console-db-url` after Cloud SQL exists (Step 0).
3. The push-to-main deploy builds the images + runs the runtime `tofu apply` (review the plan: it should
   show the 2 services + Cloud SQL + the LB/DNS + `certificate` pending validation, nothing destroyed).
4. Point `dashboard.hopme.sh` — confirm the managed cert goes ACTIVE (DNS-auth CNAME must resolve).
5. Register the GitHub OAuth app callback = `https://dashboard.hopme.sh/api/auth/github/callback`.
6. Smoke: `https://dashboard.hopme.sh` → magic-link signup → dashboard loads → usage/billing populate.

## Not in this deploy (follow-ups)

- Stripe **webhook** to STORE plan+status on the Org (the billing view live-queries today).
- Email **invites** (team management is otherwise complete).
- Exact Stripe **billing-period** alignment for the usage window (currently a rolling 30 days).
