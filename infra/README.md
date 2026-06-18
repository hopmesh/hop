# infra — Hop relay fleet (path B)

Terraform for the scale-to-zero, multi-region cloud backbone (DESIGN.md §19, §21).

## What it builds

One **global external Application Load Balancer** (single anycast IP + one DNS name)
in front of a **Cloud Run relay in each region**. Premium-tier routing sends every
device to its nearest healthy region — the "one DNS, many nodes, closest
entrance/exit, lowest latency" model.

All regions share **one identity** (Secret Manager) and **one Firestore store**, so
they are the *same* logical Hop node: a bundle sealed into the store in one region
is delivered from any other. Idle regions scale to **zero** and cost nothing until
the first WebSocket connection arrives.

```
device ──wss──▶ relay.hopme.sh (anycast) ──▶ nearest Cloud Run region
                                                  │
                                          Firestore (shared per-node store)
                                                  │
device ◀──wss── nearest Cloud Run region ◀────────┘
```

## Files

| File | Purpose |
|------|---------|
| `apis.tf` | Enable required Google APIs |
| `artifact_registry.tf` | Docker repo for the image |
| `firestore.tf` | Native Firestore DB + TTL eviction on `bundles` |
| `secrets.tf` | Shared relay identity seed (container only; seeded by hand) |
| `iam.tf` | Cloud Run runtime SA (least privilege) |
| `cloud_run.tf` | Per-region relay service, min=0, LB-only ingress |
| `load_balancer.tf` | Global LB: NEGs, backend, URL map, managed cert, IP, :80→:443 |
| `dns.tf` | Optional Cloud DNS record (off by default — DNS is external) |
| `outputs.tf` | LB IP, the A record to add, the `wss://` endpoint |

## First deploy

1. **Seed the identity once** (32 random bytes; rerunning rotates the relay address):
   ```sh
   make seed-identity            # or see secrets.tf for the raw gcloud command
   ```
2. **Build & push** the image, then **apply**:
   ```sh
   make auth
   make apply                    # builds linux/amd64, pushes, terraform apply
   ```
   Or with Spacelift: push the image in CI, set `relay_image` as a stack var, let
   the stack apply.
3. **Add DNS by hand** (hopme.sh DNS is off-GCP). `terraform output dns_setup`
   prints the record:
   ```
   A  relay.hopme.sh  ->  <anycast IP>
   ```
   The managed TLS cert goes ACTIVE a few minutes after the record resolves.
4. Point a device's **Cloud relay** field at `wss://relay.hopme.sh/`.

Once hopme.sh is delegated to Cloud DNS, set `manage_dns = true` and step 3 is
automated.

## Pending code dependency

The image runs `hop-relayd --ws … --identity-file …`. The current daemon only has
the raw-TCP bearer (`--listen`) used by the path-A VM. Before this fleet serves
traffic, hop-relayd needs:

- a **WebSocket bearer** listening on `$PORT` (Noise XX over WS frames), and
- `--identity-file` (load the 32-byte seed from the mounted secret) and reading
  `--firestore` for the durable store.

The Cloud Run env (`HOP_FIRESTORE_PROJECT`, `HOP_IDENTITY_FILE`, `PORT`) is already
wired in `cloud_run.tf` to match that interface.

## Note on path A

The live single-VM relay (`136.112.28.210:9443`, raw TCP) is **not** managed here —
it was created directly for validation. This module is the durable, scalable
replacement. Decommission the VM once the fleet is serving traffic.
```
gcloud compute instances delete hop-relay-1 --zone us-central1-a --project hop-mesh
```
