# Runbook: incident response (relay fleet)

Use this when delivery is failing, a region is crash-looping, or the fleet is
otherwise misbehaving. The fleet is honest-but-curious infrastructure; it stores
sealed bundles and routes toward recipients. It cannot read content, so an
incident is about availability and metadata, not message confidentiality.

## First 5 minutes: triage

1. Is the fleet even supposed to be on? Check the repository variable in `hopmesh/hop` (the sole deploy authority; `hopmesh/monorepo` is archived and no operational action may target it):
   ```sh
   gh api /repos/hopmesh/hop/actions/variables/RELAYS_ENABLED --jq .value
   ```
   If empty or `false`, the fleet is intentionally torn down (P2P test phase). "No relay
   delivery" is expected, not an incident. Clients still dial and retry-loop.
2. Is the anycast endpoint answering?
   ```sh
   curl -sN https://relay.hopme.sh/     # streaming activity log
   ```
   No connection at all points at the load balancer, certificate, or DNS layer (which
   survives an OFF cycle). Activity streaming but delivery failing points at Firestore
   or regional Cloud Run instances.
3. Which regions are unhealthy? Check Cloud Run in the Google Cloud Console (project `hop-mesh`)
   for revisions that are erroring or stuck. Spikes in 5xx or 429 status codes trigger
   the "Relay Cloud Run 5xx/429" alert policy (defined in `observability.tf`).
4. Check the status page:
   Check `https://status.hopme.sh/` to confirm whether public incident status is already posted
   or if an outage needs to be declared.

Note on the activity log: `curl -sN https://relay.hopme.sh/` is an unauthenticated
live stream and it leaks relay traffic metadata to anyone who hits it. Treat the
URL and its output as sensitive during an incident; do not paste it into public
tickets. Locking this stream down is a tracked services hardening item.

## Common incidents

### A region crash-loops on cold start

Likely causes, in order:

- Identity split-brain: If a new relay identity secret version was created,
  regions cold-starting with `relay_identity_version=latest` pick up a different
  identity and orphan their Firestore partition and registry entries. Fix: pin
  `TF_VAR_relay_identity_version` to the known-good version number in
  the deploy workflow (`runtime-deploy.yml`, via repository variable
  `RELAY_IDENTITY_VERSION`), then trigger deployment. Do not re-seed. No operational command may target `hopmesh/monorepo`.
- Firestore IAM or quota failure: Handoff, presence, and pull operations log
  "FAILED" and serve degraded. Check the runtime service account's Firestore permissions
  and project quota. If `ALERT_EMAIL` is unset, these errors will not generate pages
  and must be diagnosed from Cloud Run logs.
- Defective image: The deploy pins container images to the commit SHA. Roll back by
  pushing a revert commit to `main` in `hopmesh/hop`, which re-builds and re-applies
  via `runtime-deploy.yml`. No push or deployment action may target `hopmesh/monorepo`.

### Delivery works region-locally but not cross-region

All regions share one identity and one Firestore database, so a bundle sealed in one
region should deliver from any other. If cross-region delivery fails but same-region
works, suspect identity split-brain (above) or a Firestore partition problem, not
routing.

### Half-applied infrastructure (load balancer or fleet in a mixed state)

This is the destroy-time-cycle failure mode. If a `tofu apply` errored partway and
left the load balancer chain half-built:

1. Do not push more changes on top immediately.
2. Inspect the failed job logs in GitHub Actions under `runtime-deploy.yml` in `hopmesh/hop`.
3. Re-run the pipeline with the same `relays_enabled` setting (do not toggle it mid-recovery).
   The chain is designed to converge when the complete count-gated set is applied
   together. See `docs/runbooks/relay-enable-disable.md` for the cycle explanation.

## Rollback

There are two primary rollback procedures depending on whether the issue is code or configuration:

1. **Fleet disable rollback (fastest operational mitigation)**:
   In `hopmesh/hop`, set the repository variable `RELAYS_ENABLED` to `false` and re-run
   `runtime-deploy.yml`. This tears down all regional Cloud Run services while keeping the anycast
   IP addresses and DNS records intact. No operational action may target `hopmesh/monorepo`.
2. **Code rollback (git revert)**:
   Revert the problematic commit on `main` in `hopmesh/hop` and push. This triggers
   CI, which upon success triggers `runtime-deploy.yml` to build from the reverted source
   and re-apply OpenTofu with the reverted image digest. Because state is stored in
   `gs://hop-mesh-tfstate/relay-fleet`, the apply reconciles the fleet cleanly.

## After the incident

- If alerting was unconfigured and operators were unaware of failures, ensure `ALERT_EMAIL`
  is set in `hopmesh/hop` repository variables so future incidents generate pages. Prior to the
  2026-09 cutover, variables historically resided in `hopmesh/monorepo` before that repository was archived.
- Capture the timeline and root cause in an incident report.
- Verify whether CI gates prevented or could have prevented the failure before deployment.
