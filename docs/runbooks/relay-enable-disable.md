# Runbook: enable and disable the relay fleet

The relay fleet (one Cloud Run relay per Google Cloud region, up to 43 regions, behind a
single anycast load balancer) is controlled by the OpenTofu variable: `relays_enabled`.
This runbook documents where the variable lives, who applies it, the real preconditions
required before enabling traffic, and how to execute or revert the change safely.

## Architecture and repository ownership

Under the settled architecture, `hopmesh/hop` is the sole workflow, build, and deploy authority. The archived `hopmesh/monorepo` has zero deployment authority, and no runtime action may target it. Public runtime and bootstrap OpenTofu roots reside in `hopmesh/hop`.

Historical context: Prior to the 2026-09 cutover, deployment roots historically resided in the private `hopmesh/monorepo` before that repository was archived.

1. **Variable definition**: `relays_enabled` is declared in OpenTofu configuration (`variables.tf`). It defaults to `false`.
2. **Applying workflow**: The workflow applying the runtime root is `runtime-deploy.yml` ("Runtime deploy (relay fleet + console)").
3. **Execution trigger**: `runtime-deploy.yml` runs via GitHub Actions `workflow_run` when the `CI` workflow completes successfully on pushes to `main` in `hopmesh/hop`.
4. **Variable passing**: In `runtime-deploy.yml`, OpenTofu receives:
   `TF_VAR_relays_enabled: ${{ vars.RELAYS_ENABLED || 'false' }}`.
   Because `vars.RELAYS_ENABLED` is not currently set in `hopmesh/hop` repository variables, the fleet defaults to `false`.
5. **Path for changes**: Changes made to relay code under `services/hop-relayd/` deploy directly from `hopmesh/hop`. No operational command or deployment action may target `hopmesh/monorepo`.
## Real preconditions for fleet enablement

Enabling the relay fleet carries operational, financial, and reputational responsibilities.
The preconditions fall strictly into two categories: what an engineer can prepare, and what
only the project owner can decide.

### Engineer-reachable preconditions

An engineer can verify, write, and validate these items before asking the owner for decisions:

1. **Wire alerting into the deployment workflow**:
   OpenTofu configuration `observability.tf` defines `variable "alert_email"`, a notification
   channel (`google_monitoring_notification_channel.email`), and alert policies for failed operations,
   Cloud Run 5xx/429 spikes, and crash loops. Every alert resource is count-gated on
   `(var.relays_enabled && var.alert_email != "")`.
   In `hopmesh/hop`, `runtime-deploy.yml` forwards
   `TF_VAR_alert_email: ${{ vars.ALERT_EMAIL || '' }}` in the `env` block of the deploy step.
2. **Provision the status page host (`status.hopme.sh`)**:
   BIZ-014 requires public status reporting before carrying traffic. DNS lookups for
   `status.hopme.sh` currently return `NXDOMAIN`. No DNS record exists in `dns.tf`
   or `pages_dns.tf`. An engineer must define the DNS record (such as a CNAME
   to a managed status provider or hosting target) and verify resolution before enablement.
3. **Curate the initial region allowlist**:
   `regions.tf` subtracts excluded regions from all available GCP compute
   regions (~43 regions). Fresh GCP projects do not have Cloud Run quota enabled across all 43
   regions simultaneously. Attempting to deploy to all regions without prior quota increases will
   fail during `tofu apply`. An engineer can configure `vars.RELAY_REGION_ALLOWLIST` with a curated
   initial tier (for example `["us-central1", "europe-west1", "asia-east1"]`) to ensure smooth rollout.
4. **Verify relay identity version pinning**:
   `cloud_run.tf` mounts the secret `hop-relay-identity` at version
   `var.relay_identity_version` (defaulting to `"1"` in `runtime-deploy.yml`). An engineer must
   confirm the secret version exists in Google Secret Manager and matches the bootstrap identity.
5. **Verify codebase authority**:
   `hopmesh/hop` is the sole deploy and protocol source. No deployment action may target `hopmesh/monorepo`.
6. **Establish a safe dry-run plan procedure**:
   Verify the infrastructure plan using the CI-based dry-run procedure described below.

### Owner-only decisions

These decisions involve financial spend, external commitments, and administrative authority.
They must not be assumed or fabricated by an engineer:

1. **Alert destination email**:
   The owner must provide the operational email address that will receive 24/7 incident alerts.
   Placeholder: `[OWNER: valid email address for relay operational alerts, e.g. ops@hopme.sh]`
2. **Spend and region authorization**:
   Enabling relays across multiple regions provisions Cloud Run services, ingress, and Firestore
   traffic. Even though Cloud Run scales to zero when idle (`min_instance_count = 0`), active relays
   incur networking, log routing, and operational costs. The owner must authorize the target region
   list and commit to the infrastructure spend.
   Placeholder: `[OWNER: target region allowlist JSON array, e.g. '["us-central1", "europe-west1", "asia-east1"]' or '[]' for all available regions, and spend commitment]`
3. **Enablement switch authorization**:
   The owner must authorize setting the repository variable `RELAYS_ENABLED = true` in `hopmesh/hop`.
   Placeholder: `[OWNER: set repository variable RELAYS_ENABLED=true in hopmesh/hop Settings -> Secrets and variables -> Actions; do not target archived hopmesh/monorepo]`
## Safe dry-run planning: how and why

Local workstations must not execute `tofu plan` or `tofu apply` directly against production:

1. **Why local execution is unsafe**:
   - Production state is stored in Google Cloud Storage (`gs://hop-mesh-tfstate/relay-fleet`).
     A local run acquires a state lock, risking collisions with CI pipelines or leaving dangling locks.
   - Local runs bypass the audited Workload Identity Federation (WIF) service account
     (`hop-deploy@hop-mesh.iam.gserviceaccount.com`).
   - Local plans require live GCP read permissions across Compute, Cloud Run, Secret Manager,
     and Firestore data sources.
2. **How to produce a safe, read-only plan**:
   The safe method is to run a speculative plan within GitHub Actions in `hopmesh/hop`:
   - Trigger a pull request or manual dispatch workflow that authenticates via WIF as `hop-deploy`.
   - Run `tofu plan -input=false -no-color -lock=false` against the target configuration.
   - Inspect the plan artifact in GitHub Actions to verify that resources are created without
     destructive cycles or unexpected changes.

## The destroy-time cycle safety mechanism

Emptying the regions list without proper precautions can deadlock OpenTofu. In
`load_balancer.tf`, the load balancer chain is `count`-gated on
`var.relays_enabled` as a unified set rather than backend-by-backend.

Why this matters:
If the anycast backend service were updated in place to zero backends while the URL map still
referenced it, and the regional network endpoint groups (NEGs) were simultaneously destroyed,
OpenTofu would encounter a dependency cycle.

The coded solution:
The entire relay HTTPS chain (anycast backend, URL map, target HTTPS proxy, and :443 forwarding rules)
is destroyed together as one count-gated set when `relays_enabled = false`. A parallel off-state
chain (`url_map.off`, `google_compute_target_https_proxy.off`, and forwarding rules) takes over :443
to keep `example.hopme.sh` reachable on the same anycast IP.

Operator rule:
Never partially gate this chain. Keep the entire relay load balancer chain on the unified
`count = var.relays_enabled ? 1 : 0` gate.

## Step-by-step operational sequence

Follow this sequence in order. Do not skip steps.

### Preparation phase (Engineer)

1. In `hopmesh/hop`, verify that `runtime-deploy.yml` forwards `TF_VAR_alert_email`:
   ```yaml
   TF_VAR_alert_email: ${{ vars.ALERT_EMAIL || '' }}
   ```
2. Verify that `dns.tf` includes the DNS record for `status.hopme.sh`
   pointing to the active status provider.
3. Confirm `services/hop-relayd` in `hopmesh/hop` is ready for deployment. No operational action may target `hopmesh/monorepo`.

### Authorization phase (Owner inputs)

4. The owner adds the repository variable `ALERT_EMAIL` in `hopmesh/hop`:
   Value: `[OWNER: valid email address for relay operational alerts, e.g. ops@hopme.sh]`
5. The owner reviews region quotas and adds the repository variable `RELAY_REGION_ALLOWLIST` in `hopmesh/hop`:
   Value: `[OWNER: target region allowlist JSON array, e.g. '["us-central1", "europe-west1", "asia-east1"]' or '[]' for all available regions, and spend commitment]`
6. The owner authorizes enabling the fleet by updating the repository variable `RELAYS_ENABLED` in `hopmesh/hop`:
   Value: `[OWNER: set repository variable RELAYS_ENABLED=true in hopmesh/hop Settings -> Secrets and variables -> Actions; do not target archived hopmesh/monorepo]`

### Verification and rollout phase (CI and Operator)

7. Trigger `runtime-deploy.yml` in `hopmesh/hop` by merging an authorized commit to `main`
   or via the workflow dispatch trigger. No deployment may run from `hopmesh/monorepo`.
8. Monitor the `runtime-deploy.yml` Actions run:
   - Ensure the four container images build and push successfully.
   - Confirm `tofu apply` completes with exit code 0.
9. Validate network routing and endpoint health:
   - Verify anycast IP resolution: `dig +short relay.hopme.sh`
   - Verify TLS certificate status: `curl -sI https://relay.hopme.sh/`
   - Check status page resolution: `dig +short status.hopme.sh`
   - Check Cloud Run service revisions in the Google Cloud Console (`hop-mesh` project).
10. Confirm alert policies are active in Google Cloud Monitoring.

## Rollback procedure

If delivery fails, an identity mismatch occurs, or unexpected billing spikes arise:

1. **Immediate variable revert**:
   In `hopmesh/hop`, set the repository variable `RELAYS_ENABLED` to `false`. Do not target `hopmesh/monorepo`.
2. **Trigger re-deployment**:
   Re-run the latest `runtime-deploy.yml` workflow run or push an empty commit to `main` in `hopmesh/hop`.
3. **Verify clean teardown**:
   - `tofu apply` will destroy regional Cloud Run relay services, NEGs, and the on-state URL map.
   - The off-state URL map will resume serving `example.hopme.sh` on the same anycast IP.
   - The anycast IP addresses, wildcard certificate, and DNS records remain preserved.
4. **Confirm safe off state**:
   `curl -sI https://relay.hopme.sh/` will cease WebSocket routing while `example.hopme.sh` remains healthy.
