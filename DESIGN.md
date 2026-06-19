# Hop — Design

A delay-tolerant mesh network for intermittently-connected devices. Hop carries
**bundles** — self-contained, store-and-forward messages — across BLE links
between phones, relaying hop by hop until a bundle reaches either a **gateway**
(for the public internet) or a **destination device** (for peer messaging).

It is the [Bundle Protocol (RFC 9171)](https://www.rfc-editor.org/rfc/rfc9171.html)
lineage of Delay/Disruption Tolerant Networking, with a BLE bearer, a phone-shaped
routing layer, and an HTTP egress role.

---

## 1. Goals & non-goals

### Goals
- **Use Case A — internet egress.** A device with no internet emits a sealed HTTP
  request bundle. Any gateway node fulfills it, seals the response, and relays it
  back to the origin device key.
- **Use Case B — device-to-device.** A device sends a sealed message to another
  device's public key; the bundle hops until the destination receives it.
- **One core, two addressing modes.** Both use cases are the same machinery with
  different destinations. The Rust core ships both from day one; BLE comes after.
- **Confidential by default.** Relays carry ciphertext they cannot read.
- **Multi-platform.** Pure-Rust core, native BLE shims on iOS/Android via UniFFI.

### Non-goals (v1)
- Low-latency / real-time delivery. Hop is *eventually* delivered; lifetime is
  measured in hours-to-days, not milliseconds.
- Anonymity / metadata privacy at the Briar level. We encrypt payloads; we do not
  (yet) hide who-talks-to-whom from on-path relays. See §10.
- Exactly-once delivery. Impossible over a lossy partitioned network; we do
  at-least-once + idempotency. See §7.
- Non-BLE bearers in v1 (Wi-Fi Aware, MultipeerConnectivity, LoRa). The bearer is
  pluggable so they can be added; only BLE is in scope first.

---

## 2. System model & terminology

- **Node** — any device running Hop. Identified by an Ed25519 public key.
- **Device key / address** — a node's Ed25519 public key. The "device key" the
  product talks about *is* this key. 32 bytes; rendered as a short fingerprint.
- **Bundle** — the unit of store-and-forward. Self-contained, signed, sealed,
  with its own lifetime. The only thing that crosses links.
- **Link** — an established, authenticated BLE connection between two adjacent
  nodes. Carries frames (fragments of bundles).
- **Gateway** — a node advertising the `egress` capability: it has internet access
  and will fulfill internet-destined bundles.
- **Custodian** — the node currently responsible for retransmitting a bundle until
  it is handed off (custody transfer) or expires.

We assume nodes are **mobile, intermittently connected, and partially trusted**:
relays forward for strangers but must not be able to read or forge payloads.

---

## 3. Layering

```
┌─────────────────────────────────────────────────────────┐
│ Application   HTTP req/resp (A)  ·  peer message (B)       │
├─────────────────────────────────────────────────────────┤
│ Bundle        id · src · dst · lifetime · custody · seal   │  hop-core::bundle
├─────────────────────────────────────────────────────────┤
│ Routing       epidemic / spray-and-wait · gateway-gradient │  hop-core::routing
├─────────────────────────────────────────────────────────┤
│ Store         persistent forward queue · dedup · custody   │  hop-core::store
├─────────────────────────────────────────────────────────┤
│ Link          Noise session · fragmentation/reassembly     │  hop-core::link
├─────────────────────────────────────────────────────────┤
│ Bearer        BLE GATT (control) + L2CAP CoC (bulk)        │  native shim
└─────────────────────────────────────────────────────────┘
```

The layers below Application are all in `hop-core` (pure Rust, deterministic,
fully unit-testable without a radio). Only the Bearer is native per-platform.

---

## 4. Identity & crypto

- **One key = the address.** A node is a single Ed25519 keypair; its public key is
  the address. The X25519 keys for sealing/Noise are **derived** from it (SHA-512 +
  clamp for the secret; Montgomery form of the public key) — the standard
  Ed25519↔Curve25519 conversion (`crypto::address_to_x`, verified by
  `montgomery_correspondence`). So **an address is all you need** to both verify a
  peer's signatures *and* seal messages to it — no separate sealing key is exchanged
  or carried on the wire. This drops `src_x`/`publisher_x` from bundles/adverts and
  lets the Noise link bind the address by checking `address_to_x(address) ==
  authenticated static` (no extra signature). Addresses are shown in **base58**.
- **Layering:** the address (a public key) is the *only* identity the protocol knows.
  Human **common names / contacts are an app concern** (DESIGN.md §23), not part of
  the raw protocol — an app exchanges contact metadata over sealed messages and keeps
  its own local name↔address map (collisions allowed).
- **Long-term identity:** Ed25519 keypair per node. Public key = address.
- **Bundle authenticity:** the bundle header is signed by the source key. Anyone
  can verify origin; relays verify before forwarding to avoid amplifying garbage.
- **Confidentiality:** payload is sealed to the destination with a Noise-style
  X25519 + ChaCha20-Poly1305 box. Relays see headers (for routing) but not payload.
- **Link security:** each link runs a **Noise XX** handshake so adjacent nodes
  mutually authenticate and get a fresh symmetric session. This stops a passive BLE
  sniffer from even seeing which bundles transit a link, and lets nodes apply
  per-peer trust/rate limits.
- **Replay/dedup:** bundle ID is `BLAKE3(src_pubkey || nonce || payload_hash)`,
  globally unique. Nodes keep a dedup set of seen IDs (bloom + LRU) bounded by
  bundle lifetime.

**Egress addressing nuance (A):** an internet bundle is sealed to a *gateway
capability*, not a specific gateway. v1 approach: payload is sealed per-gateway at
fulfillment time using an ephemeral key carried in the bundle, OR (simpler v1) the
HTTP request is sealed to a rotating set of well-known gateway keys the app ships
with. The response is sealed back to the origin device key. This is the area most
likely to change; see §9.

### Identity ownership & portability

**The library never owns identity storage — the host app does.** `hop-core`/`hop-ffi`
is *given* a 32-byte secret at construction and uses it; it does not decide where the
secret lives. The seam:

- **Import** = the constructor (`HopNode.open(dbPath, secret)` / `with_secret`). The
  app hands in the seed on startup.
- **Export** = `node.secret()` → the 32-byte Ed25519 seed, to stash wherever the app
  chooses. The secret *is* the keypair *is* the address — re-importing it reproduces
  the same address (verified by `identity_secret_round_trips_address`).

Where those bytes come from is an **app concern**, not a protocol one:

- **Device-bound (example app default):** derive the seed deterministically from a
  device identifier (iOS `identifierForVendor`). Stable across launches/reinstall with
  zero storage to fail; the trade-off is non-portability. Used because dev-installed
  builds wipe app storage unpredictably.
- **Portable / multi-device:** store a random keypair the app can move. On iOS,
  **iCloud Keychain** (`kSecAttrSynchronizable`) shares one identity across all of a
  user's Apple devices automatically — the "single iCloud user, same key everywhere"
  model (à la iMessage). Other paths: QR handoff, encrypted backup, an account
  service. All are byte import/export at the app layer; the protocol is unchanged.

This keeps the plugin storage-agnostic and lets each host pick the right identity
lifecycle (ephemeral, device-bound, or account-synced).

---

## 5. Bundle format

Wire format is length-prefixed, versioned, `postcard`/CBOR-style canonical encoding.

```
Bundle {
  version:      u8
  id:           [u8; 32]      // BLAKE3(src || nonce || payload_hash)
  src:          PubKey        // Ed25519, 32 bytes
  dst:          Destination   // enum below
  created_at:   u64           // sender clock, ms — advisory only (see §8)
  lifetime_ms:  u32           // discard after created_at + lifetime
  hop_limit:    u8            // decrement per forward; 0 = drop
  flags:        BundleFlags   // request_ack, is_ack, custody_requested, ...
  custody:      Option<PubKey>// current custodian, if custody transfer in use
  payload:      SealedPayload // X25519 + ChaCha20-Poly1305
  sig:          Signature     // Ed25519 over all preceding fields
}

Destination =
  | Device(PubKey)            // Use Case B
  | InternetEgress            // Use Case A — "any gateway"
  | AckTo(PubKey, [u8;32])    // ACK routed back to origin for a given bundle id

SealedPayload depends on kind:
  HttpRequest  { method, url, headers, body, max_resp_bytes }
  HttpResponse { status, headers, body, for_bundle_id }
  PeerMessage  { content_type, body }
  Ack          { for_bundle_id, status }
```

Bundles are immutable once created and signed, except the mutable forwarding
envelope (`hop_limit`, `custody`) which is **not** covered by `sig` — relays may
decrement hop_limit and update custodian without invalidating the signature.
(Implementation: split into a signed inner header + an unsigned forwarding header.)

### Fragmentation
BLE ATT MTU is ~185–512 B and even L2CAP CoC has bounded SDU sizes. The Link layer
fragments a bundle into ordered frames and reassembles on the far side. Frames:
`{ bundle_id, frag_index, frag_count, bytes }`. Reassembly buffers are bounded and
time out. Large payloads (HTTP responses) ride L2CAP CoC, not GATT notifications.

---

## 6. Routing

Routing decides, for each stored bundle and each newly-discovered peer, **whether
to hand this bundle to that peer.** No global topology, no addresses-as-locations.

### Device-to-device (B): binary Spray-and-Wait

The problem: in an intermittently-connected mesh there is no path to query, so the
two naive options are bad. **Epidemic routing** — copy to *every* peer you meet —
delivers well but the copy count explodes, and so do storage and radio time.
**Direct delivery** — keep one copy, hand it only to the destination — has minimal
overhead but terrible latency (you must physically encounter the destination).
Spray-and-Wait is the tunable middle.

A bundle is born with a **copy budget L** (`BundleOpts.copies`, default 8). That
budget is the *total* number of copies allowed to exist in the network — it travels
with the bundle in the (unsigned) envelope, so it survives handoffs.

- **Spray phase** (`copies > 1`): on meeting a peer that doesn't already have the
  bundle, the custodian does a **binary split** — gives the peer `floor(n/2)` of its
  copies and keeps `ceil(n/2)` (`Bundle::split_copies`). Both can now spray further.
  Starting from 8: `8 → 4+4 → 2+2 → 1+1`, so after ~log₂(L) good encounters the
  copies are spread across up to L distinct carriers fanning out in parallel.
- **Wait phase** (`copies == 1`): a carrier down to its last copy stops spraying and
  holds it, delivering **only** when it directly meets the destination.
- **Direct delivery always wins:** at any time, if the peer *is* the destination, the
  bundle is handed over regardless of phase (and custody released).

Why binary specifically: among spray schemes under random mobility, the binary
split minimizes expected delivery delay — it spreads copies to independent carriers
fastest, maximizing the chance one of them encounters the destination soon. L is the
single knob trading overhead (≤ L copies, bounded) against delivery probability and
latency. The simulator (`hop-sim`) is where we'll tune L against contact traces;
see test `binary_spray_splits_copies_then_delivers`.

**Optional later — PRoPHET hint:** instead of spraying to *any* fresh peer, prefer
peers with higher historical delivery-predictability for the destination. The same
encounter statistics that power reliability-weighted relay (§18) feed this. Pure
spray-and-wait works without it; we add it only if the simulator shows it helps.

### Internet egress (A): gateway gradient
- Gateways periodically emit a signed, short-lived **gateway beacon** that floods
  a few hops. Nodes maintain a `hops_to_nearest_gateway` gradient and prefer
  forwarding `InternetEgress` bundles to peers with a lower gradient.
- Absent any gradient (no beacon seen), fall back to epidemic spread with a tight
  hop_limit so requests still diffuse toward connectivity.

### ACK / response return path
The return bundle is `Device(origin_pubkey)` (response) or `AckTo(...)`. It routes
back using the same device-to-device machinery. Because the origin may have moved,
returns use spray-and-wait too. The origin retransmits the request until the
response/ACK arrives or lifetime expires.

Routing is a trait so policies are swappable and testable in simulation:

```rust
trait Router {
    fn on_peer(&mut self, peer: &PeerId, their_have: &HaveSet) -> Vec<BundleId>;
    fn should_forward(&self, b: &BundleMeta, to: &PeerId) -> ForwardDecision;
    fn on_beacon(&mut self, beacon: &GatewayBeacon);
}
```

---

## 7. Two Generals — and why we're not actually facing it

The Two Generals Problem is unsolvable for one specific thing: **bilateral,
simultaneous agreement to act.** Both generals must attack *together*, so each needs
to know that the other knows that they know… — an infinite regress any finite
protocol breaks by losing its last message. That impossibility is real, but it is
**not the problem Hop has.**

Message delivery is **unilateral**. The destination doesn't need the sender's
permission to act: the instant it has the message, it delivers it to the user. It
acts alone. That asymmetry collapses the regress — only the *forward* path must
succeed; the ACK going back is bookkeeping. So the goal decomposes:

- **Exactly-once delivery on the wire** — impossible, and we don't need it. Copies
  can duplicate.
- **Exactly-once *processing/effect*** — **achieved.** At-least-once forward delivery
  + dedup by bundle id means duplicates are no-ops; the user sees the message once.
- **The sender's *certainty* of success** — arbitrarily high (retransmit until ACK),
  never absolute, **and it doesn't matter for correctness.**

**Why there's no infinite ACK-of-ACK regress:** the sender only uses an ACK to stop
retransmitting and flip a UI indicator. A lost ACK just means more (harmless,
deduped) retransmits. Nobody waits on confirmation *before acting*, so the regress
that dooms Two Generals never starts.

The mechanism:

1. **At-least-once + idempotency.** Every node dedupes on `id`; re-receiving a bundle
   is a no-op (`store` dedup set).
2. **End-to-end ACK bundles.** On `request_ack`, the destination emits a sealed `Ack`
   (`Destination::AckTo(origin, id)`, sealed to the origin's `src_x`) routed back by
   the normal machinery; the origin consumes it to stop tracking.
3. **Retransmission** at the source/custodian (`Node::tick`, refreshing the spray
   budget) until acked or past lifetime; lifetime is the give-up signal.
4. **Custody transfer (optional)** lets an intermediate accept retransmission duty,
   bounding per-node retention.

**The one real obligation — a bounded dedup window.** Exactly-once *processing* holds
only as long as a destination remembers a bundle's id for at least as long as a
duplicate of it can still arrive — its lifetime. So the `seen` set carries a
**receiver-anchored expiry** (`now + lifetime` at first sight, robust to sender clock
skew) and `Store::prune` drops entries past it. This bounds memory without weakening
the guarantee inside the window that matters. The SQLite backend persists `seen`, so
the guarantee survives restarts. (Tests: `dedup_window_closes_after_lifetime_then_reaccepts`,
`prune_closes_dedup_window`; ACK flow: `ack_returns_and_clears_sender_pending`.)

**The residual, quarantined to the UI.** What survives of Two Generals is only the
*sender's knowledge*. Worst case: a message was delivered but the ACK never returned,
so the sender shows "sent" (then "gave up") instead of "delivered ✓". That is a
**false negative on an indicator** — never a lost message, never a duplicated effect,
never a "delivered" shown for something that wasn't. Surface states as *queued /
in-flight / delivered (acked) / unconfirmed*; the unconfirmed case is the only thing
the impossibility can ever cause, and it is harmless.

> **HTTP idempotency caveat:** at-least-once means a gateway might execute the same
> HTTP request more than once (duplicate request bundles, or a lost response causing
> retransmit). v1 dedupes requests at the gateway by bundle ID within a window, and
> the product should prefer idempotent requests (GET, or POST with an
> idempotency key). Non-idempotent side effects executing twice is a real risk to
> document, not hide.

---

## 8. Time, clocks, and lifetime

Phones have unsynchronized, sometimes-wrong clocks and there is no NTP offline.
- `created_at` / `lifetime_ms` are **advisory** and interpreted against the
  *receiving* node's clock with generous skew tolerance.
- Each forward also enforces `hop_limit` (a clock-free bound) and a per-node
  **max-residence-time** so a bundle with a bogus future timestamp still gets
  garbage-collected.
- Gateways, which do have internet, can stamp a trusted time into return bundles to
  re-anchor a region's sense of time opportunistically (nice-to-have, not v1).

---

## 9. Gateways (Use Case A)

A gateway is a normal node plus:
- Internet access and the `egress` capability bit in its beacons.
- An HTTP fulfillment worker (`hop-gateway`, tokio): unseal request → perform HTTP
  (with an allowlist/policy + size cap `max_resp_bytes`) → seal `HttpResponse` back
  to the origin device key → inject as a `Device(origin)` bundle.
- Request dedup by bundle ID within a TTL window (§7 caveat).
- Abuse controls: per-source rate limiting, payload/response size caps, URL policy.

> **Implemented (`hop-gateway`).** `Gateway::fulfill` returns a structured
> `FulfillOutcome` (Response / Duplicate / RateLimited / PolicyDenied /
> RequestTooLarge / NotForUs). TTL-bounded dedup map (pruned to bound memory),
> per-source sliding-window rate limiting, request-body size cap, and an `Allowlist`
> `EgressPolicy` (methods + host suffixes + https-only). The HTTP client is injected
> (`HttpClient`) so a `reqwest` backend drops in without touching this logic.

**Open design question (flagged):** how a request is sealed to "any gateway"
without a prior shared secret. Candidate approaches, to decide before coding §4/§9:
- (a) Ship a rotating set of well-known gateway public keys in the app; seal to one.
- (b) Carry an ephemeral X25519 pubkey in the bundle; gateway does ECDH at
  fulfillment and seals the response back with it. Request body still needs to be
  readable by the gateway, so the request is sealed to the gateway key (needs a).
- (c) Hybrid: request sealed to well-known gateway key set (a); response sealed to
  the origin device key (always known). **DECIDED: (c) for v1.** The app ships a
  rotating set of well-known gateway public keys; a request is sealed to one of
  them, and the response is always sealed back to the origin device key.

---

## 10. Threat model (v1 scope)

| Property | v1 | Notes |
|---|---|---|
| Payload confidentiality from relays | ✅ | X25519 + ChaCha20-Poly1305 seal |
| Payload integrity / origin auth | ✅ | Ed25519 bundle signature |
| Link confidentiality from BLE sniffers | ✅ | Noise XX per link |
| Replay safety | ✅ | dedup by bundle ID + lifetime |
| Traffic-analysis / metadata privacy | ❌ | relays see src/dst headers; future work |
| Sybil / flooding resistance | ⚠️ | hop_limit, spray cap, per-peer rate limit; not robust against a determined adversary |
| Gateway request abuse | ⚠️ | rate limit + URL policy + size caps |

Hop is **not** an anonymity network in v1. If that becomes a requirement, the model
moves toward Briar (onion-style layered sealing, no cleartext dst in headers), which
is a significant redesign of §4–§5.

---

## 11. BLE bearer — the constraint that shapes everything

> **iOS background BLE is the hardest constraint in this project.** A backgrounded
> iOS app advertises into an "overflow" area that omits the service UUID and is only
> reliably readable by *foregrounded* iOS devices. This is what defeated
> FireChat-style apps. We design around it rather than wishing it away.

Implications baked into the design:
- **Foregrounded devices are the relay backbone; backgrounded iOS are leaf nodes**
  that sync opportunistically when the app is open. Routing must not assume a
  backgrounded iOS node will relay.
- **Dual role:** every node acts as both BLE central and peripheral. GATT carries
  **discovery + control + small frames**; **L2CAP CoC** carries **bulk** (HTTP
  responses). CoC gives a stream and far better throughput than GATT notifications.
- **Android:** foreground service for sustained operation; account for Doze and
  background-scan throttling (8.0+). Android can hold the backbone role better.
- Bearer is a trait (`Bearer: send_frame / recv_frame / peer_events`). BLE is the
  only impl in v1; Wi-Fi Aware / MultipeerConnectivity / LoRa can be added without
  touching core.

---

## 12. Cross-platform architecture

```
hop/
├─ crates/
│  ├─ hop-core/         # pure Rust core
│  │   ├─ bundle        # addressed store-and-forward messages (§5)
│  │   ├─ crypto        # identity, sealing, signatures (§4)
│  │   ├─ discover      # gossiped service/peer directory + pub-sub (§15–§16)
│  │   ├─ node          # the event loop tying every layer together
│  │   ├─ relay         # reliability-weighted relay scoring (§18)
│  │   ├─ routing       # spray-and-wait + gateway gradient (§6)
│  │   ├─ link          # Noise XX sessions + fragmentation (§4)
│  │   ├─ stream        # ordered SSE/WS reassembly + resend buffer (§20)
│  │   ├─ store/util
│  │   └─ (AppId)       # shared-fabric app namespace (§17)
│  ├─ hop-ffi/          # UniFFI → Swift + Kotlin bindings; embeddable in host apps
│  ├─ hop-gateway/      # internet-egress node (tokio, real HTTP)
│  ├─ hop-store-sqlite/ # persistent Store backend (rusqlite) — §13.2
│  ├─ hop-relay/        # online super-node: TCP/QUIC bearer + mailbox store — §19
│  └─ hop-sim/          # discrete-event mesh simulator for routing tests
├─ apple/               # Swift: CoreBluetooth central+peripheral, L2CAP CoC
└─ android/             # Kotlin: BLE GATT + L2CAP, foreground service
```

- **`hop-core`** owns everything deterministic: bundle codec, routing policy, store,
  crypto, link framing/reassembly. No async radio assumptions — it's driven by
  events (`on_peer`, `on_frame`, `tick`) so it runs identically in tests, the
  simulator, and on-device.
- **`hop-ffi`** exposes a small, stable surface (create identity, submit bundle,
  poll outbox/inbox, feed peer/frame events) via **UniFFI**, generating idiomatic
  Swift and Kotlin.
- **Native shims** implement only the `Bearer` trait against CoreBluetooth /
  Android BLE and pump events into core. They contain *no protocol logic*.
- **`hop-sim`** lets us validate routing (delivery ratio, overhead, latency under
  churn/partition) without phones — essential, because field-testing a mesh by hand
  is brutal.

---

## 13. Open questions to resolve next

1. ~~**Gateway sealing** (§9)~~ — **DECIDED: approach (c).**
2. ~~**Store backend**~~ — **DECIDED & IMPLEMENTED: SQLite** (`rusqlite`, bundled).
   Most mature and battle-tested on both iOS and Android, survives crashes, and is
   ready for indexed queries over the forward queue + directory. Lives in
   `hop-store-sqlite` behind the (now backend-agnostic) `Store` trait, so `hop-core`
   stays pure-Rust/no-C and the FFI/sim builds aren't burdened. `Node` is generic over
   `Store` (`Node::with_store`), so it runs on either memory or SQLite. Encryption at
   rest via SQLCipher or app-supplied page encryption; `MemoryStore` remains for
   tests and the simulator. Tests cover dedup-across-reopen and copy-budget persistence.
3. **Routing v1** — start with pure binary spray-and-wait (simplest correct thing)
   and add PRoPHET/gateway-gradient once the simulator shows the need?
4. ~~**Bundle codec**~~ — **DECIDED: `postcard`** (compact, Rust-native; native
   apps consume via `hop-ffi`, so CBOR interop isn't needed).
5. **Identity backup / recovery** — losing the keypair = losing your address. Out
   of scope for protocol v1 but a product question that affects key storage.

---

## 14. Build order (dependency sequence, no dates)

- **Phase 0 — Spec.** This document. Resolve §13 (1) and (4) before coding format.
- **Phase 1 — Core data plane.** `hop-core`: bundle codec + crypto (identity, seal,
  sign, dedup) + store. Property tests for round-trip and dedup.
- **Phase 2 — Routing + simulator.** `hop-sim` + binary spray-and-wait + gateway
  gradient. Measure delivery ratio/overhead under churn and partition.
- **Phase 3 — Link layer.** ✅ Noise XX sessions (`link::LinkHandshake` /
  `LinkSession`, via `snow`) + fragmentation/reassembly (`link::fragment` /
  `Reassembler`). Remaining: drive sessions from the node loop over a real bearer.
- **Phase 4 — Gateway.** `hop-gateway`: HTTP fulfillment, request dedup, abuse
  controls. End-to-end A in simulation.
- **Phase 5 — FFI + native BLE.** ✅ `hop-ffi`: UniFFI-exported `HopNode` wrapping the
  real node loop (`cdylib`/`staticlib` build for Android/iOS; end-to-end tested from
  Rust). Remaining: run `uniffi-bindgen` to emit Swift/Kotlin, and the native BLE
  shim implementing `Bearer`. First real two-phone hop.
- **Phase 6 — Internet-assisted relay.** `hop-relay`: TCP/QUIC bearer + federated
  mailbox store (§19). Long-distance hops once any carrier touches the internet.
- **Phase 7 — Streaming sessions.** Gateway-held SSE/WebSocket (§20): async upstream
  IO, session persistence, and reconnect-on-deploy. Ordering core (`stream`) done.

---

## 15. Relayed discovery (gossiped directory)

Bundles (§5) are *addressed* — you must already know the destination key.
Discovery answers the prior question: **how do you learn a peer or service exists,
and get its keys?** Nodes publish signed **adverts** that flood the mesh
epidemically and land in every node's local **directory**. You see an advert the
moment you meet *any* node carrying it — that is the product's transitivity rule:
*"discoverable as soon as I've seen another device that has also seen it."*

- **Advert** = `{ id, body, sig }`, `id = BLAKE3(body)`, signed by the publisher so
  it can't be forged. Body carries the publisher's address **and** sealing key, so
  a discoverer can immediately send a sealed device-to-device bundle back.
- **Kinds:** `Peer{display_name}` (add-me-by-key), `Service{service,title,summary,
  tags}` (a job-board post, a marketplace listing), `Tombstone{revokes}` (sold /
  closed — removes a prior advert before its TTL).
- **Gossip the index, fetch the object.** Adverts stay tiny (summary + keys). Heavy
  content (listing photos) is *not* flooded — it's fetched on demand via an
  addressed bundle to the publisher. Keeps the mesh cheap.

**Marketplace flow (User A sells a bike → User B finds it):** A publishes a
`Service{service:"market", title:"Bike for sale", …}` advert → it gossips A→R→…→B
hop by hop → B, having met any node that saw it, finds it in B's directory →
B reads A's keys from the advert → B sends a sealed `PeerMessage` bundle to A to
inquire. B and A never had to meet directly. (`discover::Directory`,
test `relayed_discovery_then_contact`.)

Adverts are **public** to the mesh — correct for a public board/marketplace.
Private peer discovery (rendezvous via a shared secret, no cleartext metadata) is
future work (§10).

## 16. Services as pub/sub topics, and keeping relays light

A **service is a topic**. Offering a service = broadcasting adverts on it;
consuming it = **subscribing**; and *every* device relays best-effort regardless of
whether it subscribes. This makes the directory a topic pub/sub bus.

The cost problem: if everyone relays everything, relay storage is unbounded. So:

- **Subscription-aware retention.** Subscribed topics (plus the reserved
  `_control` topic) get **full retention**. Everything else lands in a **bounded,
  compressed, LRU relay cache** (`DEFAULT_RELAY_CACHE_CAP`) — best-effort carry for
  strangers that can never blow up local storage. Subscribing later *promotes*
  already-cached adverts to full retention.
- **Compression is first-class.** Relay-cache entries are stored DEFLATE-compressed
  (`util::compress`, pure-Rust `miniz_oxide`); adverts are kept small by design.
  (Future: link-layer frame compression for bulk transfers too.)
- **Supersession & expiry.** `seq` lets a publisher supersede an edited listing;
  TTL + tombstones bound lifetime; `Directory::expire` GCs both stores.

(`discover::Directory`, tests `relay_cache_is_bounded_and_evicts_oldest`,
`subscribed_topics_get_full_retention`, `subscribing_promotes_already_cached_adverts`.)

## 17. The shared fabric — Hop as an embeddable library

Hop is meant to be embedded as a **plugin/library inside other apps**, not shipped
as one monolithic app. The failure mode to avoid: each app forms its own private
mesh and a lone app has no one to relay through. So the fabric is **shared**:

- **One BLE service UUID for all Hop apps.** Any Hop-enabled app recognizes any
  other as a relay peer and forwards its traffic. Relaying is not limited to
  instances of a single app — that's what makes a sparse deployment viable.
- **`AppId` namespacing.** Every bundle and advert carries a 16-byte `AppId`
  (`app_id("com.example.jobs")`; `FABRIC_APP` is the shared/default namespace for
  cross-app concerns like peer discovery). An app demultiplexes its own traffic by
  `AppId`; relays carry **all** apps' traffic indiscriminately.
- **Isolation by construction.** Relays forward ciphertext they can't read (§4), so
  carrying another app's bundles leaks nothing. Headers do expose `AppId` + topic to
  on-path relays (needed for routing/prioritization) — a metadata trade-off noted in
  §10.
- **Embedding surface.** The host app links `hop-ffi` (UniFFI → Swift/Kotlin),
  provides identity persistence + storage, and either uses Hop's default BLE bearer
  or supplies its own `Bearer` impl. All protocol logic stays in `hop-core`.

### Deduplicating the same device running Hop in multiple apps

Hop is embedded per-app, and mobile OSes sandbox each app into its own process,
BLE stack, and storage. So if a user has two Hop-enabled apps installed, by default
the **one physical device runs two Hop nodes with two identities** — it shows up as
two peers/relays. Dedup is possible at some layers, impossible at others:

- **Message delivery — already deduped, no work needed.** Dedup is by `BundleId`
  plus the receiver-anchored dedup window (§7). If a device relays the same bundle
  through several of its app-instances, the destination still **processes it exactly
  once**. Redundant relay nodes waste radio, never cause duplicate delivery.
- **Identity / presence — dedup only *within one publisher*.** Apps from the **same
  developer** can share a single Hop identity by storing the identity secret in a
  shared **Keychain access group** (iOS) / shared keystore or signature-permission
  `ContentProvider` (Android). All of that vendor's apps then use the **same address**
  and present as **one node**. Apps from **different developers** can't — the sandbox
  blocks shared identity and shared BLE — so they stay distinct nodes. Merging them
  would require a device fingerprint, which breaks the address-is-the-public-key
  privacy model (§4); we deliberately don't.
- **Radio / bearer — partial.** Same-developer apps can additionally share an **App
  Group** (iOS) / bound service (Android) to elect a single active bearer (heartbeat
  lock) so they don't all scan/advertise at once. iOS background scheduling makes
  "exactly one" best-effort, not guaranteed. Cross-developer radio redundancy is
  unavoidable — but each extra node *adds coverage* to the shared fabric rather than
  conflicting.

**Net:** duplicate *delivery* never happens (BundleId dedup). Duplicate *presence/
relay identity* for one device is removable across a single vendor's apps (shared
keychain identity + bearer election) and inherent across vendors — where the design
turns it into cooperation (mutual relaying) rather than a conflict.

## 18. Reliability-weighted relay

A node learns *which topics it is a good relay for* from whom it repeatedly meets,
and prioritizes those paths. Motivating case: **"I regularly meet 4 people who want
job-board updates from company X, and I regularly pass company X — so I'm a reliable
bridge for that topic; I should pin it and offer it first."**

This is PRoPHET-style delivery predictability (recency/frequency-weighted encounter
history) specialized to pub/sub topics. Per topic, two recency-decayed signals:

- **demand** — distinct peers we meet who *want* the topic;
- **supply** — peers we meet who *carry/originate* the topic.

`score(topic) = demand · (0.25 + supply)` — bridging strong demand and live supply
scores highest; demand alone still has some value. Encounters decay on a half-life
so the score tracks *current* reliability, not ancient history. Used to:

- **Pin** high-scoring topics to full retention even under relay-cache pressure
  (`Directory::pin_hot_topics`).
- **Order** gossip offers so the most valuable adverts go first during short BLE
  contacts (`Directory::gossip_offer_ranked`).

## 19. Internet-assisted relay (the online store)

BLE-only mesh is bounded by physical proximity chains. But the moment *any* carrier
along the path has internet — even briefly — Hop can leap continents. An online
device parks its bundles in a shared **Hop online store**, and a different online
device near the destination picks them up. The internet becomes one very long,
very fast hop in the same store-and-forward model.

**It's the same protocol, a different bearer.** Online nodes speak the existing
bundle protocol over TCP/QUIC/WebSocket instead of BLE — the `Bearer` trait already
abstracts this (§11), so the core is unchanged. What's new is a rendezvous store so
two online nodes that are *not simultaneously connected* can still relay.

**The online store is an untrusted, best-effort mailbox keyed by destination.**
- Bundles are already sealed end-to-end (§4), so the store holds **ciphertext it
  cannot read**. It indexes by `(AppId, Destination)` and topic, with TTL.
- An online node **pushes** bundles it's carrying whose destination it can't reach
  locally; an online node near a destination (or subscribed to a topic) **pulls**
  matching bundles and re-injects them into its local BLE mesh.
- Adverts (§15–§16) ride the same path: the online store doubles as a wide-area
  pub/sub broker, so a marketplace listing in one town becomes discoverable in
  another the instant both touch the internet.

**Topology options (decide before building):**
- (a) **Federated mailbox servers** — a set of well-known endpoints (operated like
  the gateways of §9, possibly the *same* nodes). Simplest; needs operators.
- (b) **DHT** — a Kademlia-style overlay of online nodes storing bundles keyed by
  destination, no central operator. More robust, much harder (NAT traversal,
  churn, eclipse/Sybil resistance).
- v1 leans (a) — federated mailboxes co-located with gateways — and treats (b) as
  the decentralization endgame.

**Why it's harder (called out honestly):**
- **NAT traversal / reachability** between online peers (hole-punching, relays).
- **Who runs it & discovery** of online endpoints (ship a seed list; let gateway
  beacons (§6) also advertise mailbox endpoints).
- **Metadata exposure:** the store sees `(AppId, dst)` and access patterns even
  though payloads are sealed — worse than a transient BLE relay. Mitigations
  (destination blinding, mailbox sharding) are future work tied to §10.
- **Abuse at internet scale:** rate limits, proof-of-work or auth, per-dst quotas,
  size/TTL caps — the store is a spam magnet otherwise.
- **It doesn't change Two Generals (§7).** The online store raises delivery
  *probability* dramatically; it does not provide certainty. Same at-least-once +
  idempotency + ACK machinery applies end-to-end.

**Build placement:** a new `hop-relay` crate (online super-node: TCP/QUIC bearer +
mailbox store), reusing `hop-core` bundles and likely sharing a process/host with
`hop-gateway`. Sequenced after the BLE path proves out (a new Phase 6).

(`relay::RelayScorer`, tests `bridging_demand_and_supply_outranks_demand_alone`,
`repeated_encounters_beat_one_offs_and_decay_over_time`.)

## 20. Streaming sessions — gateway-held SSE / WebSocket

A long-lived HTTP stream (Server-Sent Events, WebSocket) **cannot live on an
intermittently-connected device** — the socket would drop every time BLE flaps or
the app backgrounds. So the device never holds the upstream socket. Instead:

**The gateway holds the connection on the device's behalf** and relays it as an
ordered sequence of bundles. The device opens a logical stream; the gateway opens
the real upstream connection, pumps each event/frame back as numbered `StreamData`
bundles, and writes device→server frames (WebSocket) from the bundles it receives.

**Always via the gateway — even when the device is online.** The device connects
*logically to the gateway*, never directly to the origin server, regardless of its
own connectivity. This decouples device liveness from upstream liveness: the upstream
connection stays up at the gateway while the device comes and goes, so intermittent
connectivity **never causes a stream failure** — the device just catches up from where
it left off. One uniform, resilient path instead of two code paths (online vs offline).

**Wire protocol** (`Payload::Stream*`, sealed end-to-end device↔gateway like any
bundle):
- `StreamOpen { stream_id, kind: Sse|WebSocket, method, url, headers }` — establish.
- `StreamData { stream_id, seq, bytes, fin }` — one ordered chunk, either direction.
- `StreamAck { stream_id, ack }` — "I have everything contiguously through `ack`."
- `StreamClose { stream_id, reason }` — tear down (or signal *reopen*; see below).

**Ordering over unordered delivery.** Bundles can arrive out of order, duplicated, or
after a gap. The bundle layer gives at-least-once + dedup; the **stream layer adds
sequencing** (`hop-core::stream`, implemented & tested):
- [`StreamReassembler`] delivers chunks strictly in order, dedups, buffers
  out-of-order arrivals, drains on gap-fill, and reports the contiguous high-water
  mark for `StreamAck`.
- [`StreamBuffer`] holds unacked chunks so they can be **resent after the device
  reconnects** (`resend_from`), releasing them on ACK, with a bounded window that
  applies backpressure when the peer falls too far behind.

This is what makes "partial messages get relayed properly": a device that drops at
seq 40 and returns later sends `StreamAck{40}`, and the gateway resends 41+ from its
buffer. No loss, no reordering, no duplication.

**Gateway resilience across deploys / restarts / new versions.** Because the gateway
owns the connections, it must survive its own lifecycle:
- **Persist session state** — the stream registry (per `stream_id`: kind, upstream
  request, last-delivered and last-acked seq, buffered unacked chunks). On restart
  the gateway reloads this and **reconnects upstream**, resuming from the device's
  last ACK.
- **Resumable vs not** — if the upstream supports resumption (SSE `Last-Event-ID`,
  app-level cursors) the gateway resumes transparently. If it can't, the gateway
  sends `StreamClose{reason: reopen}` and the device transparently re-opens — the
  user-visible stream survives even when the underlying socket couldn't.
- **Versioning** — the stream protocol is versioned (bundle `version` + a stream
  envelope version) so a newer gateway can read sessions written by an older one;
  unmigratable sessions degrade to a clean reopen rather than a hang.

**Status.** The ordering/resend core (`stream::StreamReassembler`, `StreamBuffer`)
and the `Payload::Stream*` wire types are implemented and tested. The gateway-side
async upstream IO (real SSE via `reqwest`, WebSocket via `tokio-tungstenite`),
session persistence, and reconnect-on-deploy are the next implementation phase
(Phase 7), building on `hop-gateway` + the SQLite store.

## 21. The cloud backbone — zero-distance peers and region-aware routing

Cloud hop nodes are ordinary nodes that happen to have abundant connectivity,
storage, and CPU. Model them as **zero-distance, high-capacity virtual peers**:
- A cloud node is a gateway whose hop-gradient (§6) is ~0, so the routing layer
  already prefers moving bundles *toward* it.
- Cloud nodes peer with each other over the internet (§19 transport) at effectively
  zero cost, so the backbone is one big low-latency fabric: **any two devices
  attached to it are ~1 hop apart**, anywhere on Earth.
- High message capacity means the backbone can hold and relay far more than a phone
  (big mailbox, no BLE MTU), so it absorbs the bulk of carry-and-forward.

**But egress is not free.** Pushing a bundle *into* the cloud is cheap; fanning it
back *out* to every region costs backbone bandwidth and wakes downstream devices. So
the backbone must route **intelligently**, and the rule you called out is the core of
it: *don't ship a topic to a region that has no subscribers.*

The backbone tracks two recency-decayed signals (`hop-relay::region::RegionRouter`,
implemented & tested) — the §18 demand idea lifted from peers to **regions**:
- **presence** — which region a device address was last reachable through, so an
  *addressed* bundle goes to **one** region (the destination's) instead of flooding
  all of them. Unknown/stale ⇒ fall back to a broadcast.
- **demand** — per `(app, topic)`, how much live subscriber interest each region has.
  `should_route_topic_to` is false once a region's demand decays below threshold, and
  `target_regions` returns only regions worth fanning to, ranked by demand. A region
  whose subscribers all went away simply drops off the fan-out — no wasted egress.

So the path for, say, a marketplace broadcast: device → (1 hop) cloud → backbone
(0 cost) → only the regions with live `market` subscribers → their edge nodes →
devices. A region with nobody listening never receives it. An addressed message goes
straight to the destination's current region. This is what makes a global backbone
affordable rather than a flood amplifier.

**Status.** `RegionRouter` (presence + per-region decayed demand, with
`region_of` / `should_route_topic_to` / `target_regions`) is implemented and tested
in `hop-relay`. The relay daemon (`hop-relayd`) runs a node + TCP bearer so devices
and relays link over the internet; wiring `RegionRouter` into the live forwarding
path is the next step.

### One DNS, many nodes — closest entrance, closest exit, lowest latency

The backbone is **one hostname resolving to many relay nodes**, and traffic should
always use the lowest-latency entrance and exit.

- **Entrance (device → backbone): lowest-RTT relay.** A single name (e.g.
  `relay.hop.net`) fronts the whole fleet via **GeoDNS and/or BGP anycast** (anycast
  routes a device to the topologically-nearest PoP automatically). The device then
  **races** the resolved endpoints and keeps the fastest — today `NWConnection` with a
  hostname already does happy-eyeballs (it connects to the quickest-responding resolved
  IP), giving a first cut for free; an explicit RTT race over the top-N records is the
  refinement.
- **Exit (backbone → device): the destination's current relay.** A bundle for B must
  leave the backbone at the relay **B is currently attached to** — which is the
  closest exit by definition. `RegionRouter` tracks each address's current region from
  presence, so the backbone files the bundle and points the fetch at B's region instead
  of flooding every region. Delay-tolerant: if B is offline, the mailbox holds it
  until B's region reappears.
- **Relay ↔ relay discovery across regions.** Relays form a backbone mesh via a
  **membership layer** — a seed list / registry plus gossip (SWIM-style) so the set
  self-heals as nodes come and go. Each relay measures **RTT to its backbone peers**
  and routes inter-region traffic over the lowest-latency path (link-state or
  distance-vector over the backbone graph), so "lowest latency wins" end to end:
  nearest entrance → shortest backbone path → nearest exit.
- **No central chokepoint.** DNS is the only shared name; everything behind it is many
  interchangeable nodes. Any relay can be an entrance or an exit; the mailbox is an
  untrusted store of sealed ciphertext (§19), so adding capacity is just adding nodes.

**Status.** Implemented: `hop-relayd` (node + TCP bearer), the iOS relay bearer,
`RegionRouter` (presence/demand). To build: GeoDNS/anycast fronting, client-side RTT
race over resolved endpoints, relay membership/gossip + inter-relay RTT-aware routing,
and wiring `RegionRouter` presence to pick the exit relay.

## 22. Background operation & beaconing

Hop only matters if messages arrive while the app is closed. But background BLE is
restricted on both platforms — differently — so we lean on **periodic beaconing to
stay discoverable, OS wake mechanisms to come back to life on BLE events, and local
notifications to surface a delivered message** (no server, no APNs/FCM — the "push"
is local, triggered by a bundle that arrived over BLE).

### iOS — the constraints, and the wakes that beat them

- **Background advertising loses the service UUID.** A backgrounded iOS app still
  advertises, but the service UUID moves to an "overflow" area only *foregrounded*
  iOS devices can read (DESIGN.md §11). So two **backgrounded** iPhones generally do
  not discover each other cold. We design around it, not against it:
  - **State preservation & restoration.** Create the managers with
    `CBCentralManagerOptionRestoreIdentifierKey` / `CBPeripheralManagerOptionRestoreIdentifierKey`.
    iOS then **relaunches the app into the background** on relevant BLE events
    (a restored peripheral connects, a CoC opens, a matching advert is seen) and
    calls `willRestoreState`. An established relationship survives backgrounding and
    termination.
  - **Background scanning with explicit service UUIDs.** `scanForPeripherals(withServices:)`
    works backgrounded (it's coalesced/slow, and `nil` services is disallowed) — we
    always pass the Hop UUID, so it's compatible.
  - **iBeacon region wake (optional, strong).** Advertise an iBeacon and have peers
    `CLLocationManager` **monitor that region**; region *enter* relaunches a suspended
    or killed app in the background — a reliable proximity wake that doesn't depend on
    the GATT service UUID. A good complement for cold discovery.
  - **Foreground/always-on nodes are the backbone (§11, §21).** A plugged-in device,
    a Mac, or a cloud node stays a reliable rendezvous that backgrounded leaves sync
    against when woken.
- **Background App Refresh.** Register a `BGAppRefreshTask` (BackgroundTasks /
  SwiftUI `.backgroundTask(.appRefresh:)`) to periodically `tick` the node —
  retransmit unacked bundles, prune the dedup window, re-advertise, drain — then
  reschedule. Best-effort cadence, set by the OS from usage.
- **Local push.** On delivery while not foreground, fire a `UNUserNotificationCenter`
  local notification. Authorization is requested once at startup.

### Android — foreground service + offloaded scan

- **Foreground service** (`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_CONNECTED_DEVICE`,
  a persistent notification) owns the bearer so BLE keeps running and isn't subject to
  background-scan throttling. This is the primary keep-alive.
- **Offloaded scanning** via `BluetoothLeScanner.startScan(filters, settings, PendingIntent)`
  lets the system wake the app on a Hop-service match **even when not running** — the
  Android analogue of iOS state restoration.
- **Periodic ticks** via `WorkManager` (or the service's own timer) for retransmit /
  prune / re-advertise.
- **Local push** via `NotificationCompat` (with `POST_NOTIFICATIONS` on Android 13+)
  when a message is delivered in the background.

### What this realistically buys us (honest)

- **Foreground ↔ anything**: solid — discovery, link, relay all work.
- **Backgrounded ↔ foregrounded/always-on**: works via restoration / offloaded scan;
  the message wakes the app and a local notification fires.
- **Two cold-backgrounded iPhones with no backbone nearby**: weakest case — likely no
  fresh discovery until one foregrounds or an iBeacon region wake fires. This is an OS
  limit, not a protocol one; the mitigation is backbone nodes (§21) and iBeacon wake,
  and the bundle simply waits in the store (it's delay-tolerant by design).

### Status

Design + app capabilities (background modes, restore identifiers, local
notifications, app-refresh task on iOS; foreground service + notifications on
Android) are wired in the demo apps. Tuning the wake cadence and adding iBeacon
region monitoring are follow-ups to validate on-device.

## 23. Addressing: the address *is* the public key

**The address is the public key.** A hop address is a device's Ed25519 verifying
key (32 bytes), rendered for humans as **base58** (`address_base58` /
`address_from_base58` in `hop-ffi`). There is no separate identifier, no UUID, no
name registry in the protocol. A public key is already globally unique — more so
than a random UUID — and it's the one identifier you *must* have anyway, because:

**You cannot message a peer without its public key, and all non-broadcast traffic
is encrypted (§4).** The sealing key is **derived from the address**: the Ed25519
verifying key converts to its Curve25519 (Montgomery) form, which is the X25519
public used to seal. So *seeing an address is sufficient to seal to it* — no key
exchange, no lookup. `crypto::address_to_x` does the conversion;
`crypto::seal(to_address, …)` takes an address directly. (Test:
`montgomery_correspondence`.)

This collapses identity, signing, and sealing into one key (§4) and removes the
entire address/name service the protocol previously carried.

### Names & contacts are an app concern, not the protocol

The protocol deliberately knows **nothing** about common names. Human-friendly
naming is a *local* problem — only the people who know you care what you're called,
and they're free to disagree. Pushing it into the wire format would force global
name resolution, collision rules, and a distributed registry into every relay for
something that's ultimately a per-user address-book label.

**Broadcasts are reserved for services (§15–§16).** Public, unencrypted gossip is
only for service adverts; user peer-to-peer traffic is always sealed. An app that
wants presence/discovery publishes a **service** and builds its contact book on top:

- **Presence.** A chat app publishes a `presence` service advert whose `title` is
  the user's chosen display name (`node.publish_service("presence", name, …)`). It
  floods the mesh like any service, so you discover a user the moment you meet any
  node that has seen them — including multiple hops away (`hops` on the hit). The
  advert's `publisher` field is the address you message. (Test:
  `discover_presence_two_hops_away_and_message_it`.)
- **Contacts (app-side).** The app browses `presence` (`node.browse("presence",
  None)`), and keeps a **local** contact book: address → chosen name. Conflicts are
  allowed — only the local user cares about real names. If two peers advertise the
  same display name, the app disambiguates however it likes (e.g. base58 suffix);
  it can resolve by claim timestamp carried in the advert if it wants determinism.
- **Private contact exchange.** Because seeing an address is enough to seal to it, a
  chat app can let a user request another's contact details with a **sealed**
  message ("who are you?") and reply with metadata, tying name↔address privately
  without any public name broadcast.

None of this is in `hop-core`; the demo app (`apple/HopDemo`, `android/HopDemo`)
implements presence + a contact book on top of the generic service API as the
reference example.

### Online resolution (gateways)

Gateways still offer value as a **directory of services** — an internet-connected
device can query a gateway to browse services (including presence) it hasn't met
transitively yet. The gateway query/response over the bundle protocol
(`Payload::Resolve{Request,Response}`) is the next piece; the local service
directory + browse logic are implemented.

## 24. Service confidentiality — public & private broadcasts

> **Status: design only.** Captured for later; build after the p2p layer is locked
> down. §16 covers the *relay/retention* mechanics of services; this section covers
> their *confidentiality* model.

A service is the **one-to-many** dual of a p2p message (which is one-to-one). The
crypto for "broadcast readable by a group but no one else" is not just "publish a
public key", and reasoning it through gives a clean, uniform model.

### Why a public key alone can't make a confidential broadcast

- Signing with the service key gives **authenticity, not confidentiality**. "Anyone
  with the pubkey can read it" means the content is *signed plaintext* — the pubkey
  *verifies*, it does not decrypt. (With Ed25519 you can't "encrypt with the private
  key" at all; the operation is sign/verify.)
- Sealing (§4) is **per-recipient** — you can't seal "to everyone".
- Therefore a confidential broadcast **requires a shared content key** held by the
  audience. Public-key crypto alone cannot do it.

### Two encryption layers (don't conflate them)

- **Link layer (Noise XX):** every byte on the radio is already encrypted hop-by-hop.
  But each relay decrypts to route, so relays can read *unsealed* content.
- **End-to-end (sealing / content key):** only the intended audience reads; relays
  carry opaque ciphertext.

Design decision: **every service broadcast is encrypted end-to-end under a content
key — there are no plaintext broadcasts.** Relays always carry ciphertext.

### Separate identity from the read capability

Two distinct keys, always:

- **Signing / identity key `S`** — the service keeps `S_priv` secret *forever*; never
  distributed. `S_pub` (or its hash) is the **service ID**: used for discovery,
  subscription, addressing, and verifying authenticity. It never decrypts anything.
- **Content key** — the thing that gates reading, distributed to the audience.

This is the ID-≠-read-key separation: holding the service ID lets you *find and
verify*; only the content key lets you *read*.

> **Hard rule: never distribute `S`.** If subscribers hold the key that signs
> broadcasts, any subscriber can forge broadcasts as the service. The distributed
> key must always be a *separate* encryption key, never the identity key.

### Public vs. private is one mechanism

> **public vs. private = whether the content key is freely distributed or gated.**

- **Public service:** content key handed to anyone who asks (or embedded where any
  subscriber can fetch it). Still ciphertext on every relay.
- **Private service:** content key sealed only to admitted members.

One code path, uniform "everything encrypted end-to-end", relays never read.

### Content key: symmetric vs. asymmetric

- **Symmetric `K` (default):** a shared secret handed to members. Simplest. Any
  holder can also encrypt, but that's fine — authenticity comes from `S`, not `K`.
- **Asymmetric `(E_pub, E_priv)` (optional):** distribute `E_priv` to members; the
  service encrypts with `E_pub`. Its one real benefit is **decoupling send-rights
  from read-rights** — anyone with `E_pub` can encrypt *to* the group without being
  able to read it (only `E_priv` holders read), while `S` still gates what's
  "official". Use only if you want open-submission groups; otherwise prefer `K`. `E`
  must never be `S`.

### Membership / key distribution

- **Admit:** seal the current content key to the member's address (p2p sealing, §4).
- **Revoke:** rotate the content key and re-seal to the *remaining* members — O(members)
  per rotation. Large-scale forward-secret revocation is the group-key problem; an
  MLS-style key tree is the scaling path, not needed for v1.

### One wrap + one signature per message (no double-wrap)

- **Broadcast to all** → encrypt under the content key.
- **Targeted to one subscriber** → seal to that address (normal p2p).
- Never nest the two (don't broadcast-then-seal). And no extra service signature: the
  bundle/advert is **already signed by its source**, which *is* the service identity —
  that existing signature authenticates the broadcast. Link-layer Noise underneath is
  a separate layer, not double-wrapping.

### Two axes of "private" (be explicit)

- **Content-private** (this section): service is *discoverable* (ID/advert visible),
  messages gated by the content key. The 90% case; build this.
- **Existence-private / unlisted:** even *knowing the service exists* is restricted.
  Can't be solved with a content key (the advert is public) — needs the service ID to
  be a secret capability or a rendezvous value derived from a shared secret. Harder;
  ties to private discovery (§10, §15), future work.

## 25. Gateway transport — HTTPS without being a man-in-the-middle

> **Status: design only.** Captured for later; build after the p2p layer is locked
> down *and* after a non-BLE bearer (TCP/WebSocket) exists for the phone↔gateway hop
> (a phone can't BLE-reach a cloud box). Refines §9/§19/§20.

The v1 `Payload::HttpRequest` model is **L7**: the gateway parses and *executes* the
request. For `https://` that means it terminates TLS, sees plaintext, and
re-originates — a textbook **MitM**. Acceptable for fetching public data; a red flag
for anything authenticated or private, because it makes the gateway trusted by
necessity.

### Drop to L4: CONNECT as a byte tunnel

Instead of *making* the request, the gateway opens a TCP socket to `host:port` and
shuttles bytes. **TLS terminates device ↔ origin, end-to-end** (HTTP `CONNECT` proxy
semantics):

- The gateway is a dumb pipe — it sees TLS ciphertext and the destination
  `host:port` (SNI), never content.
- If the CONNECT setup is sealed to the gateway and the stream is opaque TLS records,
  **intermediate relays see only opaque bytes** — no relay is a MitM either; only the
  exit learns the destination.
- More general than L7 (any TCP protocol, not just HTTP); cert validation is the
  device's, not the gateway's.
- Maps onto the existing stream primitives (§20): add e.g. `StreamKind::TcpConnect`,
  carried by `StreamOpen` / `StreamData` / `StreamAck` / `StreamClose`.

### The live-circuit constraint (and what *is* delay-tolerant)

A TLS handshake + TCP socket is stateful and timeout-bound. You **cannot**
store-and-forward a handshake or keep one idle-open across a partition — the origin's
socket times out and RSTs in seconds. So a CONNECT tunnel needs a **live end-to-end
path** for its lifetime: it can cross N hops *only if every hop is up simultaneously*
(a real-time relay circuit, each node forwarding stream frames). It traverses the
*connected* mesh as a circuit, not DTN.

This live requirement is purely an artifact of **talking to the legacy TLS web.**
Between **Hop-aware endpoints** there's no such limit: session state lives only at the
two endpoints (nothing in between holds a socket that can expire), the handshake is
just async messages carried in bundles, and "established" means *keys valid + state
retained*, not *socket open*. Such a session can take minutes/hours/days to form and
persist indefinitely — the **X3DH + Double Ratchet** model (designed for establishing
E2E sessions with an *offline* party). Nice properties: pre-warm a session
asynchronously, then **0-RTT resume** the instant a live path appears; a live
*interactive* stream over it still needs the path live at that moment. Costs to handle:
ephemeral-key retention window (forward secrecy), prekey management, replay/clock-skew
over long spans.

### Mode selection (client decides; never silently downgrade)

The originating device chooses, locally — the gateway never decides, and the choice is
explicit because it changes the trust model:

| Request | Mode | TLS terminates at | MitM? | Path |
|---|---|---|---|---|
| `http://` | bundle fetch (gateway does HTTP) | n/a (plaintext) | n/a | store-and-forward |
| `https://` | CONNECT circuit | origin | no | must be live |
| `https://`, no live path | **queue & wait** for connectivity | — | — | — |
| `https://` + explicit "gateway-fetch OK" | bundle fetch | gateway | yes (opted in) | store-and-forward |

**Hard rule:** end-to-end is the default for TLS; the MitM path requires explicit
opt-in. Never opportunistically fall back from E2E to MitM because the circuit was
slow.

### The real fix: origin-side ingress (not a third-party gateway)

The MitM problem only exists when an **untrusted third party** terminates the
encryption. Move the termination **inside the origin's own trust boundary** — a Hop
ingress behind the server's firewall, run by the same party as the server — and it's
no longer a meaningful MitM (the origin always sees its own plaintext). Identical to
nginx/CDN/service-mesh sidecars terminating TLS in front of an origin today.

Such an ingress is **just a Hop node**: it has an address (= its pubkey), publishes a
service advert, and clients **seal directly to it** — the device-to-device model. That
yields, for free: no third-party MitM, **delay-tolerance** (sealed store-and-forward
bundles to a Hop address), discovery via gossip (no DNS), and long-lived X3DH/ratchet
sessions. Ship it as a **drop-in sidecar** (one binary, point at `localhost:8080`) so
adoption is a deployment step, not a rewrite.

### Adoption reality

Only **one quadrant requires service-provider adoption: delay-tolerant + no-MitM +
this-service.** It's logically forced — store-and-forward means *someone* holds the
message while disconnected; if that someone must be inside the trust boundary and
can't be the client's live TLS, it must be the provider's own node. The other
quadrants need no adoption: online + private is free via CONNECT (Tor-exit-like), and
delay-tolerant + don't-mind-gateway-reading uses the MitM shim. The untrusted egress
gateway stays in the design **only** as a compatibility shim for the legacy web you
don't control; origin-side ingress is the real answer for anything that wants to be
properly Hop-reachable.

## 26. Transports & portability — the bearer is the only thing that changes

> **Status: vision + architecture.** The transport-agnostic seam exists today; the
> per-transport bearers and embedded ports are the roadmap. Tagline: *Hop — the
> network that finds a way.*

**The transport mechanism doesn't matter, by design.** `hop-core` knows nothing
about BLE. It is driven entirely through a tiny byte-frame contract — the same one
`hop-ffi` already exposes:

- `connected(link, role)` / `disconnected(link)` — a transport says a link is up/down.
- `received(link, bytes)` — opaque frame arrived on a link.
- `drain_outgoing() -> [(link, bytes)]` — frames the transport must send.

**A bearer is anything that can move opaque, framed bytes between two endpoints and
say when a link is up.** Everything above that (Noise link encryption, bundles,
sealing, sessions, routing, discovery) is identical regardless of medium. So adding
a transport is writing a bearer, not touching the protocol.

### Transport matrix (role + honest constraints)

| Transport | Role | Notes |
|---|---|---|
| **BLE GATT + L2CAP** | full peer/relay | current focus; short range; iOS background-limited |
| **Wi-Fi (iOS MultipeerConnectivity / AWDL, Android Wi-Fi Direct / local net)** | full peer/relay | medium range, much higher bandwidth; great where available; transport doesn't change the node |
| **TCP / WebSocket** | peer↔gateway, backbone | phone↔gateway hop (a phone can't BLE-reach a cloud box, §25); cloud↔cloud backbone (§21) |
| **Web (browser)** | leaf / gateway client | WebRTC data channels (peer↔peer via signaling), WebSocket (→ gateway); WebBluetooth is central-only with no advertising/background. Browsers can't advertise or run in the background, so the web is a **leaf**, not a relay |
| **ESP32 (BLE + Wi-Fi)** | **always-on anchor / bridge** | the reliability unlock — see below |
| **LoRa / LoRaWAN** | long-range backhaul | km-range, tiny bandwidth, high latency — **DTN-native**; bundles were built for exactly this |

### ESP32 anchors — the reliability unlock

The hardest real problem (DESIGN.md §22) is that two backgrounded iOS apps can't
discover each other. The fix is **always-on anchor nodes**: cheap, mains-powered
devices that are permanently scanning/advertising, so any phone that wakes near one
can hand off and catch up. A $5–10 **ESP32 is the perfect anchor** — it has BLE *and*
Wi-Fi, so a single board is both a local BLE relay and a bridge to the internet/other
anchors.

Home Assistant does a *related* thing with **ESPHome `bluetooth_proxy`**: an ESP32
extends HA's BLE range by forwarding raw advertisements/GATT to HA over Wi-Fi — but
the ESP32 is a dumb radio extender; HA is the brain. Hop's model is stronger: the
ESP32 **runs `hop-core` itself** (it's a full autonomous node), so it relays bundles
over BLE *and* bridges them over Wi-Fi to other Hop nodes/gateways without needing a
central brain. This is feasible because `hop-core` is small, pure Rust and the
embedded Rust toolchain (`esp-rs`/`esp-hal`/`esp-idf`) targets the ESP32 directly.

### What makes this portable: one Rust core, swappable edges

- **Core is pure Rust**, UniFFI for mobile (Swift/Kotlin), and compiles to **WASM**
  for the web and to **Xtensa/RISC-V** for the ESP32. The protocol code is shared
  verbatim; only the bearer (and storage) differ.
- **Storage is already a trait** (`Store`): SQLite on phones (`hop-store-sqlite`),
  but an ESP32 uses a small flash/RAM store, and a browser uses IndexedDB — no core
  change.
- **Work required for embedded:** make `hop-core` `no_std + alloc` (it's close;
  `rusqlite` is phone-only and already isolated behind `Store`), and provide
  per-platform bearer + store impls. The seams are in place; this is implementation,
  not redesign.

### Versus Amazon Sidewalk

Sidewalk is the closest mainstream analogue — a shared low-bandwidth network over
BLE + 900 MHz LoRa, carried by Amazon Echo/Ring devices. Hop targets the same
"ambient connectivity" idea but **open and operator-less**: it runs on any phone,
any ESP32, any app (the cross-app shared fabric, §17), with **end-to-end encryption
the carriers can't read** (§4) and **no central company** required to participate.
Sidewalk's reach is bounded by Amazon hardware ownership; Hop's reach is bounded only
by who installs a Hop-enabled app or plugs in a $5 board — which is how it could end
up *more* ubiquitous. The cost is that ubiquity is earned adoption-by-adoption rather
than shipped in a billion devices on day one (§17 adoption curve).

## 27. Provenance traces & learned routes — utility-prioritized epidemic

Epidemic flood + the delivery-ACK vaccine gets a message everywhere and dedups it at
the destination (§7, the `immune` set). That's robust, but blind flooding spends a
node's finite transmit time and storage on copies that will never matter to it. Each
node should instead spend that budget on the messages most likely to reach their
destination *through it* — and it can learn which those are from the traffic itself,
with no global topology and no coordinator. This section layers that utility on top of
the flood; it does not replace it.

### Every node has its own key — tables and storage are node-local

Identity is per node: the address *is* the keypair (§23). A node's **peer table**,
**learned routes**, and **bundle store** are all keyed to its own identity and are
**node-local**. Two nodes must never share an identity — that would merge their tables
and stores, which is exactly what we don't want, because prioritization depends on
*what this node has seen*.

- **Cloud relays are no exception: one key per region node**, not one key for the whole
  fleet. Region-specific storage and peer tables are the *point* — a region prioritizes
  by what it has observed, and the backbone is a mesh of distinct region nodes that
  flood between themselves (§21), each learning independently.
- Within a region, instances that share that region's identity + store partition act as
  one logical region node; **across** regions, identities differ.
- *Course-correction:* the current Cloud Run bootstrap shares one Secret Manager seed
  across all regions (a deploy shortcut). The target is **one identity per region**, so
  each region keeps its own store partition (`relays/{node}/bundles`) and peer/route
  table.

### Trace metadata — provenance recorded on every hop

Each bundle carries a **trace**: an ordered list of **short hop addresses** (the same
truncated-pubkey short form the UI shows). On forward, a node appends its own short
address before handing the bundle off. The delivery ACK carries *its own* trace back
along whatever path it travels.

The trace is **authenticated header metadata, not sealed payload** — forwarders must be
able to read it to use it. That exposes the path to relays (privacy tradeoff below);
the payload itself stays sealed end-to-end (§4).

### Learning routes from ACK/trace correlation

When a node forwards a send and later sees the **delivered-ACK for the same bundle pass
through it**, and the ACK's trace **overlaps the send's trace at this node**, the node
has learned it sits on a *working path between src and dst — in both directions* — even
if it never directly encountered either endpoint.

- It records a **route**: `(src ↔ dst) → preferred neighbor(s)`, with a recency-decayed
  confidence (same half-life discipline as §18/§21, so stale routes fade).
- Over time the node accumulates a routing table learned **purely from observed
  deliveries**. **Peer-of-peer reach** falls out of this for free: a node can prioritize
  toward a dst it can reach via a known peer two hops away, not only dsts it has met.

### Utility-prioritized epidemic (flood, but order and retain by utility)

Still epidemic: a node offers a bundle to every neighbor while hop-limit remains, and
the destination dedups — *we don't care how many copies exist*. What changes is **order
and retention**:

- **Transmit order:** messages whose dst the node has a relationship/route to go first —
  `direct encounter > learned route > peer-of-peer > unknown`. This matters most during
  short BLE contacts where only a few bundles will fit.
- **Retention / eviction:** under store pressure, keep high-utility bundles and evict
  toward-unknown-destination ones first. *A cloud peer that has never seen the receiver
  deprioritizes that message* (lower transmit priority, first to evict) rather than
  dropping it outright.

This is the message-level analogue of §18: §18 ranks **topics** by demand/supply; §27
ranks **individual bundles** by learned route quality to their destination.

### Tiered tables — cloud nodes are the long memory

Table and store capacity scale with the node tier:

- **Mobile nodes** keep small, recent, high-utility tables (limited RAM/storage, evict
  aggressively) — they forget routes quickly.
- **Cloud nodes** keep much larger peer/route tables and stores, so they retain what
  phones forget. They become the **route-learning backbone**: from the traffic they
  relay they accumulate a broad, long-lived map of `(endpoint-pair → path)` and can
  prioritize far better than any single phone. Region-specific (§21): each region node
  learns the routes *its* region's traffic reveals.

### Privacy tradeoff (honest)

The trace exposes the forwarding path (a list of short addresses) to every relay on it.
That is the cost of learned routing. Mitigations to weigh: cap trace length to the last
N hops; let a sender **opt out** of tracing (no learning, maximum privacy); or sign each
hop so traces are tamper-evident but still readable. Same class of metadata exposure as
§19's mailbox-sees-`(AppId, dst)` — payloads (§4) are unaffected.

### Status

Design only. Building blocks exist: epidemic + vaccine (`routing`/`node`), §18
reliability-weighted relay, §21 `RegionRouter`. To build: a **trace** field on the
bundle header; ACK/trace correlation → a per-node **route table** with decay;
utility-ranked transmit/evict ordering; tier-aware table sizing; and **per-region relay
identities** (replacing the single shared Cloud Run seed).

## 28. Demand-summoned cloud nodes — the backbone exists only while devices hold it up

Cloud nodes are **scale-to-zero**: a region node exists only while at least one end-user
device holds a connection to it. No device in a region ⇒ that region's node winks out and
costs nothing. This **refines the "always-on" language of §19/§21**: the backbone is not a
permanently-running fleet — it is an **emergent, demand-driven mesh** that lights up under
traffic and goes dark when idle. *Only end-user devices bring cloud nodes online.*

- **A device summons its nearest region node** (the entrance, §21) and that node holds the
  device's relayed bundles in its **region-local durable store** (the per-region partition,
  §27 — `relays/{node}/bundles`). Compute is ephemeral; the **mailbox is persistent**: when
  the region node scales to zero and later wakes for the next device, it reloads its
  partition and resumes. The durable store is what makes ephemeral compute safe.

- **The mesh forms dynamically as regions light up — but nodes never wake each other.** A
  cloud node comes online *only* when a client in its region connects (client traffic is what
  wakes Cloud Run; that is the **only** wake trigger). When a node wakes, it announces itself
  to the liveness registry and **reaches out to the peers already marked online** — pulling in
  the bundles bound its way, and those online peers, seeing the new arrival, push its traffic
  to it. No node ever dials a sleeping region to wake it. Example: device B's connection
  brings up the `europe-west` (UK) node; the UK node then announces and `us-central1` (already
  up via device A) pushes B-bound bundles over. Add active regions, the mesh grows; as they
  empty, they drop out. The backbone's shape at any instant is just "which regions have a
  device attached right now."

- **Prioritize and flush (§27).** While online, each region node ranks what it holds by
  learned utility and, under cache pressure, **flushes low-utility / unknown-destination
  bundles first**. A node relays what it can, evicts what it must; what survives is what's
  most likely to reach its destination through it.

### Honest open question — non-overlapping online windows

Two region nodes that are **never online at the same time** can't relay directly: if A
(us-central1) holds a bundle for B and A scales to zero before B's UK node ever wakes, a
*live* push never happens. The robust fix is **destination-keyed handoff**: when a node
learns the destination's home region (presence / `RegionRouter`, §21), it writes the sealed
bundle into **that region's durable partition**, so the exit node finds it whenever it next
wakes — no simultaneity required, because Firestore is reachable regardless of which compute
is currently up. So:

- **Live relay** (both region nodes up) is the fast path.
- **Cross-partition handoff** (write to the destination region's mailbox) is the
  delay-tolerant backstop for non-overlapping windows.

Unknown/stale destination region ⇒ fall back to holding locally and/or fanning to active
regions (§21 broadcast fallback). This handoff is the next piece to design; everything
above is the lifecycle it has to fit.

### Backbone addressing — region-specific domains, separate from the relay identity

Three different "addresses" are in play and must not be conflated:

- The **relay identity** is its pubkey (§23) — used for Noise link auth and as the
  store/table key (§27). It is **not** a network locator; you can't dial a pubkey.
- The **client entrance** is the single anycast name `relay.hopme.sh` (§21) — it routes a
  *device* to the *nearest* region. A region node **can't** use it to reach a *specific*
  peer region: anycast would just send it back to the nearest entrance (possibly itself).
- So node-to-node peering needs a **per-region network locator** — each node's connectable
  endpoint, either a region-specific record like `us-central1.relay.hopme.sh` or just the
  endpoint stored in its registry entry. But a locator is used **only to connect to a peer
  already known-online** (next paragraph) — *never* to dial a sleeping node, which would wake
  it and defeat scale-to-zero.

This is the **internal discovery plane**, separate from the client-facing anycast name and
the pubkey identity. The hard rule: **a node is woken only by its own clients; nodes never
wake nodes.** So discovery must be *passive* — reading it cannot cause a wake:

- **Passive liveness registry.** Online nodes heartbeat into a shared store (a well-known
  Firestore doc/collection) with a short TTL; on scale-to-zero the heartbeat stops and the
  entry expires. **Reading the registry is just a Firestore read — it wakes no one**, and a
  sleeping node simply isn't listed.
- **Pull-on-wake.** When a client summons a node, the node heartbeats itself in, reads the
  registry, and **connects out to the currently-online peers** to exchange relayed traffic —
  pushing what it carries for them, pulling what they carry for it. The newly-woken node is
  always the initiator.
- **Never connect to an absent node.** Connections only ever target registry-live endpoints,
  so a node→node connection can't be what wakes a region. Clients are the sole wake source.
- **Offline destination ⇒ no connection at all.** For the cross-partition handoff (§28) you
  don't dial the destination region — you **write the sealed bundle into its durable
  partition** (a Firestore write, which does **not** wake it), and it's delivered whenever a
  client next wakes that region.

**Infra implication:** the core need is a **passive liveness registry** (a well-known
Firestore doc nodes heartbeat into) plus the per-region durable partitions (§27). Each online
node needs a connectable endpoint for live peers — a per-region record `<region>.relay.hopme.sh`
or the endpoint in its registry entry — and those endpoints must accept node-to-node links
from online peers even when client ingress is locked to the LB. Crucially, **never
probe/health-check region endpoints** to infer liveness (that would wake them) — liveness
comes only from registry heartbeats.
