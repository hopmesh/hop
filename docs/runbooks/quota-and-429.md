# Runbook: quota and 429 / wake-churn

Symptom: relay regions return HTTP 429, or you see "wake-churn" (regions being
woken and dialed repeatedly, cold-start storms, elevated 5xx). This is the D-429
class of issue. This runbook exists mostly to stop the wrong fix.

## The wrong fix (do NOT do this)

Do NOT raise `max_instances_per_region` to absorb 429s.

Each relay keeps presence and the bundle hot-path IN MEMORY per process. A second
instance in a region is a second, disconnected node: split-brain. Raising the
ceiling is WORSE than the 429s, not a fix. This is called out directly in
`hopmesh/platform/infra/variables.tf`:

> D-429: raising this is NOT the fix, it would be worse than the 429s.

`max_instances_per_region` stays pinned at `1` until the relay shares its
directory/store across instances (cross-instance directory/store sharing is a
separate project, not an ops lever).

## The actual causes and levers

There are two contributing causes; both are already mitigated by the default
config, so if you see 429/wake-churn, first confirm the defaults are still in place.

1. Relay-to-relay full-mesh dialing. Controlled by `mesh_fanout` in
   `hopmesh/platform/infra/variables.tf`. The safe default is `0` (handoff-only: regions do not
   dial each other, so no full-mesh wake storm). If someone raised it, a large
   value re-creates the 429 load. Lever: set `mesh_fanout = 0`, or a small value
   (2-3) at most for the partial-mesh epidemic. Never a large value.

2. Pull-on-wake dialing scaled-to-zero peers. Waking a sleeping region to pull
   held bundles within the registry TTL churns cold starts. The mesh fan-out is
   defined to dial only CURRENTLY-ONLINE peers (never wake a sleeping one), which
   is what keeps this bounded. Confirm no code path is waking sleeping peers.

## What to check when 429s appear

1. Are the defaults intact?
   ```sh
   grep -A2 'max_instances_per_region\|mesh_fanout' hopmesh/platform/infra/variables.tf
   grep 'TF_VAR_max_instances_per_region\|TF_VAR_mesh_fanout' hopmesh/platform/infra/cloudbuild.trigger.yaml
   ```
   Expect `max_instances_per_region = 1` and `mesh_fanout = 0` (or unset, which
   uses the safe defaults). If either was overridden, that is your regression.
2. Is the 429 coming from Cloud Run's own concurrency cap, or from downstream
   Firestore quota? Check the region's Cloud Run logs and Firestore quota in the
   console. Firestore throttling shows up as "... FAILED" log lines from handoff /
   presence / §39-P5 pull.
3. Do NOT add an external uptime check against the region endpoints. An external
   health probe WAKES the region on every check, which is itself a source of
   wake-churn (see the note in `hopmesh/platform/infra/cloud_run.tf`). Use the LB / Cloud Run
   built-in health, not an external pinger.

## If 429s persist with defaults intact

Then the region is genuinely over its single-instance concurrency for real
traffic, and the answer is NOT more instances (split-brain). The unlock is the
cross-instance directory/store sharing project. Until then, the region is at its
designed ceiling; escalate to that project rather than tuning the ceiling.

## Alerting

With `TF_VAR_alert_email` unset (its current state), the "Relay Cloud Run 5xx/429"
alert policy is not created, so 429/wake-churn is invisible until someone notices.
Set `TF_VAR_alert_email` when the fleet is on so this pages you. See
`hopmesh/platform/infra/observability.tf`.
