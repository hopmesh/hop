# Runbook: incident response (relay fleet)

Use this when delivery is failing, a region is crash-looping, or the fleet is
otherwise misbehaving. The fleet is honest-but-curious infrastructure; it stores
sealed bundles and routes toward recipients. It cannot read content, so an
incident is about availability and metadata, not message confidentiality.

## First 5 minutes: triage

1. Is the fleet even supposed to be on?
   ```sh
   grep relays_enabled infra/cloudbuild.trigger.yaml
   ```
   If `false`, the fleet is intentionally torn down (P2P test phase). "No relay
   delivery" is expected, not an incident. Clients still dial and retry-loop.
2. Is the anycast endpoint answering?
   ```sh
   curl -sN https://relay.hopme.sh/     # streaming activity log
   ```
   No connection at all points at the LB / cert / DNS layer (which survives an OFF
   cycle). Activity streaming but delivery failing points at Firestore or a region.
3. Which regions are unhealthy? Check Cloud Run in the console (project `hop-mesh`)
   for revisions that are erroring or stuck. 5xx / 429 spikes are the "Relay Cloud
   Run 5xx/429" signal (see `infra/observability.tf`).

Note on the activity log: `curl -sN https://relay.hopme.sh/` is an UNAUTHENTICATED
live stream and it leaks relay traffic metadata to anyone who hits it. Treat the
URL and its output as sensitive during an incident; do not paste it into public
tickets. Locking this stream down is a tracked services hardening item.

## Common incidents

### A region crash-loops on cold start

Likely causes, in order:

- Identity split-brain. If a new relay identity secret version was created,
  regions cold-starting with `relay_identity_version=latest` pick up a DIFFERENT
  identity and orphan their Firestore partition / registry entries. Fix: pin
  `TF_VAR_relay_identity_version` to the KNOWN-GOOD version number in
  `infra/cloudbuild.trigger.yaml`, then push to `main`. Do not re-seed.
- Firestore IAM / quota failure. Handoff, presence, and §39-P5 pull all just log
  "... FAILED" and keep serving degraded. Check the runtime SA's Firestore perms
  and Firestore quota. With alerting off (`alert_email` empty) these are silent, so
  you will only see them in Cloud Run logs.
- A bad image. The deploy pins images to `$SHORT_SHA`. Roll back by pushing a
  revert commit to `main` (GitOps re-applies with the reverted image), or in an
  emergency, deploy a known-good SHA by editing `TF_VAR_deploy_image_sha` and
  pushing. Prefer the revert.

### Delivery works region-locally but not cross-region

All regions share ONE identity and ONE Firestore store, so a bundle sealed in one
region should deliver from any other. If cross-region delivery fails but same-region
works, suspect identity split-brain (above) or a Firestore partition problem, not
routing.

### Half-applied infra (LB / fleet in a mixed state)

This is the destroy-time-cycle failure mode. If a `tofu apply` errored partway and
left the LB chain half-built:

1. Do NOT push more changes on top.
2. `cd infra && tofu init && tofu plan` to see the actual drift.
3. Re-apply the SAME `relays_enabled` value you intended (do not toggle it mid-
   recovery). The chain is designed to converge when the whole count-gated set is
   applied together. See `docs/runbooks/relay-enable-disable.md` for the cycle
   explanation.

## Rollback

The fastest safe rollback is a git revert on `main`: it re-runs Cloud Build, which
rebuilds from the reverted source and re-applies Terraform with the reverted image
SHA. Because state lives in `gs://hop-mesh-tfstate`, the apply reconciles the fleet
back to the reverted definition.

For an infra-only mistake (Terraform, no code change), revert the `infra/` commit
and push; the same trigger re-applies.

## After the incident

- If alerting was off and you flew blind, set `TF_VAR_alert_email` now so the next
  one pages someone.
- Capture the timeline and root cause. If it was a code regression that CI would
  have caught, confirm CI is actually gating the deploy trigger (the wire-format /
  header-drift guardrails must block the apply, not just run alongside it).
- If it was a supply-chain / dependency issue, confirm `cargo deny check` (deny.toml)
  and Dependabot are running.
