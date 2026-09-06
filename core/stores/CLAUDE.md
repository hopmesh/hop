# core/stores

Persistence adapters for Hop behind the `Store` trait (`hop-core::store::Store`).

## Stores

- `hop-store-sqlite`: Device-local SQLite and SQLCipher store. Requires an application-level
  at-rest encryption key (`open_keyed`) on user devices to defend against local extraction.
- `hop-store-firestore`: Relay-tier persistent store backed by Google Cloud Firestore, designed
  to survive scale-to-zero. Bundles and eager KV state rehydrate on startup; carrier streams
  rehydrate in bounded pages.

## Durable KV Surface and Retention Policy (DESIGN.md section 33, CLAIM-020)

Relay nodes mirror state to `relays/{node}/kv`. Values are opaque bytes; keys are indexed strings:

- `session/<peer-pubkey>`: Forward-secret session state. Retention is 30 days, matching
  `SESSION_MAX_IDLE_MS` in `hop-core::node`. Idle sessions past 30 days are pruned from memory
  and store. If an idle peer returns, the session re-establishes with a fresh prekey.
- `strm/<sender-pubkey>/...`: Carrier stream chunks. Retention is 24 hours, matching
  `CARRIER_STREAM_LIFETIME_MS` in `hop-core::node`. Chunks past 24 hours are abandoned.
- `inbox-seen/<bundle-id>`: Received bundle deduplication markers. Retention is 7 days, matching
  `MAX_SEEN_LIFETIME_MS` in `hop-core::store`.
- Other transient relay KV rows: Default retention is 30 days.
- Financial ledger rows (`usage/`, `carriage_usage/`, `storage_usage/`, `telemetry_usage/`, `journal/`)
  and `telemetry_seen/` deduplication markers are exempt from TTL and store-side sweeping. They
  persist until their respective domain reconcilers sweep them.

### Mechanism

1. **Firestore TTL Policy**: Every non-exempt KV document carries an `expireAt` timestampValue
   field (RFC3339 UTC) and an `expiresAt` integerValue epoch-ms field written by `kv_doc_json`.
2. **Store-Side Bounded Sweep**: `FirestoreStore::sweep_expired_kv` runs during `prune` (on every
   relay tick), deleting at most `FIRESTORE_KV_SWEEP_PAGE_SIZE` (100) expired rows per tick.
   The sweep is idempotent and strictly excludes financial ledger and telemetry seen keys.
