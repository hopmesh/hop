# infra: Hop relay fleet (path B)

Terraform for the scale-to-zero, multi-region cloud backbone (DESIGN.md §19, §21).

## What it builds

One **global external Application Load Balancer** (single anycast IP + one DNS name)
in front of a **Cloud Run relay in each region**. Premium-tier routing sends every
device to its nearest healthy region: the "one DNS, many nodes, closest
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

## Deploy gate + branch protection

Deploy is GitOps: a push to `main` triggers the Cloud Build run in
`cloudbuild.trigger.yaml`, which builds + pushes the images and then runs
`tofu apply` against the fleet. Two layers keep a bad commit off the fleet:

1. **Runtime gate (in code).** The trigger's `require-ci` step blocks `apply` until
   the GitHub CI workflow (`.github/workflows/ci.yml`) reports success for that exact
   commit: tests, clippy, wire-format/header-drift guardrail, the Android/Apple/WASM
   compile gates, and the Terraform `fmt`/`validate`/`plan`. It fails closed, so if CI
   fails, never ran, or is unreachable, the fleet stays on the previous good commit
   (infra-01 / quality-net-09). CI validates infra, but the authoritative prod plan
   runs inside this trigger, right before apply, with the deploy SA's credentials.

2. **Intent gate (repo settings, not code).** No file can turn on branch protection,
   so it must be set once in GitHub `Settings -> Branches` for `main`:
   - Require a pull request before merging.
   - Require status checks to pass, selecting every `CI / ...` check
     (Rust, Kotlin SDK, Android, Apple, WASM, Web + sim, Contract, Terraform, Docs token guard).
   - Require branches to be up to date before merging.
   This stops a red commit from reaching `main` at all; layer 1 is the backstop if it
   somehow does.

### Build SA privilege: accepted residual (infra-r3-03)

The build identity (`hop-cloudbuild`, defined in `cloudbuild_trigger.tf`) runs
`tofu apply -auto-approve` on every push to `main`, so it holds `roles/editor` plus
several admin roles (`resourcemanager.projectIamAdmin`, `iam.serviceAccountAdmin`,
`run.admin`, `storage.admin`, `logging.admin`, `cloudbuild.connectionAdmin`). This is
broad **by necessity**: the module manages project-level IAM bindings (relay SA roles,
the build SA's own roles), and `resourcemanager.projects.setIamPolicy` has no
resource-scoped substitute.

- **Already closed:** the seed-reading grant (`secretmanager.admin` /
  `versions.access`) was removed in favor of a scoped custom role, so the pipeline can
  no longer read the relay identity root seed (infra-02).
- **Residual:** `projectIamAdmin` retains a theoretical "grant self owner" path on a
  single bad/compromised `main` commit under `-auto-approve`. Today this is bounded by
  single-maintainer + required-main-push + the runtime CI deploy gate above, and is not
  reachable without a malicious commit landing.
- **Mitigation before production:** gate IAM-touching TF changes behind
  plan-then-approve instead of `-auto-approve` on every push (e.g. a manual approval
  step on the `apply` when the plan changes `google_project_iam_*`). Not applied now:
  it would change the fully-automated GitOps flow this stack is built around, and the
  bounding controls above are sufficient for the pre-prod P2P test phase.

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
| `dns.tf` | Cloud DNS zone + relay/wildcard records for hopme.sh (always managed here) |
| `outputs.tf` | LB IPs, the `name_servers` to delegate, the `wss://` endpoint |

## Deploy

The normal path is **GitOps**: push to `main`, and the Cloud Build trigger
(`cloudbuild.trigger.yaml`) builds + pushes the images, waits for CI to go green
(the runtime gate above), then runs `tofu apply`. There is no Spacelift and no
manual apply in the normal flow.

For a one-off **local** apply from your machine (e.g. bootstrapping):

1. **Seed the identity once** (32 random bytes; rerunning rotates the relay address):
   ```sh
   make seed-identity            # or see secrets.tf for the raw gcloud command
   ```
2. **Build & push** the image, then **apply**:
   ```sh
   make auth
   make apply                    # builds linux/amd64, pushes, tofu apply
   ```
3. **Delegate DNS.** hopme.sh DNS is managed by this module (`dns.tf`): the zone
   and all records (relay/wildcard/pages/mail) are created here. Point the
   registrar's nameservers at the `name_servers` output:
   ```sh
   tofu output name_servers
   ```
   Once delegation propagates, the managed TLS cert goes ACTIVE within minutes and
   `wss://relay.hopme.sh/` resolves.
4. Point a device's **Cloud relay** field at `wss://relay.hopme.sh/`.

The relay image already runs the **WebSocket bearer** (`--ws 0.0.0.0:8080`, Noise XX
over WS frames) on `$PORT`, loads its identity from the mounted secret
(`--identity-file`), and uses Firestore for the durable store (`--firestore`); the
Cloud Run env (`HOP_FIRESTORE_PROJECT`, `HOP_IDENTITY_FILE`, `PORT`) is wired in
`cloud_run.tf` to match.

## Note on path A

The live single-VM relay (`136.112.28.210:9443`, raw TCP) is **not** managed here:
it was created directly for validation. This module is the durable, scalable
replacement. Decommission the VM once the fleet is serving traffic.
```
gcloud compute instances delete hop-relay-1 --zone us-central1-a --project hop-mesh
```
