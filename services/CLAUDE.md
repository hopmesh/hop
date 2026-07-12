# services/

The Rust daemons. Deployed to Cloud Run via the GitOps pipeline (see `infra/CLAUDE.md`).

```
services/hop-relayd    the relay: the most internet-exposed process, accepts connections from any mesh
                       node worldwide with no prior trust. WS + raw TCP; Firestore-backed spool/mailbox.
services/hop-endpoint  the hops:// internet-egress endpoint (fetches on behalf of the mesh)
services/hop-gateway   the gateway
```

## Invariants (do not regress)

- **Panic isolation.** Every core call on attacker-controlled bytes (`node.handle(BearerEvent::Data)`, `ingest`, `provide_dns_proof`, `tick`, `drain_outgoing`) runs under `guard_core` (catch_unwind), so a panic on a hostile bundle becomes a logged skip, not a process kill. All three services have this; relayd's was added in the pass-18 F-2 fix. `on_bundle`'s multi-mutation arms are structured compute-then-commit so a caught panic cannot leave paired bookkeeping half-applied (F-18d).
- **Per-peer fairness (relayd).** Frames are rate-capped per authenticated node identity (the Noise static key, NOT client IP, which is useless behind the LB). Pre-handshake frames share one bounded bucket; the key map is hard-bounded against fresh-identity churn (pass-18 F-18a/F-18b). Do not key on IP.
- Frame length is capped (`MAX_FRAME_BYTES`) before allocation; connection count is capped (`MAX_CONNS`).

## Verify

`cargo test -p hop-relayd` and `--features firestore` (the cloud path). `cargo test -p hop-endpoint -p hop-gateway`. Stores: `cargo test -p hop-store-sqlite --no-default-features --features sqlcipher`. The deploy gate (`infra/cloudbuild.trigger.yaml`) blocks `tofu apply` until CI is green for the commit.
