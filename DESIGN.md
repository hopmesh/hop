# Hop, Design

A delay-tolerant mesh network for intermittently-connected devices. Hop carries
**bundles**, self-contained, store-and-forward messages, across BLE links
between phones, relaying hop by hop until a bundle reaches either a **gateway**
(for the public internet) or a **destination device** (for peer messaging).

It is the [Bundle Protocol (RFC 9171)](https://www.rfc-editor.org/rfc/rfc9171.html)
lineage of Delay/Disruption Tolerant Networking, with a BLE bearer, a phone-shaped
routing layer, and an HTTP egress role.

See [MECHANISMS.md](MECHANISMS.md) for a living catalog of every mechanism split by
whether it lives **in the protocol** (`hop-core`, wire-compatible across all hosts)
or is the **host's** to supply (bearers, UI, identity seed), plus the
privacy/identity roadmap.

---

## 1. Goals & non-goals

### Goals
- **Use Case A, internet egress.** A device with no internet emits a sealed HTTP
  request bundle. Any gateway node fulfills it, seals the response, and relays it
  back to the origin device key.
- **Use Case B, device-to-device.** A device sends a sealed message to another
  device's public key; the bundle hops until the destination receives it.
- **One core, two addressing modes.** Both use cases are the same machinery with
  different destinations. The Rust core ships both from day one; BLE comes after.
- **Confidential by default.** Relays carry ciphertext they cannot read.
- **Multi-platform.** Pure-Rust core, native BLE shims on iOS/Android via UniFFI.

### Non-goals (v1)
- Low-latency / real-time delivery. Hop is *eventually* delivered; lifetime is
  measured in hours-to-days, not milliseconds.
- Anonymity / metadata privacy at the Briar level *in v1*. v1 encrypts payloads but not
  metadata; **untraceable-by-default messaging (opt-in trace) is now designed in §39**,
  promoting this from a non-goal. See §10, §39.
- Exactly-once delivery. Impossible over a lossy partitioned network; we do
  at-least-once + idempotency. See §7.
- Non-BLE bearers in v1 (Wi-Fi Aware, MultipeerConnectivity, LoRa). The bearer is
  pluggable so they can be added; only BLE is in scope first.

---

## 2. System model & terminology

- **Node**, any device running Hop. Identified by an Ed25519 public key.
- **Device key / address**, a node's Ed25519 public key. The "device key" the
  product talks about *is* this key. 32 bytes; rendered as a short fingerprint.
- **Bundle**, the unit of store-and-forward. Self-contained, signed, sealed,
  with its own lifetime. The only thing that crosses links.
- **Link**, an established, authenticated BLE connection between two adjacent
  nodes. Carries frames (fragments of bundles).
- **Gateway**, a node advertising the `egress` capability: it has internet access
  and will fulfill internet-destined bundles.
- **Custodian**, the node currently responsible for retransmitting a bundle until
  it is handed off (custody transfer) or expires.

**Radio terminology.** This doc says **BLE** (the low-energy radio, passive and no-pairing)
for the phone bearer and everywhere the wording is our own. That is a deliberate convention,
not an accident: `hop-core` itself carries no radio terminology at all (it is bearer-agnostic,
§26), and the term for the radio in prose is always "BLE", never the bare marketing word. Real
platform API identifiers stay exactly as their SDKs spell them (`CoreBluetooth` on iOS,
`BluetoothLeScanner` on Android, `WebBluetooth` in browsers); those are code, not prose, so
they are kept verbatim rather than reworded.

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
  clamp for the secret; Montgomery form of the public key), the standard
  Ed25519↔Curve25519 conversion (`crypto::address_to_x`, verified by
  `montgomery_correspondence`). So **an address is all you need** to both verify a
  peer's signatures *and* seal messages to it, no separate sealing key is exchanged
  or carried on the wire. This drops `src_x`/`publisher_x` from bundles/adverts and
  lets the Noise link bind the address by checking `address_to_x(address) ==
  authenticated static` (no extra signature). Addresses are shown in **base58**.
- **Layering:** the address (a public key) is the *only* identity the protocol knows.
  Human **common names / contacts are an app concern** (DESIGN.md §23), not part of
  the raw protocol, an app exchanges contact metadata over sealed messages and keeps
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

**The library never owns identity storage, the host app does.** `hop-core`/`hop` (libhop)
is *given* a 32-byte secret at construction and uses it; it does not decide where the
secret lives. The seam:

- **Import** = the constructor (`HopNode.open(dbPath, secret)` / `with_secret`). The
  app hands in the seed on startup.
- **Export** = `node.secret()` → the 32-byte Ed25519 seed, to stash wherever the app
  chooses. The secret *is* the keypair *is* the address, re-importing it reproduces
  the same address (verified by `identity_secret_round_trips_address`).

Where those bytes come from is an **app concern**, not a protocol one:

- **Device-bound (example app default):** derive the seed deterministically from a
  device identifier (iOS `identifierForVendor`). Stable across launches/reinstall with
  zero storage to fail; the trade-off is non-portability. Used because dev-installed
  builds wipe app storage unpredictably.
- **Portable / multi-device:** store a random keypair the app can move. On iOS,
  **iCloud Keychain** (`kSecAttrSynchronizable`) shares one identity across all of a
  user's Apple devices automatically, the "single iCloud user, same key everywhere"
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
  id:           [u8; 32]      // BLAKE3(src || ephemeral_pub || nonce || ciphertext); see below
  src:          PubKey        // Ed25519, 32 bytes
  dst:          Destination   // enum below
  created_at:   u64           // sender clock, ms, advisory only (see §8)
  lifetime_ms:  u32           // discard after created_at + lifetime
  hop_limit:    u8            // decrement per forward; 0 = drop
  flags:        BundleFlags   // request_ack, is_ack, custody_requested, ...
  custody:      Option<PubKey>// current custodian, if custody transfer in use
  payload:      SealedPayload // X25519 + ChaCha20-Poly1305
  sig:          Signature     // Ed25519 over all preceding fields
}

Destination =                 // discriminant order is LOCKED; append-only (see note)
  | Device(PubKey)            // Use Case B, a specific device address
  | AckTo(PubKey, [u8;32])    // ACK routed back to origin for a given bundle id
  | Broadcast                 // flood to everyone (hps:// publishes, §32; §39 private bundles)
  | Vaccine([u8;32])         // §39 delivery vaccine (sec-priv-07): floods ONLY the recognition token,
                              //   NO plaintext delivered id. A holder recovers which held bundle it
                              //   clears by testing token->tag over its held private bundles and drops
                              //   it (epidemic recovery). Omitting the id hides the delivery event from
                              //   any observer that didn't capture the original flood. See §39.
  // NOTE: `InternetEgress` was REMOVED (commit 5dd64d3). Internet egress is now device-addressed
  // via a hops:// request to a hop-endpoint (§30), NOT a mesh-visible destination. This enum is
  // APPEND-ONLY on the wire (postcard encodes variants by index), removing/reordering renumbers
  // the rest and breaks decode across every peer + the relay, which is exactly what that removal did.
  // Bump the bundle wire version on any change (see §13.4 / bundle.rs BUNDLE_VERSION).

// SealedPayload is NON-EXHAUSTIVE below. The wire kind registry also carries
// SessionInit/SessionMessage, Private (§39), ServiceRequest/ServiceResponse (§30), Stream*, and
// Hps* variants, each defined in its own section. (HNS carries NO wire kind: name resolution is an
// out-of-band HTTPS well-known fetch, not a mesh bundle, §30.) The four shown are the original core kinds:
SealedPayload depends on kind:
  HttpRequest  { method, url, headers, body, max_resp_bytes }
  HttpResponse { status, headers, body, for_bundle_id }
  PeerMessage  { content_type, body }
  Ack          { for_bundle_id, status, delivery_hops, delivery_ms, proof: Option<[u8;32]> }
                              // `proof` (v4, core-protocol-r2-04): recipient-only CDH token on a
                              // PRIVATE ACK = recognition_shared(recipient_spk_secret, orig.ephemeral).
                              // The sender flips to Delivered iff recognition_tag_from_shared(proof,
                              // for_bundle_id) == orig.private.tag. None on the identity-signed traced
                              // ACK path. This trailing field is the v3->v4 wire bump (§39).
```

The bundle `id` derivation depends on the destination class. A normal bundle uses
`compute_id = BLAKE3(src ‖ ephemeral_pub ‖ nonce ‖ ciphertext)` (bundle.rs). A §39 private
bundle drops `src` and domain-separates: `BLAKE3("hop private bundle id v1" ‖ ephemeral_pub ‖
nonce ‖ ciphertext)`. A `Vaccine` is deterministic and self-verifying:
`BLAKE3("hop vaccine id v2" ‖ token)` (sec-priv-07: no delivered id in the pre-image), so all
vaccines for one delivery still dedup to a single flood (the token is unique per delivered bundle)
and a tampered token yields a different id.

Bundles are immutable once created and signed, except the mutable forwarding
envelope (`hop_limit`, `custody`) which is **not** covered by `sig`, relays may
decrement hop_limit and update custodian without invalidating the signature.
(Implementation: split into a signed inner header + an unsigned forwarding header.)

### Fragmentation
BLE ATT MTU is ~185-512 B and even L2CAP CoC has bounded SDU sizes. The Link layer
fragments a bundle into ordered frames and reassembles on the far side. Frames:
`{ bundle_id, frag_index, frag_count, bytes }`. Reassembly buffers are bounded and
time out. Large payloads (HTTP responses) ride L2CAP CoC, not GATT notifications.

---

## 6. Routing

Routing decides, for each stored bundle and each newly-discovered peer, **whether
to hand this bundle to that peer.** No global topology, no addresses-as-locations.

### Device-to-device (B): binary Spray-and-Wait

The problem: in an intermittently-connected mesh there is no path to query, so the
two naive options are bad. **Epidemic routing**, copy to *every* peer you meet, delivers well but the copy count explodes, and so do storage and radio time.
**Direct delivery**, keep one copy, hand it only to the destination, has minimal
overhead but terrible latency (you must physically encounter the destination).
Spray-and-Wait is the tunable middle.

A bundle is born with a **copy budget L** (`BundleOpts.copies`, default 8). That
budget is the *total* number of copies allowed to exist in the network, it travels
with the bundle in the (unsigned) envelope, so it survives handoffs.

- **Spray phase** (`copies > 1`): on meeting a peer that doesn't already have the
  bundle, the custodian does a **binary split**, gives the peer `floor(n/2)` of its
  copies and keeps `ceil(n/2)` (`Bundle::split_copies`). Both can now spray further.
  Starting from 8: `8 → 4+4 → 2+2 → 1+1`, so after ~log₂(L) good encounters the
  copies are spread across up to L distinct carriers fanning out in parallel.
- **Wait phase** (`copies == 1`): a carrier down to its last copy stops spraying and
  holds it, delivering **only** when it directly meets the destination.
- **Direct delivery always wins:** at any time, if the peer *is* the destination, the
  bundle is handed over regardless of phase (and custody released).

Why binary specifically: among spray schemes under random mobility, the binary
split minimizes expected delivery delay, it spreads copies to independent carriers
fastest, maximizing the chance one of them encounters the destination soon. L is the
single knob trading overhead (≤ L copies, bounded) against delivery probability and
latency. The simulator (`hop-sim`) is where we'll tune L against contact traces;
see test `binary_spray_splits_copies_then_delivers`.

**Optional later, PRoPHET hint:** instead of spraying to *any* fresh peer, prefer
peers with higher historical delivery-predictability for the destination. The same
encounter statistics that power reliability-weighted relay (§18) feed this. Pure
spray-and-wait works without it; we add it only if the simulator shows it helps.

### Internet egress (A): device-addressed hops:// request
- Egress is no longer a mesh-visible `InternetEgress` destination (that variant was
  removed, see §9). It is a `hops://` **service request addressed to an endpoint node by
  its key** (`Destination::Device`), served by `hop-endpoint` (§30). The request routes
  like any device-addressed bundle and the sealed response routes back to the caller's key.
- The caller learns an endpoint's key out of band (a published service, HNS, or a bundled
  default); the mesh does not need a gateway gradient because the destination is a concrete
  address, not a role.

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

## 7. Two Generals, and why we're not actually facing it

The Two Generals Problem is unsolvable for one specific thing: **bilateral,
simultaneous agreement to act.** Both generals must attack *together*, so each needs
to know that the other knows that they know…, an infinite regress any finite
protocol breaks by losing its last message. That impossibility is real, but it is
**not the problem Hop has.**

Message delivery is **unilateral**. The destination doesn't need the sender's
permission to act: the instant it has the message, it delivers it to the user. It
acts alone. That asymmetry collapses the regress, only the *forward* path must
succeed; the ACK going back is bookkeeping. So the goal decomposes:

- **Exactly-once delivery on the wire**, impossible, and we don't need it. Copies
  can duplicate.
- **Exactly-once *processing/effect***, **achieved.** At-least-once forward delivery
  + dedup by bundle id means duplicates are no-ops; the user sees the message once.
- **The sender's *certainty* of success**, arbitrarily high (retransmit until ACK),
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

**The one real obligation, a bounded dedup window.** Exactly-once *processing* holds
only as long as a destination remembers a bundle's id for at least as long as a
duplicate of it can still arrive, its lifetime. So the `seen` set carries a
**receiver-anchored expiry** (`now + lifetime` at first sight, robust to sender clock
skew) and `Store::prune` drops entries past it. This bounds memory without weakening
the guarantee inside the window that matters. The SQLite backend persists `seen`, so
the guarantee survives restarts. (Tests: `dedup_window_closes_after_lifetime_then_reaccepts`,
`prune_closes_dedup_window`; ACK flow: `ack_returns_and_clears_sender_pending`.)

**The residual, quarantined to the UI.** What survives of Two Generals is only the
*sender's knowledge*. Worst case: a message was delivered but the ACK never returned,
so the sender shows "sent" (then "gave up") instead of "delivered ✓". That is a
**false negative on an indicator**, never a lost message, never a duplicated effect,
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

> **Status (F-32): `hop-gateway` is ORPHANED.** Internet egress is no longer a mesh-visible
> `InternetEgress` destination, it is now a device-addressed `hops://` request served by <!-- docs-token-guard: allow (documents the removal) -->
> `hop-endpoint` (§30). The `hop-gateway` crate below has NO consumers (no binary, no `use
> hop_gateway`) and was built around the removed variant; its abuse controls (dedup, rate limit,
> size caps) should be ported into `hop-endpoint` (see F-19) and the crate deleted or given a real
> binary + addressing story. The description below is retained for that port, not as shipped behavior.
>
> `Gateway::fulfill` returns a structured
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
| Traffic-analysis / metadata privacy | ❌ v1 → §39 | v1: relays see src/dst headers. §39 designs untraceable-by-default (no cleartext src/dst, recognition-by-tag, flood) with opt-in trace. |
| Sybil / flooding resistance | ⚠️ | hop_limit, spray cap, per-peer rate limit; not robust against a determined adversary |
| Gateway request abuse | ⚠️ | rate limit + URL policy + size caps |

Hop is **not** an anonymity network in v1. §39 designs the move toward it, no cleartext
src/dst in headers, recognition-by-tag, flood delivery (untraceable by default, opt-in
trace), as a deliberate redesign of §5's header.

---

## 11. BLE bearer, the constraint that shapes everything

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

**The contract is a C ABI, not UniFFI.** The one thing every non-Rust client binds is
`sdk/hop.h` (cbindgen over the `hop` crate): the universal floor for Swift, Kotlin, ObjC,
C++, and ESP32. UniFFI is now optional mobile sugar layered on top, not the embedding
surface. This is the locked decision recorded in `docs/libhop-architecture.md`.

```
hop/
├─ core/
│  ├─ hop-core/          # pure Rust core
│  │   ├─ bundle         # addressed store-and-forward messages (§5)
│  │   ├─ crypto         # identity, sealing, signatures (§4)
│  │   ├─ discover       # gossiped service/peer directory + pub-sub (§15 §16)
│  │   ├─ node           # the event loop tying every layer together
│  │   ├─ relay          # reliability-weighted relay scoring (§18)
│  │   ├─ routing        # spray-and-wait + gateway gradient (§6)
│  │   ├─ link           # Noise XX sessions + fragmentation (§4)
│  │   ├─ stream         # ordered SSE/WS reassembly + resend buffer (§20)
│  │   ├─ store/util
│  │   └─ (AppId)        # shared-fabric app namespace (§17)
│  ├─ hop/               # the C-ABI client crate (cbindgen → sdk/hop.h); optional UniFFI bindings
│  ├─ hop-wasm/          # wasm-bindgen wrapper (browser swarm sim)
│  ├─ hop-sim/           # discrete-event mesh simulator for routing tests
│  └─ stores/
│      ├─ hop-store-sqlite/    # persistent Store backend (rusqlite/SQLCipher), §13.2
│      └─ hop-store-firestore/ # backbone mailbox store
├─ sdk/                  # hop.h (the C ABI) + language wrappers (Swift/Kotlin)
├─ bearers/             # one isolated package per bearer (BLE, LAN, relay), per platform; Apple Multipeer/Wi-Fi P2P stays in-driver
├─ drivers/             # per-platform host driver (radios + lifecycle) over the C ABI
├─ services/            # hop-endpoint (hops:// origin ingress), hop-gateway, hop-relay(d)
├─ apple/               # iOS app + smoke tests
└─ android/             # Android app + smoke tests
```

- **`hop-core`** owns everything deterministic: bundle codec, routing policy, store,
  crypto, link framing/reassembly. No async radio assumptions, it's driven by
  events (`on_peer`, `on_frame`, `tick`) so it runs identically in tests, the
  simulator, and on-device.
- **`hop` (the C-ABI crate)** exposes a small, stable surface (create identity, submit bundle,
  poll outbox/inbox, feed peer/frame events) through `sdk/hop.h`. UniFFI Swift/Kotlin
  bindings are an optional convenience layer over the same core.
- **Bearers and drivers** implement only the byte-frame `Bearer` contract against
  CoreBluetooth / Android BLE / LAN / relay and pump events into core. They contain
  *no protocol logic*.
- **`hop-sim`** lets us validate routing (delivery ratio, overhead, latency under
  churn/partition) without phones, essential, because field-testing a mesh by hand
  is brutal.

---

## 13. Open questions to resolve next

1. ~~**Gateway sealing** (§9)~~, **DECIDED: approach (c).**
2. ~~**Store backend**~~, **DECIDED & IMPLEMENTED: SQLite** (`rusqlite`, bundled).
   Most mature and battle-tested on both iOS and Android, survives crashes, and is
   ready for indexed queries over the forward queue + directory. Lives in
   `hop-store-sqlite` behind the (now backend-agnostic) `Store` trait, so `hop-core`
   stays pure-Rust/no-C and the FFI/sim builds aren't burdened. `Node` is generic over
   `Store` (`Node::with_store`), so it runs on either memory or SQLite. Encryption at
   rest via SQLCipher or app-supplied page encryption; `MemoryStore` remains for
   tests and the simulator. Tests cover dedup-across-reopen and copy-budget persistence.
3. **Routing v1**, start with pure binary spray-and-wait (simplest correct thing)
   and add PRoPHET/gateway-gradient once the simulator shows the need?
4. ~~**Bundle codec**~~, **DECIDED: `postcard`** (compact, Rust-native; native
   apps consume via the `hop` C ABI, so CBOR interop isn't needed).
5. **Identity backup / recovery**, losing the keypair = losing your address. Out
   of scope for protocol v1 but a product question that affects key storage.

---

## 14. Build order (dependency sequence, no dates)

- **Phase 0, Spec.** This document. Resolve §13 (1) and (4) before coding format.
- **Phase 1, Core data plane.** `hop-core`: bundle codec + crypto (identity, seal,
  sign, dedup) + store. Property tests for round-trip and dedup.
- **Phase 2, Routing + simulator.** `hop-sim` + binary spray-and-wait + gateway
  gradient. Measure delivery ratio/overhead under churn and partition.
- **Phase 3, Link layer.** ✅ Noise XX sessions (`link::LinkHandshake` /
  `LinkSession`, via `snow`) + fragmentation/reassembly (`link::fragment` /
  `Reassembler`). Remaining: drive sessions from the node loop over a real bearer.
- **Phase 4, Gateway.** `hop-gateway`: HTTP fulfillment, request dedup, abuse
  controls. End-to-end A in simulation.
- **Phase 5, FFI + native BLE.** ✅ `hop-ffi` (since renamed to the `hop` crate, now
  C-ABI-first): UniFFI-exported `HopNode` wrapping the
  real node loop (`cdylib`/`staticlib` build for Android/iOS; end-to-end tested from
  Rust). Remaining: run `uniffi-bindgen` to emit Swift/Kotlin, and the native BLE
  shim implementing `Bearer`. First real two-phone hop.
- **Phase 6, Internet-assisted relay.** `hop-relay`: TCP/QUIC bearer + federated
  mailbox store (§19). Long-distance hops once any carrier touches the internet.
- **Phase 7, Streaming sessions.** Gateway-held SSE/WebSocket (§20): async upstream
  IO, session persistence, and reconnect-on-deploy. Ordering core (`stream`) done.

---

## 15. Relayed discovery (gossiped directory)

Bundles (§5) are *addressed*, you must already know the destination key.
Discovery answers the prior question: **how do you learn a peer or service exists,
and get its keys?** Nodes publish signed **adverts** that flood the mesh
epidemically and land in every node's local **directory**. You see an advert the
moment you meet *any* node carrying it, that is the product's transitivity rule:
*"discoverable as soon as I've seen another device that has also seen it."*

- **Advert** = `{ id, body, sig }`, `id = BLAKE3(body)`, signed by the publisher so
  it can't be forged. Body carries the publisher's address **and** sealing key, so
  a discoverer can immediately send a sealed device-to-device bundle back.
- **Kinds:** `Peer{display_name}` (add-me-by-key), `Service{service,title,summary,
  tags}` (a job-board post, a marketplace listing), `Tombstone{revokes}` (sold /
  closed, removes a prior advert before its TTL).
- **Gossip the index, fetch the object.** Adverts stay tiny (summary + keys). Heavy
  content (listing photos) is *not* flooded, it's fetched on demand via an
  addressed bundle to the publisher. Keeps the mesh cheap.

**Marketplace flow (User A sells a bike → User B finds it):** A publishes a
`Service{service:"market", title:"Bike for sale", …}` advert → it gossips A→R→…→B
hop by hop → B, having met any node that saw it, finds it in B's directory →
B reads A's keys from the advert → B sends a sealed `PeerMessage` bundle to A to
inquire. B and A never had to meet directly. (`discover::Directory`,
test `relayed_discovery_then_contact`.)

Adverts are **public** to the mesh, correct for a public board/marketplace.
Private peer discovery (rendezvous via a shared secret, no cleartext metadata) is
future work (§10).

## 16. Services as pub/sub topics, and keeping relays light

A **service is a topic**. Offering a service = broadcasting adverts on it;
consuming it = **subscribing**; and *every* device relays best-effort regardless of
whether it subscribes. This makes the directory a topic pub/sub bus.

The cost problem: if everyone relays everything, relay storage is unbounded. So:

- **Subscription-aware retention.** Subscribed topics (plus the reserved
  `_control` topic) get **full retention**. Everything else lands in a **bounded,
  compressed, LRU relay cache** (`DEFAULT_RELAY_CACHE_CAP`), best-effort carry for
  strangers that can never blow up local storage. Subscribing later *promotes*
  already-cached adverts to full retention.
- **Compression is first-class.** Relay-cache entries are stored DEFLATE-compressed
  (`util::compress`, pure-Rust `miniz_oxide`); adverts are kept small by design.
  (Future: link-layer frame compression for bulk transfers too.)
- **Supersession & expiry.** `seq` lets a publisher supersede an edited listing;
  TTL + tombstones bound lifetime; `Directory::expire` GCs both stores.

(`discover::Directory`, tests `relay_cache_is_bounded_and_evicts_oldest`,
`subscribed_topics_get_full_retention`, `subscribing_promotes_already_cached_adverts`.)

## 17. The shared fabric, Hop as an embeddable library

Hop is meant to be embedded as a **plugin/library inside other apps**, not shipped
as one monolithic app. The failure mode to avoid: each app forms its own private
mesh and a lone app has no one to relay through. So the fabric is **shared**:

- **One BLE service UUID for all Hop apps.** Any Hop-enabled app recognizes any
  other as a relay peer and forwards its traffic. Relaying is not limited to
  instances of a single app, that's what makes a sparse deployment viable.
- **`AppId` namespacing.** Every bundle and advert carries a 16-byte `AppId`
  (`app_id("com.example.jobs")`; `FABRIC_APP` is the shared/default namespace for
  cross-app concerns like peer discovery). An app demultiplexes its own traffic by
  `AppId`; relays carry **all** apps' traffic indiscriminately.
- **Isolation by construction.** Relays forward ciphertext they can't read (§4), so
  carrying another app's bundles leaks nothing. Headers do expose `AppId` + topic to
  on-path relays (needed for routing/prioritization), a metadata trade-off noted in
  §10.
- **Embedding surface.** The host app links `hop` (libhop) via the C ABI (`sdk/hop.h`;
  optional UniFFI Swift/Kotlin sugar), provides identity persistence + storage, and either uses Hop's default BLE bearer
  or supplies its own `Bearer` impl. All protocol logic stays in `hop-core`.

### Deduplicating the same device running Hop in multiple apps

Hop is embedded per-app, and mobile OSes sandbox each app into its own process,
BLE stack, and storage. So if a user has two Hop-enabled apps installed, by default
the **one physical device runs two Hop nodes with two identities**, it shows up as
two peers/relays. Dedup is possible at some layers, impossible at others:

- **Message delivery, already deduped, no work needed.** Dedup is by `BundleId`
  plus the receiver-anchored dedup window (§7). If a device relays the same bundle
  through several of its app-instances, the destination still **processes it exactly
  once**. Redundant relay nodes waste radio, never cause duplicate delivery.
- **Identity / presence, dedup only *within one publisher*.** Apps from the **same
  developer** can share a single Hop identity by storing the identity secret in a
  shared **Keychain access group** (iOS) / shared keystore or signature-permission
  `ContentProvider` (Android). All of that vendor's apps then use the **same address**
  and present as **one node**. Apps from **different developers** can't, the sandbox
  blocks shared identity and shared BLE, so they stay distinct nodes. Merging them
  would require a device fingerprint, which breaks the address-is-the-public-key
  privacy model (§4); we deliberately don't.
- **Radio / bearer, partial.** Same-developer apps can additionally share an **App
  Group** (iOS) / bound service (Android) to elect a single active bearer (heartbeat
  lock) so they don't all scan/advertise at once. iOS background scheduling makes
  "exactly one" best-effort, not guaranteed. Cross-developer radio redundancy is
  unavoidable, but each extra node *adds coverage* to the shared fabric rather than
  conflicting.

**Net:** duplicate *delivery* never happens (BundleId dedup). Duplicate *presence/
relay identity* for one device is removable across a single vendor's apps (shared
keychain identity + bearer election) and inherent across vendors, where the design
turns it into cooperation (mutual relaying) rather than a conflict.

## 18. Reliability-weighted relay

A node learns *which topics it is a good relay for* from whom it repeatedly meets,
and prioritizes those paths. Motivating case: **"I regularly meet 4 people who want
job-board updates from company X, and I regularly pass company X, so I'm a reliable
bridge for that topic; I should pin it and offer it first."**

This is PRoPHET-style delivery predictability (recency/frequency-weighted encounter
history) specialized to pub/sub topics. Per topic, two recency-decayed signals:

- **demand**, distinct peers we meet who *want* the topic;
- **supply**, peers we meet who *carry/originate* the topic.

`score(topic) = demand · (0.25 + supply)`, bridging strong demand and live supply
scores highest; demand alone still has some value. Encounters decay on a half-life
so the score tracks *current* reliability, not ancient history. Used to:

- **Pin** high-scoring topics to full retention even under relay-cache pressure
  (`Directory::pin_hot_topics`).
- **Order** gossip offers so the most valuable adverts go first during short BLE
  contacts (`Directory::gossip_offer_ranked`).

## 19. Internet-assisted relay (the online store)

BLE-only mesh is bounded by physical proximity chains. But the moment *any* carrier
along the path has internet, even briefly, Hop can leap continents. An online
device parks its bundles in a shared **Hop online store**, and a different online
device near the destination picks them up. The internet becomes one very long,
very fast hop in the same store-and-forward model.

**It's the same protocol, a different bearer.** Online nodes speak the existing
bundle protocol over TCP/QUIC/WebSocket instead of BLE, the `Bearer` trait already
abstracts this (§11), so the core is unchanged. What's new is a rendezvous store so
two online nodes that are *not simultaneously connected* can still relay.

**The online store is an untrusted, best-effort mailbox keyed by destination.**
- Bundles are already sealed end-to-end (§4), so the store holds **ciphertext it
  cannot read**. It indexes by `(AppId, Destination)` and topic, with TTL.
- An online node **pushes** bundles it's carrying whose destination it can't reach
  locally; an online node near a destination (or subscribed to a topic) **pulls**
  matching bundles and re-injects them into its local BLE mesh.
- Adverts (§15 §16) ride the same path: the online store doubles as a wide-area
  pub/sub broker, so a marketplace listing in one town becomes discoverable in
  another the instant both touch the internet.

**Topology options (decide before building):**
- (a) **Federated mailbox servers**, a set of well-known endpoints (operated like
  the gateways of §9, possibly the *same* nodes). Simplest; needs operators.
- (b) **DHT**, a Kademlia-style overlay of online nodes storing bundles keyed by
  destination, no central operator. More robust, much harder (NAT traversal,
  churn, eclipse/Sybil resistance).
- v1 leans (a), federated mailboxes co-located with gateways, and treats (b) as
  the decentralization endgame.

**Why it's harder (called out honestly):**
- **NAT traversal / reachability** between online peers (hole-punching, relays).
- **Who runs it & discovery** of online endpoints (ship a seed list; let gateway
  beacons (§6) also advertise mailbox endpoints).
- **Metadata exposure:** the store sees `(AppId, dst)` and access patterns even
  though payloads are sealed, worse than a transient BLE relay. Mitigations
  (destination blinding, mailbox sharding) are future work tied to §10.
- **Abuse at internet scale:** rate limits, proof-of-work or auth, per-dst quotas,
  size/TTL caps, the store is a spam magnet otherwise.
- **It doesn't change Two Generals (§7).** The online store raises delivery
  *probability* dramatically; it does not provide certainty. Same at-least-once +
  idempotency + ACK machinery applies end-to-end.

**Build placement:** a new `hop-relay` crate (online super-node: TCP/QUIC bearer +
mailbox store), reusing `hop-core` bundles and likely sharing a process/host with
`hop-gateway`. Sequenced after the BLE path proves out (a new Phase 6).

(`relay::RelayScorer`, tests `bridging_demand_and_supply_outranks_demand_alone`,
`repeated_encounters_beat_one_offs_and_decay_over_time`.)

## 20. Streaming sessions, gateway-held SSE / WebSocket

A long-lived HTTP stream (Server-Sent Events, WebSocket) **cannot live on an
intermittently-connected device**, the socket would drop every time BLE flaps or
the app backgrounds. So the device never holds the upstream socket. Instead:

**The gateway holds the connection on the device's behalf** and relays it as an
ordered sequence of bundles. The device opens a logical stream; the gateway opens
the real upstream connection, pumps each event/frame back as numbered `StreamData`
bundles, and writes device→server frames (WebSocket) from the bundles it receives.

**Always via the gateway, even when the device is online.** The device connects
*logically to the gateway*, never directly to the origin server, regardless of its
own connectivity. This decouples device liveness from upstream liveness: the upstream
connection stays up at the gateway while the device comes and goes, so intermittent
connectivity **never causes a stream failure**, the device just catches up from where
it left off. One uniform, resilient path instead of two code paths (online vs offline).

**Wire protocol** (`Payload::Stream*`, sealed end-to-end device↔gateway like any
bundle):
- `StreamOpen { stream_id, kind: Sse|WebSocket, method, url, headers }`, establish.
- `StreamData { stream_id, seq, bytes, fin }`, one ordered chunk, either direction.
- `StreamAck { stream_id, ack }`, "I have everything contiguously through `ack`."
- `StreamClose { stream_id, reason }`, tear down (or signal *reopen*; see below).

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
- **Persist session state**, the stream registry (per `stream_id`: kind, upstream
  request, last-delivered and last-acked seq, buffered unacked chunks). On restart
  the gateway reloads this and **reconnects upstream**, resuming from the device's
  last ACK.
- **Resumable vs not**, if the upstream supports resumption (SSE `Last-Event-ID`,
  app-level cursors) the gateway resumes transparently. If it can't, the gateway
  sends `StreamClose{reason: reopen}` and the device transparently re-opens, the
  user-visible stream survives even when the underlying socket couldn't.
- **Versioning**, the stream protocol is versioned (bundle `version` + a stream
  envelope version) so a newer gateway can read sessions written by an older one;
  unmigratable sessions degrade to a clean reopen rather than a hang.

**Status.** The ordering/resend core (`stream::StreamReassembler`, `StreamBuffer`)
and the `Payload::Stream*` wire types are implemented and tested. The gateway-side
async upstream IO (real SSE via `reqwest`, WebSocket via `tokio-tungstenite`),
session persistence, and reconnect-on-deploy are the next implementation phase
(Phase 7), building on `hop-gateway` + the SQLite store.

## 21. The cloud backbone, zero-distance peers and region-aware routing

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
implemented & tested), the §18 demand idea lifted from peers to **regions**:
- **presence**, which region a device address was last reachable through, so an
  *addressed* bundle goes to **one** region (the destination's) instead of flooding
  all of them. Unknown/stale ⇒ fall back to a broadcast.
- **demand**, per `(app, topic)`, how much live subscriber interest each region has.
  `should_route_topic_to` is false once a region's demand decays below threshold, and
  `target_regions` returns only regions worth fanning to, ranked by demand. A region
  whose subscribers all went away simply drops off the fan-out, no wasted egress.

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

### One DNS, many nodes, closest entrance, closest exit, lowest latency

The backbone is **one hostname resolving to many relay nodes**, and traffic should
always use the lowest-latency entrance and exit.

- **Entrance (device → backbone): lowest-RTT relay.** A single name (e.g.
  `relay.hop.net`) fronts the whole fleet via **GeoDNS and/or BGP anycast** (anycast
  routes a device to the topologically-nearest PoP automatically). The device then
  **races** the resolved endpoints and keeps the fastest, today `NWConnection` with a
  hostname already does happy-eyeballs (it connects to the quickest-responding resolved
  IP), giving a first cut for free; an explicit RTT race over the top-N records is the
  refinement.
- **Exit (backbone → device): the destination's current relay.** A bundle for B must
  leave the backbone at the relay **B is currently attached to**, which is the
  closest exit by definition. `RegionRouter` tracks each address's current region from
  presence, so the backbone files the bundle and points the fetch at B's region instead
  of flooding every region. Delay-tolerant: if B is offline, the mailbox holds it
  until B's region reappears.
- **Relay ↔ relay discovery across regions.** Relays form a backbone mesh via a
  **membership layer**, a seed list / registry plus gossip (SWIM-style) so the set
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
restricted on both platforms, differently, so we lean on **periodic beaconing to
stay discoverable, OS wake mechanisms to come back to life on BLE events, and local
notifications to surface a delivered message** (no server, no APNs/FCM, the "push"
is local, triggered by a bundle that arrived over BLE).

### iOS, the constraints, and the wakes that beat them

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
    works backgrounded (it's coalesced/slow, and `nil` services is disallowed), we
    always pass the Hop UUID, so it's compatible.
  - **iBeacon region wake (optional, strong).** Advertise an iBeacon and have peers
    `CLLocationManager` **monitor that region**; region *enter* relaunches a suspended
    or killed app in the background, a reliable proximity wake that doesn't depend on
    the GATT service UUID. A good complement for cold discovery.
  - **Foreground/always-on nodes are the backbone (§11, §21).** A plugged-in device,
    a Mac, or a cloud node stays a reliable rendezvous that backgrounded leaves sync
    against when woken.
- **Background App Refresh.** Register a `BGAppRefreshTask` (BackgroundTasks /
  SwiftUI `.backgroundTask(.appRefresh:)`) to periodically `tick` the node, retransmit unacked bundles, prune the dedup window, re-advertise, drain, then
  reschedule. Best-effort cadence, set by the OS from usage.
- **Local push.** On delivery while not foreground, fire a `UNUserNotificationCenter`
  local notification. Authorization is requested once at startup.

### Android, foreground service + offloaded scan

- **Foreground service** (`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_CONNECTED_DEVICE`,
  a persistent notification) owns the bearer so BLE keeps running and isn't subject to
  background-scan throttling. This is the primary keep-alive.
- **Offloaded scanning** via `BluetoothLeScanner.startScan(filters, settings, PendingIntent)`
  lets the system wake the app on a Hop-service match **even when not running**, the
  Android analogue of iOS state restoration.
- **Periodic ticks** via `WorkManager` (or the service's own timer) for retransmit /
  prune / re-advertise.
- **Local push** via `NotificationCompat` (with `POST_NOTIFICATIONS` on Android 13+)
  when a message is delivered in the background.

### What this realistically buys us (honest)

- **Foreground ↔ anything**: solid, discovery, link, relay all work.
- **Backgrounded ↔ foregrounded/always-on**: works via restoration / offloaded scan;
  the message wakes the app and a local notification fires.
- **Two cold-backgrounded iPhones with no backbone nearby**: weakest case, likely no
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
`address_from_base58` in `hop` (libhop)). There is no separate identifier, no UUID, no
name registry in the protocol. A public key is already globally unique, more so
than a random UUID, and it's the one identifier you *must* have anyway, because:

**You cannot message a peer without its public key, and all non-broadcast traffic
is encrypted (§4).** The sealing key is **derived from the address**: the Ed25519
verifying key converts to its Curve25519 (Montgomery) form, which is the X25519
public used to seal. So *seeing an address is sufficient to seal to it*, no key
exchange, no lookup. `crypto::address_to_x` does the conversion;
`crypto::seal(to_address, …)` takes an address directly. (Test:
`montgomery_correspondence`.)

This collapses identity, signing, and sealing into one key (§4) and removes the
entire address/name service the protocol previously carried.

### Names & contacts are an app concern, not the protocol

The protocol deliberately knows **nothing** about common names. Human-friendly
naming is a *local* problem, only the people who know you care what you're called,
and they're free to disagree. Pushing it into the wire format would force global
name resolution, collision rules, and a distributed registry into every relay for
something that's ultimately a per-user address-book label.

**Broadcasts are reserved for services (§15 §16).** Public, unencrypted gossip is
only for service adverts; user peer-to-peer traffic is always sealed. An app that
wants presence/discovery publishes a **service** and builds its contact book on top:

- **Presence.** A chat app publishes a `presence` service advert whose `title` is
  the user's chosen display name (`node.publish_service("presence", name, …)`). It
  floods the mesh like any service, so you discover a user the moment you meet any
  node that has seen them, including multiple hops away (`hops` on the hit). The
  advert's `publisher` field is the address you message. (Test:
  `discover_presence_two_hops_away_and_message_it`.)
- **Contacts (app-side).** The app browses `presence` (`node.browse("presence",
  None)`), and keeps a **local** contact book: address → chosen name. Conflicts are
  allowed, only the local user cares about real names. If two peers advertise the
  same display name, the app disambiguates however it likes (e.g. base58 suffix);
  it can resolve by claim timestamp carried in the advert if it wants determinism.
- **Private contact exchange.** Because seeing an address is enough to seal to it, a
  chat app can let a user request another's contact details with a **sealed**
  message ("who are you?") and reply with metadata, tying name↔address privately
  without any public name broadcast.

None of this is in `hop-core`; the demo app (`apps/apple/HopDemo`, `apps/android/HopDemo`)
implements presence + a contact book on top of the generic service API as the
reference example.

### Online resolution (gateways)

Gateways still offer value as a **directory of services**, an internet-connected
device can query a gateway to browse services (including presence) it hasn't met
transitively yet. The gateway query/response over the bundle protocol
(`Payload::Resolve{Request,Response}`) is the next piece; the local service
directory + browse logic are implemented.

## 24. Service confidentiality, public & private broadcasts

> **Status: design only.** Captured for later; build after the p2p layer is locked
> down. §16 covers the *relay/retention* mechanics of services; this section covers
> their *confidentiality* model.

A service is the **one-to-many** dual of a p2p message (which is one-to-one). The
crypto for "broadcast readable by a group but no one else" is not just "publish a
public key", and reasoning it through gives a clean, uniform model.

### Why a public key alone can't make a confidential broadcast

- Signing with the service key gives **authenticity, not confidentiality**. "Anyone
  with the pubkey can read it" means the content is *signed plaintext*, the pubkey
  *verifies*, it does not decrypt. (With Ed25519 you can't "encrypt with the private
  key" at all; the operation is sign/verify.)
- Sealing (§4) is **per-recipient**, you can't seal "to everyone".
- Therefore a confidential broadcast **requires a shared content key** held by the
  audience. Public-key crypto alone cannot do it.

### Two encryption layers (don't conflate them)

- **Link layer (Noise XX):** every byte on the radio is already encrypted hop-by-hop.
  But each relay decrypts to route, so relays can read *unsealed* content.
- **End-to-end (sealing / content key):** only the intended audience reads; relays
  carry opaque ciphertext.

Design decision: **every service broadcast is encrypted end-to-end under a content
key, there are no plaintext broadcasts.** Relays always carry ciphertext.

### Separate identity from the read capability

Two distinct keys, always:

- **Signing / identity key `S`**, the service keeps `S_priv` secret *forever*; never
  distributed. `S_pub` (or its hash) is the **service ID**: used for discovery,
  subscription, addressing, and verifying authenticity. It never decrypts anything.
- **Content key**, the thing that gates reading, distributed to the audience.

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
  holder can also encrypt, but that's fine, authenticity comes from `S`, not `K`.
- **Asymmetric `(E_pub, E_priv)` (optional):** distribute `E_priv` to members; the
  service encrypts with `E_pub`. Its one real benefit is **decoupling send-rights
  from read-rights**, anyone with `E_pub` can encrypt *to* the group without being
  able to read it (only `E_priv` holders read), while `S` still gates what's
  "official". Use only if you want open-submission groups; otherwise prefer `K`. `E`
  must never be `S`.

### Membership / key distribution

- **Admit:** seal the current content key to the member's address (p2p sealing, §4).
- **Revoke:** rotate the content key and re-seal to the *remaining* members, O(members)
  per rotation. Large-scale forward-secret revocation is the group-key problem; an
  MLS-style key tree is the scaling path, not needed for v1.

### One wrap + one signature per message (no double-wrap)

- **Broadcast to all** → encrypt under the content key.
- **Targeted to one subscriber** → seal to that address (normal p2p).
- Never nest the two (don't broadcast-then-seal). And no extra service signature: the
  bundle/advert is **already signed by its source**, which *is* the service identity, that existing signature authenticates the broadcast. Link-layer Noise underneath is
  a separate layer, not double-wrapping.

### Two axes of "private" (be explicit)

- **Content-private** (this section): service is *discoverable* (ID/advert visible),
  messages gated by the content key. The 90% case; build this.
- **Existence-private / unlisted:** even *knowing the service exists* is restricted.
  Can't be solved with a content key (the advert is public), needs the service ID to
  be a secret capability or a rendezvous value derived from a shared secret. Harder;
  ties to private discovery (§10, §15), future work.

## 25. Gateway transport, HTTPS without being a man-in-the-middle

> **Status: design only.** Captured for later; build after the p2p layer is locked
> down *and* after a non-BLE bearer (TCP/WebSocket) exists for the phone↔gateway hop
> (a phone can't BLE-reach a cloud box). Refines §9/§19/§20.

The v1 `Payload::HttpRequest` model is **L7**: the gateway parses and *executes* the
request. For `https://` that means it terminates TLS, sees plaintext, and
re-originates, a textbook **MitM**. Acceptable for fetching public data; a red flag
for anything authenticated or private, because it makes the gateway trusted by
necessity.

### Drop to L4: CONNECT as a byte tunnel

Instead of *making* the request, the gateway opens a TCP socket to `host:port` and
shuttles bytes. **TLS terminates device ↔ origin, end-to-end** (HTTP `CONNECT` proxy
semantics):

- The gateway is a dumb pipe, it sees TLS ciphertext and the destination
  `host:port` (SNI), never content.
- If the CONNECT setup is sealed to the gateway and the stream is opaque TLS records,
  **intermediate relays see only opaque bytes**, no relay is a MitM either; only the
  exit learns the destination.
- More general than L7 (any TCP protocol, not just HTTP); cert validation is the
  device's, not the gateway's.
- Maps onto the existing stream primitives (§20): add e.g. `StreamKind::TcpConnect`,
  carried by `StreamOpen` / `StreamData` / `StreamAck` / `StreamClose`.

### The live-circuit constraint (and what *is* delay-tolerant)

A TLS handshake + TCP socket is stateful and timeout-bound. You **cannot**
store-and-forward a handshake or keep one idle-open across a partition, the origin's
socket times out and RSTs in seconds. So a CONNECT tunnel needs a **live end-to-end
path** for its lifetime: it can cross N hops *only if every hop is up simultaneously*
(a real-time relay circuit, each node forwarding stream frames). It traverses the
*connected* mesh as a circuit, not DTN.

This live requirement is purely an artifact of **talking to the legacy TLS web.**
Between **Hop-aware endpoints** there's no such limit: session state lives only at the
two endpoints (nothing in between holds a socket that can expire), the handshake is
just async messages carried in bundles, and "established" means *keys valid + state
retained*, not *socket open*. Such a session can take minutes/hours/days to form and
persist indefinitely, the **X3DH + Double Ratchet** model (designed for establishing
E2E sessions with an *offline* party). Nice properties: pre-warm a session
asynchronously, then **0-RTT resume** the instant a live path appears; a live
*interactive* stream over it still needs the path live at that moment. Costs to handle:
ephemeral-key retention window (forward secrecy), prekey management, replay/clock-skew
over long spans.

### Mode selection (client decides; never silently downgrade)

The originating device chooses, locally, the gateway never decides, and the choice is
explicit because it changes the trust model:

| Request | Mode | TLS terminates at | MitM? | Path |
|---|---|---|---|---|
| `http://` | bundle fetch (gateway does HTTP) | n/a (plaintext) | n/a | store-and-forward |
| `https://` | CONNECT circuit | origin | no | must be live |
| `https://`, no live path | **queue & wait** for connectivity |, |, |, |
| `https://` + explicit "gateway-fetch OK" | bundle fetch | gateway | yes (opted in) | store-and-forward |

**Hard rule:** end-to-end is the default for TLS; the MitM path requires explicit
opt-in. Never opportunistically fall back from E2E to MitM because the circuit was
slow.

### The real fix: origin-side ingress (not a third-party gateway)

The MitM problem only exists when an **untrusted third party** terminates the
encryption. Move the termination **inside the origin's own trust boundary**, a Hop
ingress behind the server's firewall, run by the same party as the server, and it's
no longer a meaningful MitM (the origin always sees its own plaintext). Identical to
nginx/CDN/service-mesh sidecars terminating TLS in front of an origin today.

Such an ingress is **just a Hop node**: it has an address (= its pubkey), publishes a
service advert, and clients **seal directly to it**, the device-to-device model. That
yields, for free: no third-party MitM, **delay-tolerance** (sealed store-and-forward
bundles to a Hop address), discovery via gossip (no DNS), and long-lived X3DH/ratchet
sessions. Ship it as a **drop-in sidecar** (one binary, point at `localhost:8080`) so
adoption is a deployment step, not a rewrite.

### Adoption reality

Only **one quadrant requires service-provider adoption: delay-tolerant + no-MitM +
this-service.** It's logically forced, store-and-forward means *someone* holds the
message while disconnected; if that someone must be inside the trust boundary and
can't be the client's live TLS, it must be the provider's own node. The other
quadrants need no adoption: online + private is free via CONNECT (Tor-exit-like), and
delay-tolerant + don't-mind-gateway-reading uses the MitM shim. The untrusted egress
gateway stays in the design **only** as a compatibility shim for the legacy web you
don't control; origin-side ingress is the real answer for anything that wants to be
properly Hop-reachable.

### Decision: drop open-web fetch; `hops://` is origin-run gateways

We are **dropping the open-web HTTP fetch entirely** (no third-party gateway fetches
arbitrary `https://` on your behalf, that's the MitM, and the demo's "fetch via a
peer" feature is removed). The net is not something Hop bridges.

Instead, an app that wants to be reachable over Hop **runs its own gateway node**, and
clients reach it at **`hops://<domain>`**. That scheme:

- speaks ordinary HTTP **to the app**, but the transport underneath is the Hop network
  (sealed bundles / sessions), not TCP/TLS to a public IP;
- resolves to the operator's **Hop address** (its pubkey, via a service advert / a
  `hops`-record), and the request is **sealed to that gateway**, which is the
  destination/origin, so there is **no third party in the middle** (same trust model as
  hitting the origin's own HTTPS server);
- lands on the box running the **Hop gateway**, listening on a known, unreserved port, default **`9444`** (configurable; sits next to the path-A relay's `9443`).

So the `HttpRequest`/`HttpResponse` payloads stay, repurposed for this origin ingress
(client → `hops://domain` → that domain's gateway), not for fetching the open web.

## 26. Transports & portability, the bearer is the only thing that changes

> **Status: partly shipped.** The transport-agnostic seam exists today, and four
> bearers ride it on the phones, BLE (cross-platform), the cloud relay (TCP/WS),
> iOS MultipeerConnectivity, and the **LAN bearer (mDNS + TCP)**. Android Wi-Fi
> Direct was built and then **removed** (see the matrix below). Embedded/web ports
> remain roadmap. Tagline: *Hop, the network that finds a way.*

**The transport mechanism doesn't matter, by design.** `hop-core` knows nothing
about BLE. It is driven entirely through a tiny byte-frame contract, the same one
the `hop` crate's C ABI (`sdk/hop.h`) exposes:

- `connected(link, role)` / `disconnected(link)`, a transport says a link is up/down.
- `received(link, bytes)`, opaque frame arrived on a link.
- `drain_outgoing() -> [(link, bytes)]`, frames the transport must send.

**A bearer is anything that can move opaque, framed bytes between two endpoints and
say when a link is up.** Everything above that (Noise link encryption, bundles,
sealing, sessions, routing, discovery) is identical regardless of medium. So adding
a transport is writing a bearer, not touching the protocol.

### Transport matrix (role + honest constraints)

| Transport | Role | Notes |
|---|---|---|
| **BLE GATT + L2CAP** | full peer/relay | **implemented** (iOS + Android, incl. cross-platform); short range; iOS background-limited |
| **LAN (mDNS/Bonjour + TCP)** | full peer/relay | **implemented**, the cross-platform high-bandwidth path: same Wi-Fi → discover via mDNS (`_hoplan._tcp`, instance name = base58 address), link over plain TCP with the shared 4-byte length framing. Works iOS↔iOS, **iOS↔Android**, Android↔Android. Lower base58 dials, higher accepts (one link per pair) |
| **Wi-Fi MultipeerConnectivity / AWDL** | full peer/relay (iOS only) | **implemented** on iOS; Apple-only radio, so it never bridges to Android, that's what the LAN/BLE bearers are for |
| **Wi-Fi Direct (Wi-Fi P2P)** | ~~Android only~~ | **REMOVED** (commit c059d69). Its per-device pairing/approval dialog violates the passive, no-pairing principle that is a core selling point. Android↔Android with no shared network now falls back to BLE; the LAN bearer (mDNS + TCP) covers the shared-network case |
| **TCP / WebSocket** | peer↔gateway, backbone | phone↔gateway hop (a phone can't BLE-reach a cloud box, §25); cloud↔cloud backbone (§21) |
| **Web (browser)** | leaf / gateway client | WebRTC data channels (peer↔peer via signaling), WebSocket (→ gateway); WebBluetooth is central-only with no advertising/background. Browsers can't advertise or run in the background, so the web is a **leaf**, not a relay |
| **ESP32 (BLE + Wi-Fi)** | **always-on anchor / bridge** | the reliability unlock, see below |
| **LoRa / LoRaWAN** | long-range backhaul | km-range, tiny bandwidth, high latency, **DTN-native**; bundles were built for exactly this |

### ESP32 anchors, the reliability unlock

The hardest real problem (DESIGN.md §22) is that two backgrounded iOS apps can't
discover each other. The fix is **always-on anchor nodes**: cheap, mains-powered
devices that are permanently scanning/advertising, so any phone that wakes near one
can hand off and catch up. A $5-10 **ESP32 is the perfect anchor**, it has BLE *and*
Wi-Fi, so a single board is both a local BLE relay and a bridge to the internet/other
anchors.

Home Assistant does a *related* thing with **ESPHome `bluetooth_proxy`**: an ESP32
extends HA's BLE range by forwarding raw advertisements/GATT to HA over Wi-Fi, but
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
  but an ESP32 uses a small flash/RAM store, and a browser uses IndexedDB, no core
  change.
- **Work required for embedded:** make `hop-core` `no_std + alloc` (it's close;
  `rusqlite` is phone-only and already isolated behind `Store`), and provide
  per-platform bearer + store impls. The seams are in place; this is implementation,
  not redesign.

### Versus Amazon Sidewalk

Sidewalk is the closest mainstream analogue, a shared low-bandwidth network over
BLE + 900 MHz LoRa, carried by Amazon Echo/Ring devices. Hop targets the same
"ambient connectivity" idea but **open and operator-less**: it runs on any phone,
any ESP32, any app (the cross-app shared fabric, §17), with **end-to-end encryption
the carriers can't read** (§4) and **no central company** required to participate.
Sidewalk's reach is bounded by Amazon hardware ownership; Hop's reach is bounded only
by who installs a Hop-enabled app or plugs in a $5 board, which is how it could end
up *more* ubiquitous. The cost is that ubiquity is earned adoption-by-adoption rather
than shipped in a billion devices on day one (§17 adoption curve).

## 27. Provenance traces & learned routes, utility-prioritized epidemic

Epidemic flood + the delivery-ACK vaccine gets a message everywhere and dedups it at
the destination (§7, the `immune` set). That's robust, but blind flooding spends a
node's finite transmit time and storage on copies that will never matter to it. Each
node should instead spend that budget on the messages most likely to reach their
destination *through it*, and it can learn which those are from the traffic itself,
with no global topology and no coordinator. This section layers that utility on top of
the flood; it does not replace it.

### Every node has its own key, tables and storage are node-local

Identity is per node: the address *is* the keypair (§23). A node's **peer table**,
**learned routes**, and **bundle store** are all keyed to its own identity and are
**node-local**. Two nodes must never share an identity, that would merge their tables
and stores, which is exactly what we don't want, because prioritization depends on
*what this node has seen*.

- **Cloud relays are no exception: one key per region node**, not one key for the whole
  fleet. Region-specific storage and peer tables are the *point*, a region prioritizes
  by what it has observed, and the backbone is a mesh of distinct region nodes that
  flood between themselves (§21), each learning independently.
- Within a region, instances that share that region's identity + store partition act as
  one logical region node; **across** regions, identities differ.
- *Course-correction:* the current Cloud Run bootstrap shares one Secret Manager seed
  across all regions (a deploy shortcut). The target is **one identity per region**, so
  each region keeps its own store partition (`relays/{node}/bundles`) and peer/route
  table.

### Trace metadata, provenance recorded on every hop

Each bundle carries a **trace**: an ordered list of **short hop addresses** (the same
truncated-pubkey short form the UI shows). On forward, a node appends its own short
address before handing the bundle off. The delivery ACK carries *its own* trace back
along whatever path it travels.

The trace is **authenticated header metadata, not sealed payload**, forwarders must be
able to read it to use it. That exposes the path to relays (privacy tradeoff below);
the payload itself stays sealed end-to-end (§4).

### Learning routes from ACK/trace correlation

When a node forwards a send and later sees the **delivered-ACK for the same bundle pass
through it**, and the ACK's trace **overlaps the send's trace at this node**, the node
has learned it sits on a *working path between src and dst, in both directions*, even
if it never directly encountered either endpoint.

- It records a **route**: `(src ↔ dst) → preferred neighbor(s)`, with a recency-decayed
  confidence (same half-life discipline as §18/§21, so stale routes fade).
- Over time the node accumulates a routing table learned **purely from observed
  deliveries**. **Peer-of-peer reach** falls out of this for free: a node can prioritize
  toward a dst it can reach via a known peer two hops away, not only dsts it has met.

### Utility-prioritized epidemic (flood, but order and retain by utility)

Still epidemic: a node offers a bundle to every neighbor while hop-limit remains, and
the destination dedups, *we don't care how many copies exist*. What changes is **order
and retention**:

- **Transmit order:** messages whose dst the node has a relationship/route to go first, `direct encounter > learned route > peer-of-peer > unknown`. This matters most during
  short BLE contacts where only a few bundles will fit.
- **Retention / eviction:** under store pressure, keep high-utility bundles and evict
  toward-unknown-destination ones first. *A cloud peer that has never seen the receiver
  deprioritizes that message* (lower transmit priority, first to evict) rather than
  dropping it outright.

This is the message-level analogue of §18: §18 ranks **topics** by demand/supply; §27
ranks **individual bundles** by learned route quality to their destination.

### Tiered tables, cloud nodes are the long memory

Table and store capacity scale with the node tier:

- **Mobile nodes** keep small, recent, high-utility tables (limited RAM/storage, evict
  aggressively), they forget routes quickly.
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
§19's mailbox-sees-`(AppId, dst)`, payloads (§4) are unaffected.

**The per-hop app id is the sensitive part, gate it.** The node address in a hop is
already public (it's the address, broadcast via presence, §23), so it's no new exposure.
But the **carrier app id** would advertise *which app a device runs* to everyone on the
path, a real app/social-graph leak. So **only public infra nodes stamp a real app id**
(a relay stamps [`relay_app_id`] → "Hop Relay"); **end-user devices stay on `FABRIC_APP`**
(shown as "device") and never reveal their app. The route layer keys on node addresses,
not the app field, so this costs nothing functionally. The FFI exposes no app-setter, so
a device *can't* leak its app even by mistake; the relay daemon sets it explicitly.

### Status

Design only. Building blocks exist: epidemic + vaccine (`routing`/`node`), §18
reliability-weighted relay, §21 `RegionRouter`. To build: a **trace** field on the
bundle header; ACK/trace correlation → a per-node **route table** with decay;
utility-ranked transmit/evict ordering; tier-aware table sizing; and **per-region relay
identities** (replacing the single shared Cloud Run seed).

## 28. Demand-summoned cloud nodes, the backbone exists only while devices hold it up

Cloud nodes are **scale-to-zero**: a region node exists only while at least one end-user
device holds a connection to it. No device in a region ⇒ that region's node winks out and
costs nothing. This **refines the "always-on" language of §19/§21**: the backbone is not a
permanently-running fleet, it is an **emergent, demand-driven mesh** that lights up under
traffic and goes dark when idle. *Only end-user devices bring cloud nodes online.*

- **A device summons its nearest region node** (the entrance, §21) and that node holds the
  device's relayed bundles in its **region-local durable store** (the per-region partition,
  §27, `relays/{node}/bundles`). Compute is ephemeral; the **mailbox is persistent**: when
  the region node scales to zero and later wakes for the next device, it reloads its
  partition and resumes. The durable store is what makes ephemeral compute safe.

- **The mesh forms dynamically as regions light up, but nodes never wake each other.** A
  cloud node comes online *only* when an **authenticated** client in its region connects
  (client traffic is what wakes Cloud Run; that is the **only** wake trigger, and §35 tightens
  it to *keyed* client traffic, so an unauthenticated connection is rejected at the edge and
  cannot wake a region). When a node wakes, it announces itself
  to the liveness registry and **reaches out to the peers already marked online**, pulling in
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

### Relays are big devices, per-region local spools + online-only epidemic

The cross-region story is just the **DTN epidemic model applied to relays**: a relay is a
*big, always-reachable-while-its-devices-are-awake* device. It has its **own local durable
spool** and it **syncs with whatever peer relays are online right now**, exactly as two
devices that pass each other exchange what they're carrying, neither knows when they'll next
meet, and because it's delay-tolerant, the timing doesn't have to line up.

- **Per-region local store.** Each region's relay owns a **regional Firestore database in its
  own region**, its private spool that survives scale-to-zero. No region is second-class:
  asia/australia/south-america relays read+write *locally*, not across an ocean to a US
  database. (Regional Firestore is cheaper than multi-region, and at storage+traffic pricing
  the per-region volume is negligible.) Firestore here is a **local disk**, not a shared
  cross-region rendezvous, there is no single global DB to be latent or US-centric (§33).

- **Online-only relay-to-relay epidemic.** When a relay comes online (woken by *its own*
  devices checking in, the only wake trigger) it **announces presence**, and other
  **already-online** relays push their bound-its-way bundles to it over a Noise link, the
  same `offer_bundles` epidemic devices use. A relay only ever connects to peers **currently
  announcing presence**; it **never dials a sleeping region** (that would cold-start it through
  the LB). So "a node is woken only by its own clients" still holds, dormant regions stay
  dark and cost nothing until *their* devices wake them, then the backlog flushes.

- **Delivery = replication + check-in overlap.** A message reaches device B when *some* relay
  holding it is online while B's region is awake. Multi-hop epidemic spread across relays makes
  that likely without anyone holding a connection to everyone; devices checking in periodically
  (§22) provide the wake windows. Non-overlapping windows resolve over time as the message
  replicates, no simultaneity required, the whole point of a DTN backbone.

This **supersedes the earlier "Firestore cross-partition handoff is the *only* path, relays
never dial" decision.** That decision was right to kill **dialing *sleeping* relays**, the
original 429 fire came from pull-on-wake cold-starting regions through the LB and heartbeat-TTL
churn relighting the fleet. The fix is *online-only* dialing, not *no* dialing. The presence/
liveness registry stays (a passive read tells an online peer from a sleeping one); the
device→region presence index (`presence/{device}`) remains useful to **route epidemic spread
toward** a destination's region rather than flood blindly.

### The one constraint: bounded fan-out

"Online relays sync with each other" taken as a **full mesh** is the *other* half of the old
429: N online regions → N² persistent peer links, each `maxScale=1` instance holding (N−1)
peer connections *plus* its device connections, saturating the instance and 429'ing real
check-ins. So the mesh is **partial**:

- Each relay keeps a **small fan-out**, a handful of online peers (gossip / SWIM-style
  membership), not every peer. Multi-hop epidemic carries messages the rest of the way.
- **Replication, not reach:** a few hops of spread beat one giant mesh for delivery
  probability, at a fraction of the connection load.
- Raising `maxScale` (post quota-increase) gives instances headroom to shed peer-link load,
  but bounded fan-out is the real lever.

Both user messages (`Device`) and delivery-ACKs (`AckTo`) ride the epidemic, so a confirmation
travels back to an offline cross-region sender the same way. All blocking Firestore I/O (the
local spool) runs on dedicated worker threads; the driver loop stays single-owner.

### Backbone addressing, region-specific domains, separate from the relay identity

Three different "addresses" are in play and must not be conflated:

- The **relay identity** is its pubkey (§23), used for Noise link auth and as the
  store/table key (§27). It is **not** a network locator; you can't dial a pubkey.
- The **client entrance** is the single anycast name `relay.hopme.sh` (§21), it routes a
  *device* to the *nearest* region. A region node **can't** use it to reach a *specific*
  peer region: anycast would just send it back to the nearest entrance (possibly itself).
- Each region still gets a **per-region domain** `us-central1.relay.hopme.sh` (one wildcard
  cert, host-routed to that region; §ops). It is the region's stable public name, what
  `hop.identify` returns for that relay (§29) and a region-specific entrance, but, per the
  decision above, it is **not** used for node-to-node dialing.

This is the **internal discovery plane**, separate from the client-facing anycast name and
the pubkey identity. The hard rule: **a node is woken only by its own clients; nodes never
wake nodes.** So discovery must be *passive*, reading it cannot cause a wake:

- **Passive liveness registry.** Online nodes heartbeat into a shared store (a well-known
  Firestore doc/collection) with a short TTL; on scale-to-zero the heartbeat stops and the
  entry expires. **Reading the registry is just a Firestore read, it wakes no one**, and a
  sleeping node simply isn't listed. The registry is now used only for *observability* and to
  tell a peer relay from a device, not for dialing.
- **No peer dialing.** A node never connects out to a peer (that would wake it). Cross-region
  traffic is moved by the **cross-partition handoff** (a Firestore write into the destination
  region's partition), so a region's only inbound connections are from its own clients.
- **Never connect to an absent node.** Connections only ever target registry-live endpoints,
  so a node→node connection can't be what wakes a region. Clients are the sole wake source.
- **Offline destination ⇒ no connection at all.** For the cross-partition handoff (§28) you
  don't dial the destination region, you **write the sealed bundle into its durable
  partition** (a Firestore write, which does **not** wake it), and it's delivered whenever a
  client next wakes that region.

**Infra implication:** the core need is a **passive liveness registry** (a well-known
Firestore doc nodes heartbeat into) plus the per-region durable partitions (§27). The per-region
domains `<region>.relay.hopme.sh` exist as stable public names (the relay's `hop.identify` name,
§29) and region-specific entrances, not as peer-dial targets (no node-to-node links). Crucially,
**never probe/health-check region endpoints** to infer liveness (that would wake them), liveness
comes only from registry heartbeats.

### Device check-in (mailbox pull)

Sending a message wakes a relay (the client's connection summons the region's node,
§28). **Receiving** needs the reverse: a device must **check in** to discover messages
waiting for it. The delivery itself is already automatic, on link-up a relay *offers*
its stored bundles and anything addressed to the device is delivered (then ACK-purged), so check-in is purely **"connect so the offer happens."**

How a region gets a bundle in the first place:

- **The backbone** never pulls between relays (no node-to-node links; see above). A bundle
  for another region is placed there by the **cross-partition handoff**, a Firestore write
  into that region's partition, which the region drains on its own next check-in.
- **A device** only ever connects to the **single anycast name `relay.hopme.sh`**, which
  resolves to its **closest topographical node** and **wakes that node** as it connects.
  The device never talks to the backbone directly; it trusts the backbone to have moved
  any message destined for it into the node it lands on (cross-partition handoff / region
  routing, §28). One address, nearest node, no fan-out.

So the client keeps a connection to `relay.hopme.sh` (reconnecting on drop / on
foreground / on background-wake), which continuously checks in: it wakes the nearest
node and receives whatever is pending. Persistent connection = real-time receive +
keeps that one node warm; periodic reconnect (the delay-tolerant mode) lets the node
scale to zero between check-ins at the cost of receive latency. The device's existing
background wakes (beacon region entry, BG fetch) double as periodic check-in triggers.

## 29. Services & commands, calling a node

Beyond fire-and-forget messages, a node can **call a service** on any address: a
request/response over the bundle layer, sealed end-to-end like everything else. A
`ServiceRequest { service, method, args }` is addressed to a node; the reply comes back as
a `ServiceResponse { for_bundle_id, status, body }` correlated by the request's id (the
same shape as the HTTP-egress pair, §9, but device-to-device).

- **Built-in services** are namespaced under `hop.` and answered by the **node itself**, they never surface to the app. The first is **`hop.identify`**: call it on any address to
  get an `IdentityRecord { name, kind, address }`. `name` is `None` by default for a device
  (so a caller falls back to the short address), a user can set it, and a **relay reports
  its region domain** (`us-central1.relay.hopme.sh`). `kind` is device / relay / gateway.
- **Custom services** (any non-`hop.` name) are **dispatched to the embedding app**, which
  fulfills them and seals a response back. This is the "call a device with a command"
  primitive, an app registers whatever services it wants on top.

**Forward secrecy: services are sealed, not ratcheted, by design.** A `ServiceRequest` /
`ServiceResponse` (and the `hops://` HTTP-over-mesh pair built on them, §30) is **statically
sealed** to the destination key (ephemeral-static ECDH, §4), the same bundle class as the
HNS/HTTP-egress traffic, and deliberately does **not** go through the per-peer Double Ratchet
that user messages use. This is a considered decision, not an oversight:

- **Services are addressed RPC, usually first-contact and one-shot.** A `hops://` request to an
  endpoint you have never messaged, or a `hop.identify` to a fresh address, has **no session and
  no reason to build one**: a ratchet needs a prekey exchange and stateful continuity that a
  single request/response to an arbitrary address does not have. Forcing a session would add
  round-trips and state to a fundamentally stateless call.
- **The forward-secrecy law is about user CONTENT, not RPC.** The repo law "device-to-device
  content is always forward-secret" (see `CLAUDE.md` / §25) scopes to **`PeerMessage` user
  content**, which is exactly the traffic that carries private conversation and is always
  ratcheted or deferred, never static-sealed. Services are a separate class, like adverts,
  HNS answers, vaccines, and egress requests, all sealed end-to-end but not ratcheted.
- **Consequence, stated plainly.** An adversary who records a node's service traffic and *later*
  compromises the recipient's identity key can decrypt those past service payloads (no
  recipient-compromise forward secrecy for the RPC class). An app that needs to move sensitive
  device-to-device data with forward secrecy should carry it as **messaging content**
  (`PeerMessage`, ratcheted), not as a custom service. `hops://` and `hop.identify` payloads are
  request metadata / public-directory data where this trade is acceptable.

**Why identify matters for traces (§27).** A trace records each hop as an 8-byte short
address, compact, and not reversible to a full address. The app resolves a hop to a
**display name** by indexing the full addresses it already knows (peers, contacts, the
relay it's connected to) by their short form and matching; `hop.identify` is how it learns
the name for an address (and a relay's domain). Unresolved hops fall back to the short id, so a trace reads `you → us-central1.relay.hopme.sh → Bob` instead of opaque hex.

## 30. Protocol layering, `hdp`, `hops`, and HNS

Hop is now framed as three named layers, lowest to highest.

### `hdp://`, the Hop Datagram Protocol (the substrate)

`hdp` is Hop's UDP: a connectionless, sealed, addressed **datagram** (a bundle) that is
store-and-forwarded across the mesh. **All Hop traffic rides on `hdp`**, messages,
service calls, ACKs, adverts, name lookups, and `hops` requests/responses are all bundles.

A datagram differs from UDP in two directions:
- *Below* UDP: it's **store-and-forward** (held when there's no onward path, not dropped)
  and **sealed + signed** (UDP is naked).
- *Above* UDP: TCP's two useful guarantees are rebuilt **at the endpoints**, where they
  need no live circuit, **reliable delivery** (`request_ack` + retransmit + epidemic
  spray, collapsed by the delivery-ACK vaccine) and **in-order large transfers** (carrier
  transport, §31). State lives only at the two endpoints, so nothing in the middle holds a
  timer that can expire. That's why `hdp` is delay-tolerant where TCP/TLS can't be.

Addressing: `hdp://<hop-address>` (a base58 pubkey) or `hdp://<domain>` (resolved to an
address via HNS).

### `hops://`, HTTP over `hdp` (origin-run, no MitM)

`hops` is Hop's HTTP: the **same request/response semantics** as HTTP, carried as `hdp`
datagrams (`Payload::HttpRequest` / `HttpResponse`), sealed to the destination. It requires
a new operator-run component, the **`hop-endpoint`**, which runs on the service's own
infrastructure and does the `hops → http/https` translation: it receives a `hops` request,
**executes it against its own backend** (localhost / its LAN), and returns the response
back through the mesh to the client.

Because the endpoint terminates HTTP for **its own** service (it *is* the origin, like an
nginx sidecar), there is **no man-in-the-middle**, unlike a third-party fetch gateway,
which is why open-web fetch was dropped (§25). The only "live" hop is endpoint↔backend, on
the operator's own wire; the client↔endpoint path stays fully delay-tolerant.

**An endpoint is bound to its own domain, never an open proxy.** `hops://google.com/x`
can resolve *only* to `https://google.com/x`, and only because `google.com` served a signed
reach record at `https://google.com/.well-known/hop` pointing at its endpoint. The request carries just a
**path**; the endpoint prepends its *own* configured origin and refuses any other host, so
there's no open-relay abuse and no laundering arbitrary web traffic through someone else's
endpoint. You reach a domain's content only through that domain's own endpoint.

**Domain binding is enforced at the protocol level, not by convention.** Every `hops`
request carries a signed `host` field inside the sealed bundle (`Payload::HttpRequest.host`).
The endpoint is configured with exactly one authorized `--domain` and **rejects any request
whose `host` ≠ that domain with a 403, before it ever touches the backend**. The URL it
fetches is built *solely* from its configured `--origin` plus the request path, the
request's own bytes never choose a host, and HTTP redirects are disabled, so the backend
can't bounce it off-origin either. There is no code path by which a `hop-endpoint` process
fetches anything other than `<origin><path>`. An attacker who forges a different `host`
simply gets a 403; an attacker who tampers with the signed bundle breaks the seal.

**Direct-address form bypasses HNS.** A client that already knows an endpoint's address can
speak straight to it, `send_hops_request(<address>, host, …)` (or `hdp://<address>`), with
no name lookup at all. HNS is only the *discovery* step that turns a domain into that
address; once you have the address, resolution is skipped entirely.

Response sizes map onto §31:
- **Finite** response (Content-Length) → rides the **carrier transport** (auto-chunked,
  reassembled into one response). Free.
- **Live / open-ended** response (SSE, chunked, WebSocket, progressive media) → rides an
  **application stream** (`StreamOpen`/`StreamData`/`StreamAck`/`StreamClose`): the endpoint
  holds the live upstream and relays numbered chunks the client reassembles in order and
  **catches up on after a gap**. The upstream's liveness is confined to the operator side.

### HNS, the Hop Name System

Name→address resolution, **built into hop-core**, anchored on the domain's own TLS certificate
plus a self-certifying **reach record** (`reach.rs`). A domain owner serves a signed reach record
at `https://{domain}/.well-known/hop`: the record binds the domain's Hop **address** (pubkey) to an
endpoint and is Ed25519-signed **by that very address**. To reach `hops://example.com`, a client
fetches `https://example.com/.well-known/hop`, then speaks `hdp` to the address it certifies.

**Two independent proofs.** The bind is trustworthy because of two orthogonal checks:

- **WebPKI proves the domain.** The HTTPS fetch's TLS certificate proves the responder really is
  `example.com` (the same trust every browser already relies on). Serving the well-known requires
  control of the domain.
- **The reach record self-certifies the address.** The record's signature is by the *claimed*
  address itself (`sign(id, {address, endpoint, issued_at, ttl})`), so a tampered endpoint or a
  substituted address simply fails the signature check. No external anchor, no root key is
  consulted.

Together: TLS says "this really is example.com's server," and the reach record says "example.com's
operator holds the private key for this Hop address." A forged binding fails one check or the other.

**The fetch is the host's job; the trust decision is core's.** Core hands the host a domain to
resolve (`take_dns_lookups`); the host does **one HTTPS GET** of the well-known and hands core the
raw record bytes (`provide_reach_record`); core verifies the self-certifying signature + expiry and
caches `domain→address` for the record's TTL. The host's only parsing is pulling the base64 `reach`
field out of the `{address, endpoint, reach}` JSON body, no validation logic lives in the host.

**Resolution needs the resolving device's own internet.** Because the domain proof *is* the TLS
handshake, only a node that can itself reach `https://{domain}` can resolve a name. There is
deliberately **no mesh-assisted or relayed resolution**: relaying the lookup would either force the
client to trust the resolver or re-introduce a proof chain for the client to validate, the exact
complexity this design removes. An internet-connected device resolves names directly; a radio-only (e.g. BLE-only)
device cannot resolve a name and must be handed the address directly, `send_hops_request(<address>,
…)` / `hdp://<address>`, which is itself self-certifying. Once resolved, the cached address makes
delivery fully delay-tolerant again.

**Missing / unreachable is a first-class negative.** A well-known that 404s, fails TLS, or serves a
bad or expired record resolves to a **negative** answer cached briefly (surfaced as "no such hops
endpoint" / "offline" rather than a hang). The offline case (no internet, so the fetch can't even be
attempted) is surfaced distinctly so the UI can say "connect to the internet to resolve names."

**Why name→address is self-certifying.** An earlier design instead flooded a public `HnsQuery` across
the mesh and carried a full signed proof chain back in an `HnsAnswer` for the client to validate
in-core against a baked-in root anchor. It resolved trustlessly over multiple hops, but it required
every publisher to run a signed zone, embedded a chain validator + DoH JSON parser in core, and
carried a subtle owner-in-signer forgery class (caught in the pass-5 audit). The reach record
collapses name→address onto the **same self-certifying primitive already used for endpoint
discovery**: the address signs its own binding, so there is no chain to validate and no external
anchor at all. The cost is that resolution is no longer mesh-assisted, it needs the resolving
device's own internet, which matches how a `hops://` endpoint is reached in the first place.

**No HNS wire types.** Resolution is an out-of-band HTTPS fetch, not a mesh bundle exchange, so HNS
adds nothing to the wire kind registry. The old `HnsQuery` / `HnsAnswer` payloads and the
point-to-point `resolve_hns_via` are removed.

## 31. Reliable, ordered, delay-tolerant delivery on `hdp`

Everything below is built on plain datagrams; none of it requires a live end-to-end path.

- **Epidemic spray + ACK-vaccine (§6/§7).** A bundle is replicated to new peers as they're
  met (spray-and-wait, bounded by copy budget + hop limit + lifetime). The destination's
  delivery-ACK travels back as an **anti-packet/vaccine**: every node it passes drops its
  copy and refuses future ones (`immune`), collapsing the flood. Reliability = redundant
  persistent replication that an acknowledgment later cancels.
- **Reliable ACKs over long hops (§7).** Delivery-ACKs are first-class: **re-emitted on a
  duplicate** (throttled) so a lost ACK self-heals; **replicated to N peers then settled**
  (`ACK_REPLICATION_TARGET`); **lifetime-matched** to the message (capped 7 d) and ridden a
  priority notch above bulk traffic; **route-biased** toward a hot return path via learned
  routes (§27) without sacrificing redundancy.
- **Custody / forward-before-evict (§6).** A node won't drop a relayed bundle it hasn't
  handed to ≥1 peer if anything else can be freed, and keeps it ~3 min after forwarding for
  opportunistic re-handoff. This stops a flood of big transfers from evicting legitimate
  not-yet-relayed messages, and turns a node's custody cap into a **sliding window** of
  concurrent in-flight bundles rather than a limit on transfer size. Cloud relays run a
  large window (`set_max_relayed`).
- **Carrier transport (§20).** A bundle too large for one link record is transparently
  split into ordered `Payload::Carrier` chunks (each a sealed, ACK-tracked datagram) and
  reassembled into the original bundle at the destination, preserving id, request_ack,
  delivery status, and dedup. So a 5 MB image "message" just works; the cap is a sliding
  window, so even video streams through.
- **Application streams (§20).** For genuinely open-ended data, `StreamData` chunks are
  delivered to the app **progressively** (in order, deduped, gap-buffered, resumable after
  the receiver was offline), distinct from carrier transport, which reassembles into one
  bundle.
- **DTN-scale timing.** Default bundle lifetime is **24 h** (settable longer), and
  retransmission **backs off exponentially** (30 s → … → 15 min cap) so a long-lived bundle
  costs a handful of retries, not thousands. A message persists and keeps seeking the
  destination across contacts for its whole lifetime.

## 32. `hps://`, Hop Pub/Sub: services & channels

`hps://` (Hop Pub/Sub) is a protocol **distinct from `hops://`**. `hops://` is request/response
(a client fetches from one origin); `hps://` is **publish/subscribe**, a writer broadcasts to
many subscribers it doesn't enumerate. Both ride `hdp` and both resolve hosts via HNS.

### Registration & addressing

**Any node**, phone, endpoint, relay, can **register a service or channel at a path** and
becomes its host. On registration the node generates the relevant keys and **persists them in
its store** (so they survive restarts); one node may host many, one per path.

A topic is addressed `hps://{address|host}/{name}`, `{name}` is the path under the host node's
address (`{host}` resolved via HNS). A request to a path that **isn't registered returns an
error**, paths are explicit, never implicit.

### Two modes

**Channel, anyone reads, anyone writes** (group chat). Confidentiality is a **symmetric
content key** shared by members; any member encrypts/decrypts with it. Every post is **signed
by the writer's own device identity**, so readers always see a *verified* sender even though
the read/write key is shared.

**Service, only the owner broadcasts, many read.** Confidentiality is again a **symmetric
content key** handed to subscribers (so they can read); write-restriction is a **service
signing keypair**, the host signs each broadcast with its private key and subscribers verify
with its public key. So only the host can produce a valid broadcast *even if the read key
leaks*. (Confidentiality and authenticity are deliberately separate concerns: a single keypair
can't enforce both "only subscribers read" and "only the owner writes".)

### Authenticity is always a per-message signature

Independent of the shared content key, **every `hps://` message is signed by its sender**, the
service's key for a broadcast, the member's own identity for a channel post. The content key is
*confidentiality only*; the signature is *authenticity*. A leaked content key lets someone
**read**, but they still can't forge a service broadcast (no service signing key) nor
impersonate another member (signatures are per-identity).

### Subscribe / join, and access modes

Subscribing is an `hps://{host}/{name}` request; on success the host hands back the keys
(content key, plus the service's public verify key for a service). **Who gets the keys** is the
access mode:

- **Open**, keys handed out on subscribe; no member list; membership stays anonymous (the
  host learns a member's address only when they ACK a message, see reach).
- **Request-to-join**, the requester asks; the host **approves** before handing off keys.
- **Invite**, the host **initiates** an invite to a destination; the destination accepts,
  then receives the keys.

**Implemented:** all three modes, plus per-topic **visibility** (Private vs Discoverable),
reach tallying, and selective-rotation revocation. Open hands keys on a join request;
RequestToJoin queues for host approval; Invite is host→destination→accept (consent-based).

### App-secret isolation (DESIGN.md §17)

A topic must not be discoverable or joinable across **different apps**. The 16-byte `AppId`
is only a public *fingerprint* (`blake3(app_secret)`), it travels in headers and proves
nothing, so it's used for demux/filtering, never authorization. Real isolation comes from
key material derived from a host-supplied 32-byte **app secret**:

- **Discovery** adverts (`AdvertKind::HpsTopic`) carry the topic descriptor **encrypted** under
  a per-app key (`disc_key`), so a foreign app can relay but never *enumerate* topics.
- **Join / invite / accept** handshakes carry a keyed-MAC **proof** (`mac_key`) the host verifies
  before any key handoff, a different-secret app can't join even knowing the address+path.
- `ingest` still **relays** foreign-app adverts (the fabric is shared) but never surfaces them.
- Two developers who share the app secret interoperate; otherwise their topics are mutually
  invisible and unjoinable.

**The one intentional public surface:** a broadcast's *envelope* is sealed to a well-known key
(`broadcast_identity`) so any node can carry it, so the wire form exposes an opaque per-topic
`topic_tag` (keyed hash of the path) and the epoch, never the path or content. The content key
and per-message signature keep the body confidential and authentic; the topic identity stays
app-private via the tag.

### Publish, delivery, and reach

A published message is encrypted with the content key and **floods the mesh** (epidemic, like
any `hdp` bundle); non-members carry it but can't read it. Each member that decrypts **ACKs
back to the host**, and the host tallies **unique acking addresses** as its delivery count /
sense of reach, **no subscriber registry required** (for open mode).

On a subscriber, a verified publication is staged in a durable app inbox and repeats on poll until
the app explicitly accepts it. The inbox holds at most 256 publications. An unaccepted row expires
with the publication's receiver-anchored lifetime, clamped to seven days; acceptance removes the
payload row but retains its bounded replay identifier until that same deadline. Replay state is capped
at 1,024 identifiers per topic generation and 4,096 across the node.

### Revocation (current limit + future)

**Implemented as selective forward rotation:** the host mints a fresh content key (and, for a
service, a fresh signing key), bumps the topic **epoch**, re-keys every retained member except
those being removed (via a sealed `HpsRekey`), tombstones the old discovery advert, and
re-advertises. A removed member is simply never handed the new key, and broadcasts at the new
epoch supersede older ones. The remaining limit is that rotation is **forward-only**, a removed
member keeps whatever it could already read (keys aren't retroactively secret).

### Relationship to the rest of the stack

- `hdp`, the datagram substrate everything rides.
- `hops://`, request/response to a domain's own endpoint (HNS-resolved via the domain's TLS-served reach record, §30).
- `hps://`, pub/sub services & channels at paths on any node (this section).
- HNS resolves a `{host}` to an address for any of them; the `hps://`/`hops://` grammar and the
  signature/key handling live in core, not the hosts.

## 33. Data protection & GDPR, what the durable store holds and where

> Engineering-compliance map, not legal advice. The point is to be honest about what
> personal data the backbone persists, where it physically lives, and which knobs move it.

The only place Hop persists user-derived data at rest is the **durable Firestore store** (§27/§28).
Everything else is ephemeral compute or on-device. Three things land there, and they are **not**
equal under GDPR:

- **Sealed bundles** (`relays/{node}/bundles`), **ciphertext**. Relays carry the payload
  end-to-end encrypted and **never hold keys**, so message *content* is opaque to the store. But
  the bundle header carries **source + destination public keys, timestamps, size, and app/topic
  labels**. A persistent pseudonymous identifier tied to an individual is personal data (GDPR
  Recital 26 / *Breyer*), so the **metadata** is in scope even though the content is not.
- **Presence index** (`presence/{device}` = region + heartbeat, §28), the sharp one. It maps a
  pseudonymous device address to a coarse **location + activity timeline**. Movement/timing
  metadata over time is the most sensitive dataset in the system.
- **Delivery ACKs** (`AckTo`), same metadata character as bundles.

### What the design already gets right (data protection by design, Art. 25)

- **End-to-end encryption, relays hold no keys.** Content exposure at rest is essentially nil, a
  strong Art. 32 safeguard and the core of any transfer-risk argument.
- **No central identity/name registry (§23).** Addresses are pseudonymous public keys with no
  account mapping. Pseudonymization and data minimization by construction.
- **TTL eviction** on bundles (`infra/firestore.tf`) and heartbeat staleness on presence, storage limitation (Art. 5(1)(e)) is built in, not bolted on.

### The actual exposures

1. **International transfer (Chapter V).** The durable store is a **single Firestore database in
   one location**, default `nam5`, a **US** multi-region (`infra/bootstrap/variables.tf`). Every region's
   partition (including EU nodes') is just a collection in that one US database, so EU users'
   personal data (addresses, presence, metadata) is **transferred to and stored in the US**. Post
   *Schrems II* that needs a mechanism: the **EU-US Data Privacy Framework** (Google Cloud is
   DPF-certified) or **SCCs + a transfer impact assessment**. The mechanism exists and must be
   actively relied on and documented, US storage is not automatically unlawful, but it is the
   first thing a regulator asks about.
2. **Presence is location data.** Coarse region + timestamps per address is the highest-risk set.
   Minimize it: shortest viable retention, coarsest viable granularity, and prefer in-memory on a
   warm node over persistence where delivery allows.
3. **Erasure is awkward, by design.** With no address→person map, enumerating "all of one
   person's data" for an Art. 15/17 request is hard. Pseudonymity aids minimization but
   complicates rights fulfilment unless a subject proves they hold an address (then
   deletion-by-address is feasible).

### Globality & replication of the store (precise)

The Firestore database is **globally reachable and strongly consistent, but US-centric in latency
and residency**:

- **Consistency:** one logical DB, any relay anywhere sees a consistent view; no cross-region
  eventual-consistency races.
- **Replication:** within the multi-region only. `nam5` synchronously replicates across several
  **US** regions (survives a US-region outage); it does **not** replicate to Europe.
- **Locality: none.** A non-US relay's "region-local durable store" (the §28 phrasing is logical,
  keyed by node) is **physically in the US**. So an EU relay's reads/writes are trans-Atlantic
  (~80-100 ms each) and all data sits under **US residency**. For a delay-tolerant backbone the
  handoff cadence (tens of seconds, §28) dwarfs that RTT, so it's a residency question, not a
  performance one.

### The levers (ranked)

- **Near term (cheapest):** rely on Google's DPF certification / SCCs, write the transfer-impact
  assessment, and lean on the E2E-encryption + pseudonymity posture. Standard, defensible for
  EU-serving infra on GCP.
- **Tighten the sensitive set:** shrink presence retention/granularity; keep bundle/ACK TTLs as
  short as delivery allows.
- **EU data residency (largely free under the per-region model, §28):** the chosen model gives
  **each region its own local regional store**, so EU relays already keep their spool **in the EU**
  and asia/etc. keep theirs locally, residency falls out of locality, no single US-centric DB to
  split. The relay-to-relay epidemic does move ciphertext across regions, but it's **sealed
  payload** the relay can't read (§32), and a hard mandate can constrain *which* peer regions a
  given region syncs to. The remaining lever is the **declared home** (§34): residency is a
  property of the person, so a mandate pins a device's region to its declared store and bounds
  where its bundles may replicate. (The old "single global `nam5` + per-continent split" framing
  is superseded by per-region local spools.)

## 34. Device inboxes, recipient-keyed mailboxes with locality migration

> **Status: largely superseded by §28's per-region local spools + online-only relay-to-relay
> epidemic.** This section worked out a *recipient-keyed inbox* with a **continental home store**
> that **migrates** toward sustained access (the Gmail/Spanner model). The chosen model instead
> gives **each region its own local spool** and lets relays **epidemic-sync** what they carry, so
> a device's messages live in whatever relays carry them (replicated), not in one pinned "home
> inbox DB," and there is no cross-continent migration to run. Two ideas here still carry over:
> (1) indexing a spool's held bundles **by destination** (so a relay knows what to push toward a
> peer region), and (2) the **residency pin** below, a *declared* home overriding placement for a
> hard localization mandate. The rest (continental placement, affinity migration) is retained only
> as the record of an alternative we did not take.

### The unit: a per-device inbox with a home store

- The authoritative durable layer is an **inbox keyed by recipient address**, `inbox/{device}/bundles/{id}`, **not** a relay-node partition. *Every* `Device(X)`-addressed
  bundle that can't be delivered live lands in `inbox/{X}`: user messages, **delivery-ACKs**
  (`AckTo`), service responses, and the `hps://` key handoffs (`HpsKeys`) alike. One mailbox per
  device for all unicast traffic.
- An inbox has a **home store**. Placement granularity is the **continental Firestore database**
  (§32/§33): a multi-region DB (`nam5`, `eur3`) is one logical store, so there is no placement
  *within* a continent, "the region a device connects to" maps to **that region's continental
  DB**. Migration is therefore meaningful at the **cross-continent** grain (move `nam5`→`eur3`),
  which is exactly where latency and residency bite.
- A tiny **locator** `inbox-home/{device} = { store, region, updatedAt }` says where the inbox
  lives. A pure read that wakes no one, it **subsumes the §28 presence index** (it now records a
  *home*, maintained by migration, not just a last-seen region).

### Relays write directly to inboxes

A relay holding an undeliverable `Device(X)` bundle reads `inbox-home/{X}`:

- **Locator exists** → write the sealed bytes into `inbox/{X}/bundles/{id}` in that store. It
  never opens the bundle (ciphertext verbatim); writes are deduped by bundle id.
- **No locator (no inbox anywhere yet)** → **sender-side implicit creation**: the sending relay
  creates `inbox/{X}` in **its own store** and writes the locator pointing there. The inbox is
  born nearest whoever first needed it and **gravitates to X** once X starts checking in. So a
  message to a never-seen recipient is never dropped, it waits in the sender's region until the
  recipient appears and pulls (and eventually until the inbox migrates to them).

### Devices check their inbox on connection

On link-up, the relay X lands on reads `inbox-home/{X}`:

- **Home is this store** → drain `inbox/{X}`, offer to X on its link, ACK-purge on delivery.
- **Home is another continent** → drain it **cross-store** (works; pays one continental RTT) and
  **bump X's affinity** for this store, sustained checking-in here is what pulls the inbox over.
- **No locator** → nothing waiting.

Receiving is still just "connect so the offer happens" (§28 device check-in), only the *source*
of the offered bundles changes from a relay partition to the device's own inbox.

### Migration, locality gravity, damped

Each inbox carries a **recency-decayed affinity** per store, fed by where X actually checks in.
When a non-home store **dominates the home by a margin `M` over a window `W`** (hysteresis, so a
two-week trip abroad doesn't yank the inbox and the return flight doesn't yank it back), the
inbox **migrates**:

1. **Copy** `inbox/{X}/bundles/*` to the new store.
2. **Flip** `inbox-home/{X}` to the new store, the locator is the single source of truth.
3. **Sweep + tombstone** the old inbox: re-scan it for writes that landed mid-copy, move them,
   then leave a tombstone/redirect so a stale writer that still had the old location re-files to
   the new home instead of resurrecting the old inbox.

Migration is a damped, occasional relocation of the primary, never a per-message decision.

### Channels & services (`hps://`, §32)

Two shapes, handled differently:

- **The subscribe handshake is unicast**, `HpsSubscribe`→host and `HpsKeys`→subscriber are
  `Device`-addressed, so they ride device inboxes with no special casing.
- **Publishes are broadcasts**, one writer, many readers, *no subscriber registry* by design, so
  they don't belong to any one inbox. They get a parallel **topic inbox** `topic/{path}/bundles`,
  placed by **demand** (§21 `RegionRouter`): a relay holding a broadcast for topic `T` writes it
  into `topic/{T}` only in **stores that have live subscriber demand** for `T`, a store with
  nobody listening never receives it. A subscriber drains `topic/{T}` on check-in from a
  **per-subscriber read cursor** (so each member gets each message once without a registry),
  decrypts with the content key, and verifies the sender (§32). **ACK-based reach** still works:
  the ACK to the host is `Device`-addressed, so it rides the host's inbox back. Topic inboxes are
  **TTL-evicted** (no per-member purge, since there's no membership list).

### Invariants & consolidation

- **Nodes never wake nodes.** Every inbox / locator / topic-inbox operation is a passive Firestore
  read or write; the only thing that wakes a region is a device's own connection.
- **Relays carry only ciphertext.** Inboxes store sealed bundles; placement and migration never
  open them.
- **Relay-node partitions (§27) shrink to in-flight scratch**, what a node is actively carrying
  across its own restart. The **inbox is the authoritative durable delivery layer**; the §28
  cross-partition handoff becomes "write to the recipient's inbox."

### GDPR / residency tie-in (§33)

Migration buys **locality**, data gravitates to where the user sustainedly is, and a more
defensible transfer story (the data follows the user's *own* access). But **locality ≠ residency**:
sustained-access region is still *topology*, not a *declared jurisdiction*. A hard localization
mandate overrides migration with a **declared home region** that **pins** the inbox (disables
migration) to the declared store. Absent a declaration, store-near-use + migration is the right
default (§33).

**Detect for locality; declare for residency.** The two needs take opposite signals, and
conflating them is a mistake:

- **Locality (performance), detect automatically, no user input.** This is just the migration
  affinity above: *sustained* region-of-connection over a window. It can be sharpened with IP
  geolocation (the strongest single auto-signal, but noisy under VPN/proxy/travel *and* itself
  personal data, so geolocating means **persisting more PII**) or device locale/timezone (weak).
  Sustained affinity is the **privacy-cheaper** signal, it needs no stored IPs, so it's the
  default; IP/locale are optional accuracy boosts, not requirements.
- **Residency (legal/compliance), the user must declare it; never infer it.** An inferred
  residence cannot drive a localization decision, for reasons that all point the same way:
  1. **Not authoritative**, only the person (or an authority) knows their legal residence;
     topology can't establish a legal fact. `"user asserted EU residency"` is auditable; `"we
     geolocated their IP"` is not.
  2. **A confident wrong guess is a breach**, misclassify one VPN user and their data goes to the
     wrong continent *while you believe you're compliant*.
  3. **Inference is self-defeating**, detecting residence means collecting/persisting more
     personal data (IP, location history, locale) and building the person↔location linkage the
     no-registry design (§23) deliberately avoids; you'd do more surveillance to satisfy a
     privacy requirement.

  (And recall §33: GDPR proper keys on the *service's* targeting/monitoring, not per-user
  residence, so for GDPR itself you need no detection at all.)
- **The middle ground, suggest, then confirm.** Pre-fill a likely home from sustained affinity,
  **suggest** it, and let the user confirm or override. The inference only pre-fills the field; the
  **user's confirmation is what carries the legal weight**, one-tap setup for most people, an
  auditable declaration for compliance, and no guess ever treated as the answer.

### Open / abuse

Anyone can create an inbox for any address (it's a write-only drop box; content is sealed; only X's
keys can read it). Inbox-spam / storage-exhaustion is bounded by **TTL + per-destination quotas**
(as §19), future work.

## 35. Backbone access control & metering, keyed relay, free tier, and wake protection

> **Status: partially built.** The carriage stamp, keyed-relay gate, and per-tenant metering are
> implemented (see "The carriage stamp" below); the link-RAT admission and Stage-1 edge gate
> remain design. This section adds the missing seam that makes the **hosted** backbone (§21/§28) both
> *monetizable* and *abuse-resistant*. This is a property of the **hosted service**, not the
> protocol: the open SDK and any self-hosted relay fleet set their own admission policy. The
> protocol's only obligation is to **carry a credential at link establishment** (below); whether a
> relay *requires* one is operator policy.

### The problem this closes

§28's backbone is **scale-to-zero and woken by client connections**, which, unguarded, is two
liabilities at once:

1. **No tenant identity ⇒ nothing to meter.** Relays carry *sealed* bundles (§33) and deliberately
   can't read content or maintain a person↔address registry (§23). Without a separate billing
   identity there is no honest unit to charge for, the very thing the business model (free SDK,
   paid backbone) depends on.
2. **Open wake ⇒ cost-amplification / DoS.** If *any* TCP/WebSocket connection wakes a region
   (Cloud Run cold-start + Firestore spin-up), an unauthenticated flood lights up the whole fleet
   and bills the operator for traffic that was never legitimate. "Clients are the only wake trigger"
   must become "**keyed** clients are the only wake trigger."

Both are fixed by one primitive: a **signed access credential presented before any relay work**,
verified cheaply enough to gate the wake itself.

### The credential, a Relay Access Token (RAT)

A **RAT** is a short-lived, signed bearer ticket that authorizes use of the *hosted* backbone. It
is **distinct from the node's Hop address** (§23): the address is per-device identity (Noise link
auth, store key); the RAT is the **tenant/billing identity**, which app or account is responsible
for this traffic.

```
RAT {
  v:        u8           // version
  tenant:   TenantId     // who is billed / metered (an app or org, not a person)
  tier:     Tier         // free | pro | enterprise, selects quota class
  scopes:   Scopes       // relay, mailbox, egress, hps, regions allowed
  quota:    QuotaClass   // rate / storage / egress ceilings for this tier
  bind:     Option<Addr> // optional: pin to one Hop address (anti-sharing, macaroon-style)
  iat, exp: u64          // issued-at, short expiry (minutes-hours)
  sig:      Signature    // Ed25519 over all preceding fields, by the account-service key
}
```

- **Issued by an account service** (Hop's, or an enterprise's own for a private fleet). A device
  mints/refreshes a RAT *while it has connectivity* and **caches it** for offline use within its
  TTL, consistent with delay-tolerance: you don't need to be online at *use* time, only to have
  obtained a still-valid ticket.
- **Verified statelessly.** Relays (and the edge gate below) carry the account-service **public
  key** baked in and check `sig` + `exp` + `scopes` locally, **no database lookup, no network
  call** on the hot path. This is what lets the check be cheap enough to run *before* a wake.
- **`free` is a real tier, not an absence of a key.** The free tier is a valid RAT with the `free`
  quota class. **Anonymous (no RAT) is rejected**; "free" still carries a ticket. The key is an
  *identity + meter*, never a paywall, which is exactly why a generous free tier and strict
  admission coexist without contradiction.

### Where it rides, admission at link setup

Every link to a hosted relay is a Noise XX session (§4). The RAT travels **in the Noise handshake
payload** (XX allows application payloads in its messages), so it is validated **as part of
establishing the link, before a single bundle is offered**:

- Missing / malformed / expired / wrong-scope RAT ⇒ the **handshake is refused**; the connection
  never becomes a usable link and no bundle work occurs.
- `bind` present ⇒ the relay checks the Noise-authenticated static key equals `bind`, so a leaked
  RAT can't be replayed from an arbitrary device (anti-sharing). Unbound RATs are allowed for
  multi-device tiers; quota then catches sharing economically.

### Wake protection, the two-stage gate

A scale-to-zero relay can't validate a RAT *before it exists*, so admission can't live **only** in
the relay, the cold-start is the cost we're trying to avoid. Split it:

- **Stage 1, edge authenticator (always warm, cheap).** A small, **min-instances ≥ 1** gate sits
  in front of the fleet (at/with the global load balancer). It does **only** stateless RAT
  verification (signature, expiry, scope) + an emergency deny-list check, then proxies *only valid*
  connections to the region node. It holds no Firestore, no per-region state, no bundle logic, so
  it's a fraction of a relay's cost to keep warm, and it is the **one** always-on component.
  **Unauthenticated connections are rejected here and never reach, never wake, a relay.**
- **Stage 2, relay enforcement (on the now-woken node).** Past the gate, the region node
  re-validates the RAT on the Noise handshake (defense in depth) and enforces **fine-grained
  quota**: per-tenant rate limits, mailbox storage caps, egress ceilings, and **per-tenant
  metering** (below). Over-quota free traffic is **throttled or shed with backpressure**, not
  hard-dropped where delay-tolerance lets it wait.

This preserves every §28 invariant and tightens one: **nodes still never wake nodes** (cross-region
movement is the passive cross-partition handoff, a Firestore write); the **only** wake path is a
client connection, and now that path must present a valid RAT to get past Stage 1. The liveness
registry, presence index, and region routing are unchanged.

### Metering, measure the envelope, never the content

The relay attributes usage to `RAT.tenant` on the **sealed envelope**, consistent with §33: it
counts **volume, not content**. The billable units (§pricing):

- **Relay carried**, bundles/chunks stored-and-forwarded on the tenant's behalf (count + bytes).
- **Mailbox storage**, sealed bytes × retention held in inboxes (§34) for the tenant's recipients.
- **Internet egress**, bytes fulfilled out to the public internet / bridged across regions (§9/§19).

**The metering atom is the bundle/chunk, not the logical message.** A large message is split by the
carrier transport into many sealed `Payload::Carrier` chunks (§31), each its own stored-and-forwarded
datagram, so a 5 MB image is metered as the dozens of chunks it actually is, and billing scales with
**data carried** rather than message count. (Link frames, §5, are per-hop and ephemeral, never
metered.) This is why "relay carried" is best billed by **GB/chunk-count**, the only unit fair across
a chat line and a media payload.

Usage rolls up per `tenant` for billing; the relay never opens a payload to meter it. (`hps://`
topic fan-out is metered to the **publishing** tenant, since broadcasts have no per-subscriber
billing identity.)

### The carriage stamp, bundle-level attribution (built)

> **Status: built** (`hop-core/src/access.rs`, `Envelope::access`, wire v9; carriage stamps were introduced in v8; relayd
> `--require-stamps` / `--billing-root` / `--deny-tenant`). The link-RAT admission above and the
> Stage-1 edge gate remain design.

The link-level RAT has a blind spot that store-and-forward creates by construction: **the peer
whose connection carries a bundle into a relay is routinely not the tenant whose traffic it
is**. A §39 private bundle floods peer-to-peer and reaches the backbone via whatever device
touched a relay last; a mailbox pull re-injects bundles with no live sender at all. Attributing
at the link would bill couriers, not senders. So the billing credential ALSO rides the bundle:

```
CarriageStamp {
  hint:  [u8; 4]     // H("hop carriage hint v1" || tenant_id || epoch)[..4], rotates per epoch
  sig:   Signature   // Ed25519 by the tenant key over "hop carriage stamp v1" || bundle_id || epoch
  epoch: u64         // the (coarse, hourly) rotation epoch this hint + sig were computed for
}
```

The stamp reveals NOTHING about the tenant to the network: no app id, no tenant id, no public
key on the wire, only a `hint` that rotates every epoch (the same discipline as §39 mailbox-tag
rotation). The `hint` is an O(1) SELECTOR, not the authorization: a keyed relay's KEYSERVER
(its keylist of `{tenant_id -> stamping pubkey}`) precomputes `{hint -> [tenant]}` per epoch, so
recovering the tenant is a hint lookup plus an O(bucket) signature check, never an N-key loop,
and an unauthenticated bundle whose hint hits no known tenant is rejected after an O(1) lookup.
The authorization is the SIGNATURE, which only the tenant's key can produce over this exact
bundle id, so a relay cannot fabricate attribution and a captured stamp cannot be lifted onto
another bundle.

- **Where it rides.** A trailing `Option` on the mutable, unsigned forwarding `Envelope`, so
  both the private content id and the wire id EXCLUDE it: identical content keeps one identity
  and dedups regardless of access material, re-stamping never forks an id, and the §39 id
  discipline (the id as the sole integrity check of an unsigned bundle) is untouched. The
  price: the bundle's own checks do not cover the stamp, so a stripped stamp is lost postage
  rather than a forgery (any custodian holding a tenant key can re-stamp; a couriered bundle
  that loses its stamp just stops being admissible until then).
- **Verify at the meter, never read a field.** Because the stamp is on the unsigned envelope,
  EVERY point that reads it for a billing or admission decision re-runs the keyserver lookup +
  signature check (`AccessPolicy::admit`). It never trusts a bare recovered tenant, or an
  attacker rewrites who-pays (bill a victim, or garbage for free carriage).
- **Who stamps.** `Node::submit`, the single origination choke point, stamps everything a
  configured node originates for the current epoch. The return path must be admissible at keyed
  relays too. Vaccines are exempt (anti-packets, not billable, and stamping would leak the
  recipient). Devices without a stamper (pure P2P apps) originate unstamped bundles and lose
  nothing off the backbone. Stamping keys MUST be app-scoped, never per-user (a per-device key
  makes the rotating hint a per-user tracking handle within an epoch).
- **Epoch rotation.** The hint rotates hourly; a relay accepts the current AND previous epoch
  (transit + clock skew) and refreshes its precomputed tables as the epoch rolls, which also
  bounds stamp replay to the ~2h hint window.
- **The gate.** Under a `Keyed` policy the relay admits a foreign bundle to custody only with a
  verifying stamp; `LOCAL_LINK` re-injections (durable re-ingest, mailbox pulls) are trusted
  first-accepts, and vaccines are exempt (anonymous anti-packets that must propagate to purge
  delivered copies; stamping would leak the recipient).
- **The meter (delivery-justified).** Billing is NOT charged at custody. The relay records the
  tenant it VERIFIED at admission and bills it only when delivery is PROVEN: a returning ACK or
  a §39 delivery vaccine that purges the held copy. A bundle held but never delivered (evicts or
  TTL-expires) is never billed as carriage; its durable-storage occupancy is priced by the
  separate storage GB-hour floor. Recording the verified tenant at admission (rather than
  re-reading the mutable stamp at delivery) both closes the bill-shifting hole and bills a
  delay-tolerant delivery correctly after the stamp epoch has rolled. The OFFLINE path bills too:
  a spooled bundle re-ingested for delivery is attributed at re-ingest (verifying the stamp
  against its own signed epoch, since a spooled stamp is legitimately old), so its eventual mesh
  delivery bills the offline-delivery path. Still to wire: cross-instance region-shared dedup (so
  N same-region instances bill once) belongs at the async §37 reconciler, not the driver hot
  path; and the §37 BigQuery reconciler + Stripe.
- **The partition IS the business boundary.** A relay only honors stamps whose signer is in ITS
  keyserver. A commercial (hosted-fabric) stamp means nothing to a private fleet with a
  different keyserver, and vice versa: an unauthed key cannot ride, so self-hosting yields a
  sealed island by construction, and reaching the broader fabric is always metered (§36
  federation is the sanctioned bridge).
- **Custody beacon (COGS, mode-1 built).** A relay's dominant cost is duplicate INGRESS: a
  high-degree relay is offered the same bundle by every neighbor that already accepted it. The
  custody beacon cuts it: on connect, a relay sends a `Wire::Have` listing what it already holds,
  and the peer suppresses re-offering those (a new pre-send check beside the per-link
  sent-bundles filter). MODE-1 only for now: the beacon is exchanged over the AUTHENTICATED Noise
  link with the peer it constrains, so it is that peer's own truthful claim about its own store,
  an exact set with no false positives and no forgery/censorship surface. (A FLOODED regional
  beacon would be strictly advisory and exclude §39-private ids, per the adversarial review; it
  is a later addition.) Off by default (devices spare their BLE link); relays enable it.
- **Privacy stance.** The stamp exposes only a rotating `hint` to on-path observers: nothing
  about the person, and nothing that links a tenant's bundles across epochs to an observer who
  cannot enumerate tenant ids. One who can enumerate them recovers at most the k-anonymity of
  the epoch bucket, the app-level attribution §33/§39 already accept, and sender identity still
  stays inside the seal with recipients recognition-only. Blind tokens (per-bundle unlinkable
  credentials) remain the documented upgrade path for full unlinkability.
- **Known gaps, deliberate.** `hps://` broadcast fan-out work happens before the custody gate
  and is not yet metered to the publisher; mailbox-storage and egress dimensions are §37 work
  on top of the same ledger; the link-RAT + edge gate (wake protection) compose with, and do
  not replace, the stamp.

### Revocation & key rotation

- **Short TTL is the primary control.** A leaked RAT self-expires in minutes-hours; the device
  silently refreshes from the account service while online. No long-lived secret sits on the wire.
- **Emergency deny-list at the edge.** For revocation *before* expiry (compromise, abuse), the
  Stage-1 gate consults a small denied-`tenant`/denied-`jti` set, the one piece of shared state it
  reads, and it wakes no relay.
- **Account-service key rotation.** The signing key is versioned (`RAT.v` + a key id); relays and
  the edge gate carry the current + previous public keys so rotation doesn't invalidate in-flight
  tickets.

### Why this doesn't compromise the open model

The protocol gains exactly one capability, *carry a credential in the link handshake*, and one
operator knob, *require it or not*. The **open SDK self-hosting its own relays needs no Hop RAT**
(it sets its own policy, or none). The RAT requirement is the **hosted backbone's** admission and
metering policy, layered on top. That is precisely the seam the business model wants: the protocol
stays open and free to run yourself, while the **hosted** fabric is keyed, metered, free-tier-first,
and protected from waking on traffic nobody is accountable for.

## 36. Private & federated backbones, islands, and the bridges between them

A **private backbone** is a separate relay fleet (a customer's own GCP project or on-prem) with its
own identities, its own per-region durable partitions (§27), and its own RAT issuer (§35). It exists
for isolation, control, and data residency (§33). The question this section answers: *when someone
runs a private backbone, what still flows through it, and what does the broader Hop network lose?*

The answer hinges on Hop relaying at **two layers that behave oppositely**, and conflating them is the
mistake:

- **Device/BLE layer, always shared, always cross-app.** Two Hop devices in radio range relay each
  other's sealed bundles regardless of app or backbone. A relay forwards ciphertext addressed to a
  *key*; it doesn't know which app produced it (app-namespacing is a payload/topic concern, §16/§24).
  So a private-backbone customer's users **still relay for, and benefit from, every nearby Hop
  device.** This is where the network-effect moat actually lives, and **no backbone choice removes
  it**, you cannot opt your users out of being good BLE citizens without forking the protocol.
- **Cloud backbone layer, scoped to whoever attaches.** A device connects to exactly one backbone
  entrance (the anycast name it's configured with, §21). A bundle only transits the backbone its
  origin/custodian is attached to. So a private backbone is, by default, an **island at the cloud
  layer**: it carries only its own app's cloud traffic, and other apps neither traverse it nor carry
  its bundles. That isolation is usually the whole point.

**So: a private backbone does not carry other apps' cloud traffic by default, and that's a feature,
not a regression.** The customer keeps the ambient device mesh; they give up cloud-layer mixing, which
is exactly what they're paying to give up.

### Federation, safe because relays only ever see ciphertext

Isolation need not be all-or-nothing. Because every bundle is **end-to-end sealed and signed**
(§4/§5) and relays carry ciphertext they cannot read, two backbones can **peer** without trusting each
other with content. A **bridge relay** is simply a node that is a member of both fabrics, it holds a
RAT for each, and moves cross-boundary bundles via the same online-only epidemic / cross-partition
handoff used inside one backbone (§28). It learns only envelopes (addresses, sizes), never plaintext, the same exposure any on-path relay already has.

This makes private deployment a **dial**, not a binary:

- **Isolated (default).** No cross-traffic. Maximum control and residency; the customer's fabric is
  air-gapped from the public one at the cloud layer.
- **Federated.** The private fabric peers with the public one (or with a partner's). The customer's
  own infra carries their baseline traffic and keeps their data in their region, but their users stay
  **reachable across the global fabric**, a bundle addressed from a public-backbone device to one of
  theirs crosses the bridge, sealed the whole way.

**Routing across the bridge** reuses §21 presence: the bridge advertises reachability for the
addresses/regions it can reach on the far side, so the epidemic only pushes a bundle across the
boundary when there's a destination (or live topic demand) over there, no blind flooding between
fabrics. Federation can be scoped (e.g. only certain topics or address ranges cross) so a customer
exposes exactly as much surface as they want.

### Business shape (ties to §35 and pricing)

- Private backbones are **not MAD-metered** like the hosted service, the customer runs the infra and
  pays their own GCP bill. We charge a **platform/license fee + support**, with **federation as an
  add-on** (per-bridge or per-region), since a bridge consumes hosted-fabric resources and inter-fabric
  egress.
- The core network effect is unharmed: every private customer's *devices* still thicken the shared
  BLE mesh, and federation keeps their *cloud* traffic in the fabric when they want it. Going private
  is a deployment option, not an exit from the network.

## 37. Metering & billing, capture, aggregate, and charge

§35 named the billable units; this section makes them *collectable and chargeable*. The job: capture
every unit of billable usage at the relay, persist it durably and **idempotently** (relays scale to
zero and bundles are re-tried/replicated, naïve counters would double-count or lose counts), then
report it to **Stripe** so an invoice actually goes out. The chain is **capture → ledger → reconcile →
Stripe meters → invoice**, and every link is idempotent so the worst case is a retry, never a double
charge or a silent loss.

### What we meter (four dimensions)

All keyed by `RAT.tenant` (§35), measured on the **sealed envelope**, counts and bytes, never content
(§33).

| Dimension | Unit | Stripe meter aggregation | Captured when |
|---|---|---|---|
| **Active devices (MAD)** | distinct devices / period | `count` of first-seen events | a device's first authenticated link in the billing period |
| **Data carried** | chunks (and/or bytes) | `sum` | each chunk/bundle the relay stores-and-forwards (§31, a large message is many chunks) |
| **Internet egress** | bytes | `sum` | bytes fulfilled to the public internet / bridged across regions |
| **Mailbox storage** | byte-hours → GB-month | `sum` of byte-hours | sampled per retention interval on held inbox bytes |

**MAD without storing identity.** Active devices is a *distinct count*, but Stripe meters only
`sum`/`count` events, they can't dedup. So we dedup at the edge: the **first** time a device address
authenticates for a tenant in a billing period, the relay emits exactly **one** `mad` meter event;
subsequent links that period emit none. The per-period "seen" set is a tenant-scoped, period-scoped
probabilistic set (HyperLogLog / bloom) keyed by address, **pseudonymous, period-bounded, never linked
to identity** (§23/§33). Aggregation `count` then sums first-seen events to the period's MAD.

### Capture → durable usage ledger (idempotent)

Relays are ephemeral (scale-to-zero, §28), so in-memory counters can't be the source of truth. Each
relay writes **usage deltas** into a durable per-tenant ledger in its region partition:
`usage/{tenant}/{period}/{shard}`, monotonic counters plus an **idempotency set** so the same unit is
never counted twice:

- **Data carried / egress**, deduped by the chunk's bundle id (+ frag index): a re-sprayed or
  re-forwarded copy of a chunk already counted is ignored. Custody/epidemic replication (§31) means a
  chunk may pass several relays; it is billed **once**, at the relay that first commits it for the
  tenant (the same "first commit wins" the dedup window already enforces).
- **MAD**, deduped by `(tenant, period, address)` via the HLL/bloom set above.
- **Mailbox**, a sampler walks held inbox bytes per interval and adds byte-hours; idempotent by
  `(tenant, period, sample-tick)` so a re-run of a tick can't double-add.

Writes are small and sharded to avoid hot-doc contention; the ledger is the **authoritative** record,
independent of whether reporting has happened yet.

### Reconcile → Stripe meter events

A periodic **billing reconciler** (a scheduled job, *not* on the bundle hot path) reads each tenant's
ledger forward from a stored **watermark** and emits **Stripe meter events**, one per dimension, with the payload Stripe's meter expects (`{ stripe_customer_id, value }`, mapped via the meter's
`customer_mapping`). It then advances the watermark. Two properties make this safe:

- **At-least-once + idempotent.** Each meter event carries an idempotency key derived from
  `(tenant, period, dimension, ledger-offset)`. If reporting succeeds but the watermark write fails,
  the next run re-sends the same events, Stripe dedups them, so no double charge. If reporting fails,
  the watermark doesn't advance and the ledger still holds the truth, so nothing is lost.
- **Decoupled from delivery.** Metering never blocks or gates a bundle; a billing outage degrades to
  *delayed* invoicing, never dropped traffic or dropped usage.

Stripe aggregates meter events per its meter definition and bills the subscription at period close.

### Tenant ↔ Stripe, base price + metered prices

The **account service** (the RAT issuer, §35) owns the tenant↔Stripe mapping: each tenant is a Stripe
**customer** with one **subscription** whose items are the prices defined in Terraform (`infra/billing`):

- A **base price**, a flat recurring platform fee (`usage_type=licensed`); `$0` for the free tier,
  a committed minimum for paid plans.
- **Four metered prices**, each bound to one `stripe_meter` (`usage_type=metered`, `meter=…`), priced
  per the cost model (§pricing / `docs/pricing-cost-model.md`).

**Included allowances** (free-tier and per-MAD) are modeled as **tiered metered prices**, first *N*
units at `$0`, overage above, so the invoice is transparent (the customer sees included vs. billed)
and the reconciler always reports **gross** usage rather than pre-subtracting, keeping the relay dumb.

### Why this captures and charges everything

- **Nothing escapes capture:** admission requires a RAT (§35), so every billable unit is attributable
  to a tenant the moment it touches the backbone; unkeyed traffic can't even wake a relay, so there is
  no unattributed usage to leak.
- **Nothing is double-charged or lost:** idempotent ledger + idempotent meter events make the whole
  pipeline at-least-once end to end.
- **Nothing leaks content:** every dimension is a count or a byte total on the sealed envelope.
- **Infra-as-code:** meters, base price, and metered prices live in `infra/billing` (Stripe Terraform
  provider); the meter **`event_name`s are the contract** between the relay reconciler and Stripe.

## 38. Anti-entropy & sets, the reconciliation primitive that makes sync build *on* Hop

Everything so far moves **messages**, a bundle is addressed, sent, delivered, acked. That's the
right primitive for messaging and egress. It is the *wrong* primitive for a **replicated store** (a
CRDT collection, an event log, a shared dataset, the layer a "Ditto-class" product is). Sync doesn't
ask "deliver this to Bob"; it asks **"what do you have that I don't?"** and transfers only the
difference. Brute-forcing that over message-passing (re-send everything, dedup on receipt) is
quadratic and wasteful. So Hop grows one more primitive above `hdp`: **anti-entropy over a set**.

This is the concrete hook that turns "a sync engine *could* be built on Hop" into "a sync engine is
*efficient* on Hop." It keeps the waist thin: **Hop provides convergence of a set of opaque,
content-addressed, sealed items, not merge semantics.** Conflict resolution / CRDT logic stays in the
L7 app (Automerge, Yjs, custom). Hop gets the bytes to where they're missing, efficiently and
delay-tolerantly; the app decides what they *mean*.

### The model: a namespace is a set of content-addressed items

- A **namespace** (`hsync://<group-or-address>/<collection>`) is an unordered **set** of items.
- Each **item** is content-addressed: `item_id = BLAKE3(sealed_bytes)`. Content-addressing gives
  dedup, idempotency, and integrity for free, and reuses the bundle dedup machinery (§4/§7).
- Items are **sealed to a group key** (the `hps` content-key model, §24/§32), so reconciliation
  works on **ciphertext**: a relay or the backbone sees item *ids and sizes*, never plaintext, consistent with the envelope-only metering and data-protection rules (§33/§35/§37).
- "Converged" between two replicas means **equal sets of `item_id`s**. The app layers a CRDT/log on
  top so that set-union *is* a correct merge (add-only sets, op logs, and most CRDTs have this shape);
  tombstones are just more items.

### The exchange: range-based set reconciliation, carried as bundles

Reconciling two large sets by shipping full digests is itself expensive. Hop uses **range-based set
reconciliation** (the Meadowcap/“RBSR” family): recursively compare **fingerprints of ranges** of the
sorted item-id space, descending only into ranges that differ, so cost is ~`O(d · log n)` in the size
of the *difference* `d`, not the set `n`.

- `SyncFingerprint { namespace, range, fp }`, a hash of all item-ids in `[lo, hi)`. Equal fp ⇒ that
  range is already converged; skip it.
- Differing range ⇒ split and recurse, or (once small) `SyncIdList { namespace, range, ids[] }` to
  name the exact items.
- `SyncWant { namespace, ids[] }` → the holder replies with the missing items as ordinary **`hdp`
  carrier bundles** (§31), large items chunk and reassemble exactly as any payload does.

Crucially these are **all just bundles**: floodable/forwardable, store-and-forward, sealed. So
reconciliation is **delay-tolerant**, two replicas that are never online together still converge,
each round trip crossing the partition whenever a path (or the backbone) appears. No live session,
nothing in the middle holding state (§30).

### Two gears

- **Anti-entropy (catch-up):** the range-based exchange above, bring two divergent replicas into
  equality in `O(log)` round trips. Used on first sync, after a long offline gap, or periodically.
- **Live subscribe (steady state):** once converged, new items propagate as they're created via an
  **`hps` subscription** to the namespace (§32), a per-subscriber cursor streams fresh `item_id`s,
  fetched on demand. Steady-state sync is just pub/sub; anti-entropy is the gap-filler. (Mirror of
  §31's "carrier transport for catch-up, streams for live.")

### The backbone is the always-available replica

Two devices that are never simultaneously online converge through the cloud backbone, which holds a
**replica of the namespace** in its region partition, the §28/§34 mailbox idea lifted from a unicast
*inbox* to a shared *set*: a device reconciles against the backbone whenever it checks in, and the
backbone reconciles region-to-region by the same cross-partition handoff. This is the direct analog of
Ditto's "Big Peer," but it stores **sealed, content-addressed items it cannot read**, and it's
demand-summoned/scale-to-zero like every other region node. Region routing (§21) applies: a namespace
only replicates to regions with live subscribers.

### What Hop deliberately does *not* do

- **No merge semantics.** Set-union convergence only; the L7 app supplies the CRDT/log so union is a
  valid merge. Keeping merge out of the waist is what keeps the waist thin and general.
- **No schema/query engine.** Items are opaque sealed blobs with ids. Indexing/query is the app's job
  (or a library above Hop).
- **No ordering guarantee beyond causal hints the app encodes** into items. `hdp` stays unordered; the
  set is unordered; ordered logs are an app construction.

### Why this closes the platform thesis (§30, positioning)

A replicated store is the single biggest L7 use case that message-passing alone serves badly. With
`hsync` over `hdp`, "build a Ditto-class store on Hop" becomes *efficient*, not just *possible*, the
app brings conflict resolution, Hop brings **convergence transport**: content-addressed, sealed,
delay-tolerant, backbone-assisted set reconciliation. Reconciled items are metered as **data carried**
exactly like any chunk (§37), so the platform and the business model stay one and the same.

**Status: design.** Build after the `hdp`/`hps` core and the backbone replica are solid; the
range-based set-reconciliation exchange and the namespace replica are the two new pieces. Wire types:
`SyncFingerprint`, `SyncIdList`, `SyncWant`, plus `hps`-carried item notifications, all `hdp`
bundles, all sealed, all forwardable.

---

## 39. Untraceable-by-default messaging, receiver-driven routing, opt-in provenance

§5 puts `src`/`dst` in cleartext and §27 records a provenance trace on every hop, so relays spray
toward the destination and learn routes. The cost: unicast is **traceable by default**, on-path relays
see who→whom and the path is recorded (the ❌ row in §10). This section **inverts the default**: a
message is **untraceable by default**, no cleartext sender, recipient, or path, and traceable only
when the sender opts in.

The idea that makes private *routing* (not just privacy) possible is to flip its direction: **you never
route toward a hidden destination; the destination advertises a gradient toward *itself*, by prefix, and
nodes follow it** knowing only "prefix P is that way," never who P is. The only thing the network does
to a private bundle is ask **"is this mine?"** (a cheap recognition check) and, if not, forward it down
whatever gradient it has, or, lacking one, hold it. It builds on primitives Hop already has: the
`topic_tag` recognition of §32, the `Broadcast` flood of §5/§7, the X3DH prekeys of §4/§25, the
demand-summoned regions of §28, the anti-entropy of §38, and the §27 trace machinery (now opt-in).

### What a private bundle exposes (and doesn't)

- **No `dst`.** Replaced by a per-message **recognition tag** only the recipient can match, plus an
  optional **mailbox-tag** (a rotatable pseudonym, below) when the recipient wants to be *pulled*, and
  an optional **`k`-bit prefix hint** for gradient routing.
- **No `src`, no identity signature.** Sender authenticity moves *inside* the seal, the recipient
  authenticates the sender from the established ratchet/X3DH session (§25), not a cleartext header
  signature (which would re-expose the sender).
- **`BundleId = H(sealed ‖ ephemeral)`** instead of `H(src ‖ sealed)` (§5), globally unique, dedups
  under flood, leaks nothing about the endpoints.
- **Empty `trace`** (§27), no hop recording.
- **Sealed payload unchanged** (§4). Content was already private; §39 closes the *metadata* gap.

A relay holding a private bundle sees an opaque tag, an opaque sealed blob, a BundleId, a lifetime, and
an app id, never the sender, the recipient, or (without colluding across the whole path) the route.

### Two tags: recognition vs reachability

Privacy needs one tag; being *reachable* needs another. They trade differently, so they are separate:

- **Ephemeral recognition tag (per message), unlinkable.** `tag = KDF(g^{e·P_recipient}, BundleId)`,
  with the ephemeral public `g^e` in the header. The recipient recomputes `KDF(g^{e·s}, BundleId)` per
  prekey and checks for a match, a few scalar-mults, no payload decryption. Because the ephemeral
  changes every message, two bundles for the same recipient share nothing a relay can correlate. This
  is the **transit** identity, for *recognize-as-it-floods-by*. (A static `H(prekey)` tag would be
  O(1) but linkable; full trial-decrypt is unlinkable but an AEAD attempt per node, the ephemeral tag
  is the same privacy, far cheaper.)
- **Mailbox-tag (per epoch), a rotatable pseudonym.** `mailbox = H("v2" ‖ recipient address ‖ epoch)`
  with a daily epoch (F-06). Any sender (who knows the recipient's address for a private send) can stamp
  it, a relay can *bucket* by it, and the recipient names it in a beacon ("spray me mailbox M"). It is
  **not** the address, you can't seal to it or message it, only group by it, and it **rotates every
  epoch**, so a global observer can't link a recipient's mailbox across epochs. It exists only
  because **you cannot solicit a bundle you have not seen**: the ephemeral tag is uncomputable in
  advance, so pulling needs a standing handle. That handle is linkable while it lives (an indexer
  clusters "mailbox M's traffic"), the honest, irreducible price of being reachable while offline.
  Passive recipients never use it.

### Routing: the beacon gradient (soft state)

A recipient that wants to be *routed to* (not merely recognized as traffic floods past) emits a
**beacon**: a small signed bundle carrying its mailbox-tag (or `k`-bit prefix) and a fresh
**reverse-path token**. As the beacon propagates, every node it crosses records a **gradient**: "prefix
P / mailbox M is reachable via the neighbor I heard this from." A node then **holds** a private bundle
until it has a gradient for that bundle's prefix and **forwards down the gradient**, directed, cheap,
and private (the node knows a direction, never an identity).

Three rules keep this sound, not a foot-gun:

- **Signed beacons.** The beacon is signed by the prekey behind its mailbox-tag, so only the holder of
  M can advertise a gradient for M. No node can hijack or black-hole a prefix it doesn't own.
- **Soft state that decays.** A gradient is recency-weighted (§18/§27 half-life), refreshed by periodic
  re-beaconing, superseded when a newer beacon arrives from a different direction. "Holds a path" means
  *between refreshes*, never forever, otherwise a moved recipient black-holes.
- **Flood is the fallback, not the default.** With no gradient yet (cold start, or a never-seen
  prefix), a node falls back to bounded flood, the local physical mesh, the `k`-bit anonymity-set, or
  `Broadcast`. The recipient's beacon *is* the bootstrap: you can only route to a prefix that has
  advertised itself, so an offline recipient has no live gradient and senders hold (in the durable
  spool, below).

A beacon is just a bundle, so the gradient is **bearer-agnostic** (§26): one learned over BLE is
followed by a bundle arriving over LAN or a relay link, the `BearerManager` seam makes the transport
irrelevant to routing.

### Reaching a recipient: want beacons and the gateway-as-bearer

"A relay is just another bearer", a **gateway** is simply a node whose `BearerManager` has a relay
link up (§9/§19/§26). A recipient several P2P hops from any internet node never touches a relay
directly; it **pulls from its local mesh**, and its want beacon recruits whoever can help: **holders** (a
peer or carrier with a matching bundle) spray it back along the reverse-path gradient, and **gateways**
reconcile its pending set from the backbone and spray it back the same way. Two shapes, the familiar
privacy/bandwidth knob:

- **Passive (max privacy):** no beacon, the recipient recognizes by ephemeral tag whatever floods
  through its mesh (a gateway injecting the region's pending set is one such source). Zero linkable
  handle; you only get what physically reaches you.
- **Active (reachable):** a want beacon with a mailbox-tag, reachable deep in the mesh and across
  dormant regions, at the cost of that pseudonym being clusterable while it lives.

If there is **no gateway in the component** (offline island), pure DTN applies: the bundle arrives when
a node already holding it carries a link, or itself, into the island (a data mule), or when the
island gains a gateway. Nothing is dropped; held until lifetime/ACK.

The **inbox bifurcates by mode**: §34/§28's `inbox/{recipient-address}` is recipient-*keyed* (a
cleartext-dst construct). Private mode has no recipient-keyed inbox, it has a **blind spool** keyed by
mailbox-tag that the recipient pulls; traced mode keeps the address-keyed inbox and targeted
spray-and-wait. Privacy means the gateway can't *target* the recipient, so it floods the component or
answers a blind pull, the routing-vs-privacy asymmetry, one layer down.

### Cross-region under dormancy: eventual delivery, no global store

Regions are **anycast** and **demand-summoned** (§21/§28): a sender always deposits in *its own* nearest
region (it can't, and under privacy shouldn't, target the recipient's), and a region's relay is dormant
when its region has no active devices. So a message to Bob in another region lands in the sender's
regional DB, whose compute may scale to zero before Bob ever wakes his. That is fine, for two reasons:

- **The durable store outlives the compute.** A region's spool (Firestore/GCS, §33) persists when its
  Cloud Run scales to zero. Dormancy stops *forwarding*, not *storage*.
- **Delivery is eventual, via relay-tier epidemic, not a global DB and not simultaneous wake.** While
  awake, a region anti-entropy-syncs its pending set to **whatever other regions are awake then** (§28
  online-only relay epidemic, §38 RBSR). The bundle **store-carries-forwards across the region mesh over
  time**, region A↔B now, B↔C later, riding pairwise awake-overlaps. The recipient's region, on wake,
  reconciles with **whatever regions are awake now** (not the depositing one); if the bundle reached the
  awake set it's there, and if not, continued spread brings it before `lifetime` (§8) expires. Delivery
  holds as long as the region graph is *temporally connected* within the bundle's lifetime, which a
  globally-active device population provides.

So "keep both relays awake" is the *fast* path; the dormant path is slower but certain. No region ever
wakes another; the durable regional spools plus the awake-set epidemic are the rendezvous. This keeps
§28's **regional DBs as-is**, no continental or global store.

### Opt-in trace: buy back routing and visibility

Setting the trace flag reverts *that one message* to §5/§27: cleartext `Destination::Device(dst)` (so
relays run spray-and-wait §6 and learn routes §27) and per-hop `TraceHop` recording (so the sender
watches the path and "Sent N / delivered"). A deliberate trade of privacy for **both** efficiency and
visibility, right for debugging or a public/infra flow, wrong for a personal message. The machinery
already exists; §39 only flips which mode is the default.

### The anonymity-set hint, and soft-state discipline

The `k`-bit hint *is* the gradient's prefix: a beacon for a `k`-bit prefix maintains a gradient shared
by the ~`N/2^k` nodes in that anonymity set, so private routing is exactly "gradient toward the prefix."
`k=0` = no hint = full flood (the privacy floor); larger `k` = a sharper gradient and fewer holders, but
it leaks `k` bits of destination entropy and adds prefix-level linkability (a recipient's messages share
their prefix). A mesh dials `k` up only when it grows large enough that flooding hurts.

**Realized (sec-priv-04):** routing, spooling, and want-beacon matching now ALL key on the tag's
`MAILBOX_ROUTE_PREFIX_BYTES`-byte prefix (16 bits by default), never the full 16-byte tag. The full tag
still travels in the beacon (so the relay authenticates it against the publisher's signed address, F-05),
but the **private header carries ONLY the routing prefix** (`crypto::MailboxRoute`, the leading
`MAILBOX_ROUTE_PREFIX_BYTES` of `H(address ‖ epoch)`), never the full 16-byte tag (core-protocol-r2-02).
The recipient never reads a target mailbox-tag off the header; it recomputes the per-message *recognition*
tag locally from its own prekey and the header's ephemeral. Carrying the full tag verbatim would let a
bundle-capturing address-knower recompute the target's tag and uniquely re-link the recipient off the
header, so only the prefix rides the wire, exposing at most the same anonymity-set membership the routing
layer already does. No routing
*decision* uses more than the prefix. This is what defeats an **address-knower**: the full mailbox-tag
is a public deterministic function of a broadly-known address, so anyone holding the address can compute
it every epoch; if routing keyed on the full tag they could uniquely confirm a target's private traffic,
and epoch rotation would do nothing against them. Keying on the prefix instead gives them only an
*anonymity set* (every address, known or not, that collides on the prefix) rather than a unique match.
Because a prefix bucket can now cover several distinct recipients on different next-hops, a gradient
bucket holds a bounded SET of next-hops and a matching private bundle rides all of them (never a
non-next-hop leaf); the wrong recipient in the set just fails the per-message recognition tag and drops
its copy. Delivery is decided by the final "is this mine?" test, the per-message-ephemeral recognition
tag, which stays unique and unlinkable.

**Collision recovery is spool-backed, and that spool needs a carrier running the reload loop
(security-privacy-r3-02).** One collision case does NOT self-heal on the directed path alone: an ACTIVE
recipient B1 that beacons a prefix, colliding with a PASSIVE recipient B2 that shares the prefix but
never beacons. B2's bundle is steered only down B1's link (B1 drops it on the recognition check), and B2
is a leaf in no gradient, so the directed path never reaches it. The recovery is the durable want-beacon
SPOOL: the carrier holding the bundle keeps it spoolable by mailbox-prefix (`spoolable_private_bundles`),
and when B2 later beacons, the carrier reloads the spool and re-ingests it so P4 steers the reloaded copy
to B2 (worked scenario 3 below). We deliberately do NOT flood the bundle to leaf links "just in case",
because a node cannot tell a passive RECIPIENT leaf from a passive DECOY leaf without opening the seal,
so flooding would leak exactly the traffic P4 hides. The consequence: recovery requires SOME node in the
partition to run the spool-reload loop. `hop-relayd` always does; a relay-served partition therefore
never black-holes B2. Those spool APIs are transport-agnostic, so a pure-P2P carrier can run the same
loop, but a pure-P2P partition with NO node running it (e.g. the relays-deployed-off P2P-test phase)
cannot recover B2 off-relay until a carrier does. Closing that fully is a driver task (run the
spool-reload loop on P2P carriers), not a wire or core-routing change.

**Treat every piece of routing/spool state as soft-state with a TTL and a cap, from day one.** Gradients
decay (above); held private bundles evict at `lifetime` (§8); each node caps its gradient table.
**Mailbox-tags rotate per epoch (F-06):** `mailbox = H("v2" ‖ address ‖ epoch)` with a daily epoch, so a
global observer can't correlate a recipient's mailbox across epochs. A recipient beacons the current epoch
plus a one-epoch window (and a relay accepts that window), so a bundle addressed/spooled just before a
rotation boundary still routes and pulls. Deriving from `(address, epoch)` rather than the prekey decouples
rotation from the deterministic prekey (sessions/recognition are untouched) and makes a beacon **self-
verifying at the relay from public info**, the relay recomputes `H(publisher ‖ epoch)` and only lays a
gradient if it matches, and since a beacon is identity-signed by that address, no node can forge a victim's
mailbox (F-05). Residual: being pull-reachable via a signed beacon inherently reveals "this address is
reachable this epoch"; that's the documented cost of pull-reachability (a fully passive recipient sets
`route_to_me = false` and advertises no mailbox). Caps + rate-limits stop a Sybil *bloating* the table with
fake mailbox-tags; §35 keying gates relays. Anything that "remembers forever" is a storage and DoS liability.

### Costs (honest)

The model trades targeted routing for privacy, and the bill is real:

- **Storage amplification (the first to bite).** A private bundle replicates across many regional DBs
  (epidemic) and device stores (flood). The hint bounds *which* regions/holders carry it; `lifetime`
  eviction bounds *how long*. This is the price of hiding the destination.
- **Beacon control-traffic.** Gradient freshness costs periodic beacons; budget it like any routing
  protocol's control plane (low-rate, prefix-scoped, soft-state).
- **Latency / eventual confirmation.** The dormant path is minutes-to-hours, and the ACK is itself a
  private bundle making the same round-trip, so "delivered" is eventual too. Consistent with §1/§8.
- **The linkability floor (fundamental).** Reachable-while-offline-across-regions requires a standing
  routing handle, so an indexer can cluster a pseudonym. sec-priv-04 shrinks that handle from the full
  per-address tag to a `k`-bit prefix, so both a passive indexer AND an address-knower cluster only an
  *anonymity set* of ~`N/2^k` addresses, not a unique identity; epoch rotation bounds the cross-epoch
  window on top. But the set is not empty: pure unlinkability stays local-only (a fully passive recipient
  that sets `route_to_me = false` and beacons nothing). You cannot have global reachability *and* zero
  linkability; you can have global reachability with prefix-set linkability, which is what this ships.
  - **Honest scope at small N (security-privacy-r3-01 / r2-03).** The `~N/2^k` anonymity-set argument is a
    *large-N* argument, and `k = MAILBOX_ROUTE_PREFIX_BYTES` (16 bits) is a **compile-time constant, NOT
    adaptive to observed N**. Below ~`2^k` (~65k) reachable addresses in the observed region, a target's
    prefix bucket is almost always occupied by the target ALONE, so against an **address-knower** who
    computes the target's route and watches that bucket in a region, the "anonymity set" is effectively a
    set of one: seeing the bucket active is, with near-certainty, a per-address reachability disclosure
    ("this specific target is reachable here this epoch"). At the current fleet scale (single-digit to a
    few hundred devices) the fixed 2-byte prefix therefore provides **no meaningful sender/recipient
    anonymity against an address-knower**; its only role at that scale is to keep routing buckets from
    being unique KEYS on the wire (so a *passive* indexer without the address still can't derive it). The
    real fix is to widen `k` adaptively as observed reachable-N grows (so `~N/2^k` stays >= a target set
    size). That is **wire-affecting** (the private header carries this prefix, so its width is part of the
    format) and is deliberately deferred + tracked as future work, not shipped in this hardening pass.
    Mirrored at `crypto.rs` `MAILBOX_ROUTE_PREFIX_BYTES` so the caveat lives with the constant too.
- **Mobility → flood.** Move faster than your beacon refresh and gradients go stale; you degrade to
  flood (the safety net), less efficient but still delivered.

None are fatal; the latency, linkability, and mobility costs are inherent to (privacy + DTN + dormancy),
exactly what Hop's thesis signs up for. (Operational flood-alerting can come later.)

### Worked scenarios

1. **Alice → Bob, private, Bob beaconing.** Bob's beacon has laid a gradient for his prefix across his
   reachable mesh and (via gateways) the awake backbone. Alice seals to Bob, stamps the ephemeral tag
   (+ mailbox-tag + hint), and her node forwards it **down the gradient**, directed, no flood. Bob
   recognizes it by ephemeral tag, opens it, authenticates Alice from the session. Relays saw a
   direction for a prefix, never Alice or Bob. The ACK rides Bob→Alice's gradient back.
2. **Bob offline, in another (dormant) region.** No live gradient → Alice's bundle holds in her region's
   durable spool, epidemic-spreads to co-awake regions over time. Bob comes online → anycast wakes his
   region → it reconciles the pending set from the awake backbone → Bob's fresh beacon drains it the
   last hops to him. Slower, certain, and no region was woken to push.
3. **Alice opts into trace.** Cleartext `Device(Bob)` + growing `trace`: relays spray-and-wait toward
   Bob and record each hop; Alice watches the path and a live "delivered." Faster and visible, and
   on-path relays now see Alice→Bob. Her choice, that message only.

### Why this is best-effort flood-containment, not a global epidemic

Privacy (hide dst) and routing (need dst) are opposed; the model makes **privacy the default** and gives
efficiency back as **opt-in dials** (the hint's `k`, full trace), while several bounds compound to keep
even the private default from going global:

1. **Physical scoping (free):** a BLE/LAN flood reaches only the physical connected component.
2. **Gradient-first, not flood-first:** with a live gradient there is no flood at all, directed
   forwarding; flood is only the bootstrap/fallback.
3. **No relay push-down:** relays never push-flood private bundles into device meshes.
4. **Lazy, awake-only backbone epidemic:** `O(diff)` reconciliation among awake regions; dormant
   regions catch up on wake, no per-message global push, no wake-churn.
5. **The `k`-bit hint:** caps holders to ~`N/2^k` and sharpens the gradient.
6. **Hard caps:** `lifetime`, `hop_limit`, spray budget `L`, dedup-by-`BundleId` (§5/§6/§7).
7. **Opt-in trace** for the efficient targeted gear.
8. **Keyed/metered backbone (§35)** bounds a node trying to flood globally.

Best-effort, not a hard guarantee, a leaderless privacy mesh can't promise a global bound, but the
common case is gradient-directed and physically small, and the cross-region case is eventual and capped,
never a global push.

### Delivery vaccine: epidemic recovery on delivery

A private bundle can be sprayed to several holders, so once the recipient has it, its remaining copies
are dead weight. The recipient (or the delivering relay on its behalf) floods a `Destination::Vaccine`
carrying **only the recognition_token** (sec-priv-07: NO plaintext delivered id). The token is the
recipient's revealed DH from the recognition tag: a holder recovers which of its held private bundles the
vaccine clears by testing `recognition_tag_from_shared(token, held_id) == held_tag` over the bundles it
holds, then drops the match. The token identifies no one (CDH: only the recipient could produce it, and
it reveals nothing about which node did). The vaccine id is deterministic (`BLAKE3("hop vaccine id v2" ‖
token)`), so every vaccine for one delivery dedups to a single flood, it self-verifies (a tampered token
yields a different id and is rejected), and it carries no src/dst/sig. This is the §6/§7 anti-packet,
specialized for the private path.

**Why token-only (sec-priv-07):** the old wire flooded the plaintext `delivered_id`, which named the
exact bundle to *anyone*, including an observer that never saw the original flood (a late joiner, a
global relay log). Dropping the id means such a non-capturing observer learns nothing but an opaque
32-byte token with no bundle to bind it to. Residual (documented, intrinsic): an observer that *did*
capture the specific flood already holds that bundle's public `(id, tag)`, and the recognition function
is public, so it can still confirm delivery via the revealed token. Closing that too would require the
recognition tag itself to be non-publicly-reopenable, which would break the recipient's own "is this
mine?" test; for a self-verifying epidemic anti-packet this is the floor. It leaks a delivery *event*,
never identity.

**Private delivery-ACK proof (core-protocol-r2-04, the v3->v4 wire driver):** the private `Payload::Ack`
now carries a recipient-only `proof: Option<[u8; 32]>`. On a private ACK the proof is
`recognition_shared(recipient_spk_secret, original.ephemeral)`, the SAME CDH value the delivery vaccine
reveals, so ONLY the bundle's true recipient (who holds the SPK secret) can produce it. The sender, still
holding the original private bundle, accepts the ACK as Delivered iff
`recognition_tag_from_shared(proof, for_bundle_id) == original.private.tag`. This closes an ACK-forgery
hole: a private bundle is sealed to the sender's *public* address and its recognition tag keys on the
sender's *published* SPK public, so before the proof anyone who learned the sender's address and guessed
an in-flight `for_bundle_id` could flood a bare private ACK and forge a Delivered. The proof is `None` on
the identity-signed **traced** ACK path (there the Ed25519 signature already authenticates the acker).
Because `Ack` rides inside the seal and this appends a trailing `Option` field, it is a genuine
struct-layout change: `BUNDLE_VERSION` bumped 3->4 and the version gate rejects a mixed v3/v4 fleet
rather than let a v3 unproven ACK be silently trusted, or a v4 proof be misparsed by a v3 sender.

**Status: SHIPPED (P1-P5, fleet-verified).** New wire pieces: the private header variant (ephemeral
recognition tag + `g^e`, plus the optional 2-byte mailbox **routing prefix** `MailboxRoute`; no
src/dst/sig and no separate `k`-bit hint field, since the prefix *is* the gradient hint), the recipient-
only CDH `proof` on the private `Payload::Ack` (v4), the ephemeral-tag and
mailbox-tag KDFs, the **signed beacon** + reverse-path token + per-node gradient table (soft state),
the blind regional spool, and the want-beacon pull path: a recipient floods a signed
`AdvertKind::RecvBeacon` a few hops; a node that newly accepts it queues that mailbox-tag, and the
host drains it (`take_wanted_mailboxes`) and reloads the mailbox's durable blind spool. (This replaced
the removed `InternetEgress` pull verb.) Reuses: `Broadcast` flood + BundleId dedup (§5/§7),
`topic_tag` recognition (§32), X3DH prekeys (§25), the §27 trace machinery (now opt-in), demand-summoned
regions (§28), regional spools + online-only relay epidemic (§28/§34), and §38 RBSR for cross-region
catch-up. Supersedes the §10 metadata-privacy non-goal for unicast content; keeps §28's regional DBs
unchanged (no global/continental store).

## 40. OTel-over-Hop, telemetry that rides the mesh to a collector

Observability is a paid surface (§37), but there is a hard constraint the transport has to respect:
**pure-P2P traffic never touches a server**, so the only telemetry a collector can ever see is what a
device chooses to self-report. And the devices that most need Hop are exactly the ones with no internet
to POST OTLP over. So telemetry itself has to be a first-class Hop payload: an OpenTelemetry-shaped
batch carried as an addressed, sealed bundle to a collector, not OTLP-over-HTTP.

**Wire.** A telemetry batch rides the built-in `hop.telemetry` service (a `ServiceRequest` whose `args`
are a postcard-encoded `TelemetryBatch`). Because `args` is an opaque `Vec<u8>`, this adds **no new
`Payload`/`Destination` variant and does not bump `BUNDLE_VERSION`**. Like every addressed service it is
**statically sealed to the collector's key** (§29), not ratcheted: it is data *about* the app, not user
content, so the static-seal class is the correct one. If any telemetry field were sensitive user content
it must instead be carried as a ratcheted `PeerMessage` (the §29 boundary).

**Delay tolerance is the whole point.** The batch is an ordinary bundle: if the collector is unreachable
it spools and delivers when a path opens (§28/§34), so a field device that was offline for hours still
lands its telemetry once it comes back into range. This is what makes P2P observability possible at all.

**Model (`core/hop-core/src/telemetry.rs`).** `TelemetryBatch { resource, records }` maps 1:1 onto OTLP:
`resource` is an OTLP Resource (coarse, opt-in labels such as `platform`, `app`, `region`), and each
`Record { signal, name, value, unit, attrs, time_ms }` is a metric point or log record. `Signal` is
`Counter` (OTLP Sum), `Gauge`, or `Event` (LogRecord). `value` is a **fixed-point integer** so the wire
is byte-identical across every SDK (no cross-language float wobble); the collector scales by `unit`.

**Bounds.** Decode enforces `MAX_RECORDS` / `MAX_ATTRS` / `MAX_STR`; a malformed or oversized batch is
dropped rather than trusted, so a device cannot shape telemetry into a collector-side DoS.

**Receive + meter.** The receiving node decodes `hop.telemetry` as a built-in and surfaces the typed,
bounds-checked batch via `Node::take_telemetry`; it is one-way (no service response). A collector (a node
that serves a reach record per §30 and drains `take_telemetry`) forwards each batch to an OTel collector
or a warehouse, and meters `batch.billable_events()` (the record count) to the `hop_telemetry_events`
observability dimension (§37). Metrics therefore carry their own COGS on their own meter, never folded
into a per-device fee.

**Privacy.** Resource and record labels are opt-in and coarse by construction and must stay
user-anonymous; the collector sees per-app aggregates, never a per-user identity. `region` is only ever
knowable for relay-carried or self-reported traffic, consistent with §39: the backbone does not learn a
pure-P2P device's location, the device discloses a coarse label or nothing.
