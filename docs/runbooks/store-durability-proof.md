# Runbook: Store Durability Proof & Live Firestore Procedure

This runbook documents the durability claims of Hop persistence layers, their
automated verification in the repository test harness, and the operational
procedure for executing a live Firestore validation on Google Cloud Platform.

## 1. Durability Claims

The design of Hop persistence across device stores (`SqliteStore`) and the
cloud relay backbone (`FirestoreStore`) rests on six core durability claims.

### Claim 1: Single-Writer Exclusive Lease (STORE-002)
* Cross-process: An exclusive OS lock (`flock(LOCK_EX | LOCK_NB)`) on a sidecar
  `.lock` file guarantees that only one process can open a database file at any
  time. A second concurrent opener in another process is refused immediately
  with an error rather than corrupting state.
* In-process: A process-wide path registry (`ProcessPathLease`) refuses second
  openers within the same process on the same canonical path with `SQLITE_BUSY`.
* Crash recovery: When a process holding the lease dies abruptly (via SIGKILL,
  panic, or power cut), the operating system releases the file lock descriptor
  automatically, allowing subsequent openers to recover the database without
  manual intervention.
* Keyed parity: This lease applies identically to plaintext and SQLCipher-encrypted
  databases.

### Claim 2: Crash Atomicity and Zero Torn State (STORE-001, STORE-005)
* Atomic commits: Multi-key batches (`apply_kv_batch`) and critical mutations
  (`put_kv_critical`, `put`, `rehydrate`) are fully transactional.
* In-flight interruption: If a process is terminated with SIGKILL (kill -9) or
  experiences power loss during a write transaction, reopening the database
  triggers SQLite WAL recovery. Incomplete transactions are rolled back in full,
  leaving zero torn state.
* Committed atoms: All transactions committed before the crash are preserved
  without data loss.
* Critical barrier: Critical WAL writes use `PRAGMA synchronous = FULL` to ensure
  frames are flushed and synced to physical storage before reporting success,
  preventing rollback across power failures.

### Claim 3: Unclean Shutdown with WAL Replay
* Surviving WAL frames: If an application process terminates uncleanly without
  calling `flush` or cleanly closing the SQLite database connection, committed
  frames residing in the `-wal` file remain valid.
* Automatic recovery: On subsequent open, SQLite detects the active WAL file and
  replays all valid committed frames into the database, restoring full state.

### Claim 4: WAL Checkpoint Truth and Disk Persistence via Flush (STORE-001, STORE-013)
* Checkpoint verification: `Store::flush(timeout)` executes `PRAGMA wal_checkpoint(PASSIVE)`
  and inspects the resulting `(busy, log, checkpointed)` tuple.
* Truthful reporting: `flush` returns `true` only when `busy == 0` and all logged
  frames have been checkpointed to the main database file (`checkpointed >= log`
  or `log <= 0`).
* Contention handling: Under reader contention, uncheckpointed frames cannot be
  moved past the reader lock. `flush` polls until `timeout` and returns `false`,
  refusing to report success prematurely.
* Disk persistence: When `flush` returns `true`, the data physically resides in
  the main database file on disk. If the database file is copied in isolation
  without the `-wal` sidecar, the flushed state is present.

### Claim 5: SQLCipher At-Rest Encryption & Key Enforcement (F-25, ABI-014)
* Full-page encryption: With `--features sqlcipher`, `open_keyed` encrypts every
  page at rest with the supplied 32-byte key.
* Key hygiene: The hex-formatted key buffer is zeroized on drop.
* Fail closed: Without `--features sqlcipher`, `open_keyed` with a non-empty key
  fails closed, refusing plaintext fallback.
* Parity: All durability guarantees (single-writer lease, kill -9 recovery,
  unclean shutdown WAL replay, and flush checkpointing) hold under SQLCipher.

### Claim 6: Backbone Collections & Data Protection (DESIGN.md Section 33)
* Exhaustive collections: User-derived data at rest exists only in designated
  Firestore collections:
  - `relays/{node}/bundles`: sealed ciphertext bundles, TTL evicted via `expireAt`.
  - `relays/{node}/kv`: opaque values with cleartext keys for ratchet sessions,
    carrier streams, and dedup markers. TTL policy on `expireAt`. Billing ledger
    and telemetry markers are exempt from cleanup.
  - `presence/{index}`: coarse region and heartbeat keyed by fleet `PresenceIndex`.
  - `mailboxes/{mailbox-tag}/bundles`: blind mailbox spool keyed by rotating pseudonyms.
  - `relays/{node}/operations` and `relays/{node}/control/critical-operation-fence`:
    batch idempotency journal.
  - `registry/{node}`: relay liveness registry.
  - `tenants/{tenant-hex}`: tenant commercial registry.

---

## 2. Automated Verification in the Repository

The durability claims are verified by automated tests in `core/stores/hop-store-sqlite`
and `core/stores/hop-store-firestore`:

```sh
# Plain SQLite store tests (30 tests)
cargo test -p hop-store-sqlite

# SQLCipher encrypted store tests (38 tests)
cargo test -p hop-store-sqlite --no-default-features --features sqlcipher

# Firestore local mirror and contract tests (95 tests)
cargo test -p hop-store-firestore

# Relay daemon store integration (108 tests)
cargo test -p hop-relayd --features firestore
```

Key test implementations in `core/stores/hop-store-sqlite/src/lib.rs`:
* `kill_9_during_write_proves_no_torn_state_and_no_lost_committed_atom`:
  Spawns a child process that commits a baseline atom, starts a multi-row write,
  and receives SIGKILL (kill -9) mid-transaction. Reopening proves the uncommitted
  write was rolled back with no torn state, while the committed atom is intact.
* `kill_9_during_write_proves_no_torn_state_and_no_lost_committed_atom_sqlcipher`:
  Verifies identical kill -9 crash recovery on a SQLCipher encrypted database.
* `second_concurrent_opener_refused_rather_than_corrupting`:
  Proves that while an active `SqliteStore` holds the database open, a child
  process attempting to open the same database path is refused with code 42
  (lock failure). Conversely, while a child holds the database, parent open is
  refused.
* `second_concurrent_opener_refused_rather_than_corrupting_sqlcipher`:
  Proves cross-process second concurrent opener refusal on SQLCipher databases.
* `unclean_shutdown_wal_replay_recovers_committed_state`:
  A child writes committed atoms and exits abruptly via `std::mem::forget(store)`,
  bypassing flush and connection teardown. The parent verifies that frames were
  persisted to the WAL file, that an isolated copy of the main database without
  WAL lacks the data, and that reopening triggers WAL replay to recover all
  committed rows.
* `unclean_shutdown_wal_replay_recovers_committed_state_sqlcipher`:
  Proves unclean shutdown WAL replay on an encrypted database under SQLCipher.
* `flush_return_value_checked_against_disk_persistence`:
  Proves that before `flush`, data exists only in WAL; after `flush` returns `true`,
  the data physically exists in the main database file on disk. Verifies that under
  reader contention, `flush` returns `false` and frames do not reach the main file
  until the lock is released.
* `flush_return_value_checked_against_disk_persistence_sqlcipher`:
  Proves disk checkpoint truth for `flush` on SQLCipher databases.

---

## 3. Live Firestore Verification Procedure (Owner-Held)

Production Firestore tests require live Google Cloud infrastructure and
credentials that are held exclusively by the repository owner. This procedure
describes how to perform an end-to-end live exercise against GCP.

### Prerequisites & Credentials
* Target GCP project: `hop-mesh` (or a dedicated staging project `hop-mesh-test`).
* Database: `(default)` in multi-region `nam5` (US).
* Service account credentials: A service account with the `roles/datastore.user`
  IAM role.
* Workstation authentication:
  ```sh
  gcloud auth application-default login
  gcloud config set project hop-mesh
  ```

### Estimated Cost
* Scale of exercise: Approximately 500 document writes, 500 document reads, and
  500 document deletes.
* Google Cloud Firestore pricing: Free tier includes 50,000 reads, 20,000 writes,
  and 20,000 deletes daily.
* Net cost: $0.00 (within free tier allowance). Outside free tier: < $0.01.

### Target Collections
The live exercise writes to an isolated test node partition:
* `relays/live-audit-test-node/bundles`
* `relays/live-audit-test-node/kv`
* `relays/live-audit-test-node/operations`
* `presence/live-audit-test-index`

### Step-by-Step Live Execution Procedure
1. Acquire a fresh access token:
   ```sh
   export FIRESTORE_PROJECT_ID="hop-mesh"
   export FIRESTORE_ACCESS_TOKEN="$(gcloud auth print-access-token)"
   export HOP_TEST_NODE_ID="live-audit-test-node"
   ```

2. Execute the live store driver suite:
   ```sh
   cargo test -p hop-store-firestore --features firestore-live -- --nocapture
   ```

3. Validate live persistence and scale-to-zero survival:
   * Verify that bundles written by the driver are queryable in Cloud Console:
     `Firestore Studio -> relays -> live-audit-test-node -> bundles`.
   * Stop the local process, wait 30 seconds, and reopen the store.
   * Verify that rehydration recovers the remote bundles and KV sessions.

4. Post-Exercise Cleanup:
   Delete the test documents to leave zero residual data:
   ```sh
   # Delete the test node collections
   gcloud firestore operations-delete-documents \
     --collection-path="relays/live-audit-test-node/bundles" \
     --project="hop-mesh" --quiet || true

   gcloud firestore operations-delete-documents \
     --collection-path="relays/live-audit-test-node/kv" \
     --project="hop-mesh" --quiet || true

   # Verify collection is empty
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     "https://firestore.googleapis.com/v1/projects/hop-mesh/databases/(default)/documents/relays/live-audit-test-node/bundles"
   ```

---

## 4. Offline Substitute: Local Firestore Emulator

When GCP credentials are not available, the Google Cloud Firestore Emulator
serves as the offline substitute:

```sh
# 1. Start the emulator on localhost
gcloud emulators firestore start --host-port=127.0.0.1:8080 &
EMULATOR_PID=$!

# 2. Point client to emulator
export FIRESTORE_EMULATOR_HOST="127.0.0.1:8080"
export FIRESTORE_PROJECT_ID="hop-emulator-test"

# 3. Run store test suite against emulator
cargo test -p hop-store-firestore

# 4. Terminate emulator
kill $EMULATOR_PID
```
