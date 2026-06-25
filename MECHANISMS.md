# Hop mechanisms — what's in the protocol and what's the host's

A living catalog of every mechanism Hop uses, split by whether it's **in protocol** (defined in
`hop-core`: a wire format, cross-platform, identical on every device and the relay) or **out of
protocol** (a host/app convention: swappable per app, never on the wire as a contract). The line
matters because anything in-protocol must stay wire-compatible across iOS, Android, the relay, and
a future WASM/ESP32 node; anything out-of-protocol can change per host without breaking interop.

The transport seam is the dividing line: `hop-core` only ever sees opaque `LinkId`s via
`connected(link, role)` / `received(link, bytes)` / `drain_outgoing() -> [(link, bytes)]` /
`disconnected(link)`. Everything below the seam is the protocol; the radios are above it.

## In protocol (`hop-core`)

| Mechanism | What it is | Wire surface |
|---|---|---|
| **Bundles** | the unit: self-contained, content-addressed (`blake3(src‖nonce‖payload)`), with src/dst, flags, copy budget, provenance trace | `Bundle`, `BundleEnvelope` |
| **Link encryption** | per-link **Noise XX** channel — mutual auth, so each side learns the other's static key (= address) | wire `LinkPacket::{Handshake,Data}` |
| **Routing** | binary spray-and-wait: epidemic flood with copy budgets, custody (forward-before-evict), dedup (`seen`), delivery-ACK vaccine | — |
| **Discovery / directory** | signed adverts, gossiped + deduped, superseded by `(publisher, seq)`, app-scoped (§17); offered on link-up and re-gossiped every 12s | `AdvertKind::Service`, `PreKey`, `Tombstone`, `HpsTopic` |
| **E2E sessions** | per-peer **Double Ratchet** (forward secret), keyed by address, bootstrapped from a prekey; content is *always* ratcheted (require-ratchet — never static-sealed device-to-device) | `SessionInit`, `SessionMessage` |
| **Messaging** | sealed device-to-device content + delivery receipt | `PeerMessage`, `Ack` |
| **Large transfers** | carrier chunking/reassembly with per-chunk acks (§20) | `StreamOpen/Data/Ack/Close`, `Carrier` |
| **Service RPC (§29)** | sealed point-to-point request/response. **`identify` lives here** (resolve a peer's name); also custom services + the hops:// transport | `ServiceRequest`, `ServiceResponse` |
| **hps:// pub/sub (§32)** | channels (anyone writes) / services (owner broadcasts) with a per-topic **content key**, **access modes** (Open / RequestToJoin / Invite), **visibility**, per-message signature, and forward-rotation **revocation** | `HpsJoinRequest/Invite/InviteAccept/Leave/Rekey/Keys/ReachAck/Publish` + `AdvertKind::HpsTopic` |
| **HNS / hops:// (§30)** | DNSSEC-validated naming → resolve a domain to a Hop address; fetch web resources over the mesh | `HnsQuery/Answer`, `HttpRequest/HttpResponse` |
| **App isolation (§17)** | `AppKeys = id ‖ disc_key ‖ mac_key`, all `blake3::derive_key` of a 32-byte app secret; `FABRIC_APP` is the open shared lane (prekeys/peer-discovery flood it) | stamped `AppId` on adverts/bundles |
| **Provenance (§27)** | per-hop stamp `{node: ShortAddr, app: ShortApp}`; device hops now stamp a **zeroed** address (anonymous), infra relays self-identify | trace in the envelope |
| **Persistence seam** | `Store` trait — bundle ops (`put/get/remove/seen/have/prune`) + KV (`put_kv/get_kv/list_kv`); host supplies the impl | — |

### Sealed primitives in-core (pick the right one)
- **`seal(to_address)` / `open`** — anonymous sealed-box to an address. No forward secrecy; sender not revealed. One recipient.
- **Double Ratchet `encrypt/decrypt`** — forward-secret, per-peer. One recipient, ongoing conversation.
- **hps `content_key`** — per-topic symmetric key. **Group broadcast** to everyone who holds the key (the "prebaked service key").
- **`disc_key`** — encrypts hps discovery-advert bodies. Per-**app** (all same-secret devices), not per-contact.
- **`mac_key`** — keyed-blake3 join proofs (proof-of-app-secret on hps joins).

## Out of protocol (host / app)

- **Bearers** — BLE (GATT + L2CAP + iBeacon wake), LAN (mDNS + TCP), Wi-Fi Direct, MultipeerConnectivity, relay TCP/WS. Link-id assignment, the gentle push-to-peripheral central, scanning cadence. The core only sees `LinkId`s.
- **"presence"** — a *convention*, not a protocol feature: the topic name `"presence"`, the `fg|ios|HopDemo` meta string, the publish cadence, the private-mode toggle. The core only provides the generic `Service` advert; choosing to call one "presence" is the app's.
- **Address book / contacts** (`contacts.json`), **message history** (`messages.json`), threads, delivery UI, `SendingIndicator`.
- **QR identity exchange** — out-of-band handoff of `"<base58>|<name>"`; just calls `addContact`.
- **Identity seed + display-name string + app-secret value** — host supplies the 32-byte seed (→ keypair), the name (→ `identify`), and the app secret (→ `AppKeys`).
- **Multipart framing** (`[u32 count][parts]`), image downscale, notifications/badges, background scheduling (BGTask / beacon region / state restoration).

## Privacy / identity roadmap

The principle: **identity is opt-in; everything else carries you anonymously.** Relay never needs
to know who you are — it floods on the bundle's sealed destination. Status:

1. **Private-mode toggle** — DONE. Stops broadcasting the `presence` advert; you stay relay-capable + reachable by anyone who has your address.
2. **Anonymized provenance** — DONE. Device hops stamp a zeroed address; recipient sees count + "device"/"Hop Relay" type, never which devices.
3. **Anonymous links (Noise XX → NN)** — TODO. Switch the link handshake to ephemeral-only so a neighbour no longer learns your address just by connecting. Reworks: `Established.peer` becomes optional; the direct-delivery shortcut + `peer_links` attribution + connect-time address verify go best-effort; an **opt-in signed identity record** sent over the link re-enables them for peers who want to be known (debug default: send it). E2E ratchet/messaging untouched.
4. **Identity as a sealed mechanism (two complementary options):**
   - **(a) presence-over-hps** — re-home presence onto an hps **Invite service** with a content key. Your name/address advert is encrypted to a key you share only with contacts → discoverable to your circle, invisible to strangers, still anonymous-relay for everyone. Reuses §32 wholesale.
   - **(b) HNS-backed identity at `id.hopme.sh`** — publish a **DNSSEC-secured record at `<name>.id.hopme.sh`** mapping a claimed name → Hop address (and optionally prekey), with a **very long TTL** (identity is stable, so cache it for ~days). Resolving someone = an HNS lookup over §30 (works over the internet *or* over the mesh), DNSSEC-validated so a name can't be spoofed. "Backed" = a small service writes the record when a device claims a name. This gives **authoritative, cacheable, infra-anchored identity without flooding presence** — and `identify` (§29) already covers the sealed on-demand "who are you?" between two reachable nodes. Needs: the `id.hopme.sh` DNSSEC zone + a claim/write service (infra), plus an app "add by name" that resolves via the existing HNS path. (a) and (b) compose: (a) = private discovery within a circle; (b) = a public, verifiable handle you can hand out.

`identify` (§29) is already private (sealed, on-demand, you choose to answer), so the work is on
**presence/discovery**, not on-demand resolution.
