# Runbook: enable / disable the relay fleet

The relay fleet (one Cloud Run relay per Google region, ~42 regions, behind a
single anycast load balancer) is controlled by ONE Terraform variable:
`relays_enabled`. This runbook is how you flip it safely and what to watch for.

## The one-line switch

The live value is set in `hopmesh/platform/infra/cloudbuild.trigger.yaml` in the `apply` step env:

```yaml
- 'TF_VAR_relays_enabled=false'   # P2P-only test phase (fleet OFF)
```

- `false` = fleet OFF. All regional relay Cloud Run services, their NEGs,
  backends, and IAM are destroyed. The anycast IP, wildcard cert, DNS, Firestore,
  and the example endpoint stay up.
- `true` = fleet ON. The fleet is re-applied on the SAME anycast IP + cert + DNS.

Because the IP, cert, and DNS survive an OFF cycle, re-enabling does NOT require
clients to learn a new endpoint. `relay.hopme.sh` stays stable across the flip.

## To re-enable the fleet

1. Edit `hopmesh/platform/infra/cloudbuild.trigger.yaml`, change the line to
   `TF_VAR_relays_enabled=true`.
2. Validate locally BEFORE pushing (this is the guardrail that catches the
   destroy-time cycle described below):
   ```sh
   cd hopmesh/platform/infra
   tofu init -input=false
   tofu plan -input=false \
     -var 'project_id=hop-mesh' \
     -var 'relays_enabled=true' \
     -var 'region_allowlist=[]' \
     -var 'deploy_image_sha=<a-real-pushed-sha>'
   ```
   Read the plan. On a clean enable you expect the relay backend, url_map, https
   proxy, forwarding rules, and per-region services/NEGs to be CREATED, and NO
   resource to be both created-and-destroyed in a way that forms a cycle. If
   `tofu plan` reports a cycle error, STOP and see the cycle section below.
3. Push to `main`. Cloud Build builds + pushes both images and runs `tofu apply`.
4. Confirm: `curl -sN https://relay.hopme.sh/` should start streaming activity as
   devices connect. Regional health: check Cloud Run in the console for green
   revisions across regions.

## To disable the fleet

1. Edit `hopmesh/platform/infra/cloudbuild.trigger.yaml`, change the line to
   `TF_VAR_relays_enabled=false`.
2. `tofu plan` locally (same command, `relays_enabled=false`). Expect the WHOLE
   relay HTTPS serving chain to be destroyed as one set, and the url_map to fall
   back to the example backend as the LB default.
3. Push to `main`.

## The destroy-time cycle gotcha (read before touching this)

Emptying the regions naively deadlocks OpenTofu. The load balancer chain is
`count`-gated on `var.relays_enabled` as a WHOLE, not backend-by-backend, on
purpose. See `hopmesh/platform/infra/load_balancer.tf`.

Why: if the anycast backend service were left as an in-place UPDATE to "zero
backends" while the url_map still references it AND the per-region NEGs it points
at are being destroyed, that forms a Terraform destroy-time cycle. A conditional
or alternate url_map does not help, because `x ? on[0] : off[0]` statically
references BOTH branches.

The fix already in the code: the entire relay HTTPS chain (anycast backend, the
url_map, the https proxy, the :443 forwarding rules) is destroyed together as one
count-gated set. Destroying the whole chain has no
"in-place-update-referencing-a-destroyed-resource" edge, so there is no cycle.

Operator rule: never partially gate this chain. If you need to change relay LB
resources, keep the entire chain on the same `count = var.relays_enabled ? 1 : 0`
gate, and always `tofu plan` before applying. The first execution of an infra
change must not be the production apply (see `docs/runbooks/incident-response.md`
and the release-engineering doc for the validation gate).

## Related config to check when re-enabling

Re-enabling the fleet does NOT automatically restore everything you probably want
in production. Verify these, all currently unset in the live trigger:

- `TF_VAR_alert_email` is empty, so ALL alerting is off (crash loops, Firestore
  failures, and 429 wake-churn are invisible). Set it before or with the enable.
  See `hopmesh/platform/infra/observability.tf`.
- `TF_VAR_relay_identity_version` defaults to `latest`. If a new secret version
  was ever created, cold-starting regions will pick it up and split-brain the
  fleet identity. Pin it to a specific version number for a production enable.
  See `hopmesh/platform/infra/variables.tf` and `docs/runbooks/incident-response.md`.
- `TF_VAR_cloud_run_ingress=INGRESS_TRAFFIC_ALL` means `*.run.app` URLs bypass the
  anycast LB. Switch to `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER` once the LB is the
  intended single front door.
- Client apps default `relaysEnabled=true` and will dial `wss://relay.hopme.sh`
  regardless. With the fleet OFF they retry-loop on a dead endpoint (battery /
  network waste). That is expected during the P2P test phase.

## Do NOT

- Do not raise `max_instances_per_region` to "fix" 429s. See
  `docs/runbooks/quota-and-429.md`; raising it is worse than the 429s.
- Do not re-seed the relay identity (`make seed-identity`) to enable the fleet.
  Re-seeding ROTATES the relay address and orphans Firestore partitions / registry
  entries. Idempotency is on you.
