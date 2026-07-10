# Hop mechanisms, what's in the protocol and what's the host's

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
| **Bundles** | the unit: self-contained, content-addressed. TRACED bundles carry `src`/`dst`, flags, copy budget, provenance trace. The DEFAULT send is now **untraceable** (§39): a `PrivateHeader` bundle with **zeroed src**, `dst = Broadcast`, **no identity signature**, and `id = blake3("hop private bundle id v1"‖ephemeral_pub‖nonce‖ciphertext)` (DESIGN.md:197). Wire version is `bundle.rs BUNDLE_VERSION` (currently 4; append-only, bumped on any Destination/kind change). | `Bundle`, `Envelope`, `SignedInner`, `PrivateHeader` |
| **Untraceable delivery (§39, SHIPPED)** | untraceable-by-default. `PrivateHeader{tag, ephemeral, mailbox, hint}`: **recognition tag** `KDF(ephemeral·SPK, id)` (recipient recognizes as-it-floods, ephemeral per message so two bundles don't correlate); **mailbox-tag** `blake3::derive_key("hop mailbox tag v2", address‖epoch)`, a per-epoch rotating pull pseudonym (crypto.rs `mailbox_tag`). Routing/spool/want-beacon key on only its **`MAILBOX_ROUTE_PREFIX_BYTES` (2-byte / 16-bit) prefix** (`crypto::mailbox_route`, sec-priv-04): an address-knower gets an anonymity SET, not a unique confirmation, and colliding recipients are separated by the per-message-ephemeral recognition tag. **receiver-beacon** gradient (P4) + **want-beacon / blind-spool pull** (P5). Beacon mailbox is bound to the publisher's signed address+epoch at ingest, so it can't be hijacked (F-05). | `PrivateHeader`, `AdvertKind::RecvBeacon`, `Payload::Private` |
| **Link encryption** | per-link **Noise XX** channel, mutual auth, so each side learns the other's static key (= address) | wire `LinkPacket::{Handshake,Data}` |
| **Routing** | binary spray-and-wait: epidemic flood with copy budgets, custody (forward-before-evict), dedup (`seen`), delivery-ACK vaccine. The vaccine rides `Destination::Vaccine([u8;32])`, the token ONLY (sec-priv-07: no plaintext delivered id): a self-verifying flood (id = `blake3("hop vaccine id v2"‖token)`, no src/dst/sig) that lets holders confirm-and-drop a delivered bundle by testing the token against their held private bundles (§39) | `Destination::{Device,AckTo,Broadcast,Vaccine}` |
| **Discovery / directory** | signed adverts, gossiped + deduped, superseded by `(publisher, seq)`, app-scoped (§17); offered on link-up and re-gossiped every 12s | `AdvertKind::Service`, `PreKey`, `Tombstone`, `HpsTopic` |
| **E2E sessions** | per-peer **Double Ratchet** (forward secret), keyed by address, bootstrapped from a prekey; content is *always* ratcheted (require-ratchet, never static-sealed device-to-device) | `SessionInit`, `SessionMessage` |
| **Messaging** | sealed device-to-device content + delivery receipt | `PeerMessage`, `Ack` |
| **Large transfers** | carrier chunking/reassembly with per-chunk acks (§20) | `StreamOpen/Data/Ack/Close`, `Carrier` |
| **Service RPC (§29)** | sealed point-to-point request/response. **`identify` lives here** (resolve a peer's name); also custom services + the hops:// transport | `ServiceRequest`, `ServiceResponse` |
| **hps:// pub/sub (§32)** | channels (anyone writes) / services (owner broadcasts) with a per-topic **content key**, **access modes** (Open / RequestToJoin / Invite), **visibility**, per-message signature, and forward-rotation **revocation** | `HpsJoinRequest/Invite/InviteAccept/Leave/Rekey/Keys/ReachAck/Publish` + `AdvertKind::HpsTopic` |
| **HNS / hops:// (§30)** | DNSSEC-validated naming → resolve a domain to a Hop address; fetch web resources over the mesh | `HnsQuery/Answer`, `HttpRequest/HttpResponse` |
| **App isolation (§17)** | `AppKeys = id ‖ disc_key ‖ mac_key`, all `blake3::derive_key` of a 32-byte app secret; `FABRIC_APP` is the open shared lane (prekeys/peer-discovery flood it) | stamped `AppId` on adverts/bundles |
| **Provenance (§27)** | per-hop stamp `{node: ShortAddr, app: ShortApp}`; device hops now stamp a **zeroed** address (anonymous), infra relays self-identify | trace in the envelope |
| **Persistence seam** | `Store` trait, bundle ops (`put/get/remove/seen/have/prune`) + KV (`put_kv/get_kv/list_kv`); host supplies the impl |, |

### Sealed primitives in-core (pick the right one)
- **`seal(to_address)` / `open`**, anonymous sealed-box to an address. No forward secrecy; sender not revealed. One recipient.
- **Double Ratchet `encrypt/decrypt`**, forward-secret, per-peer. One recipient, ongoing conversation.
- **hps `content_key`**, per-topic symmetric key. **Group broadcast** to everyone who holds the key (the "prebaked service key").
- **`disc_key`**, encrypts hps discovery-advert bodies. Per-**app** (all same-secret devices), not per-contact.
- **`mac_key`**, keyed-blake3 join proofs (proof-of-app-secret on hps joins).

## Out of protocol (host / app)

- **Bearers**, three extracted per-bearer SwiftPM/Gradle packages, BLE (GATT + L2CAP + iBeacon wake), LAN (mDNS + TCP), and relay TCP/WS. **MultipeerConnectivity (Apple Wi-Fi P2P)** is a live transport too, but it is retained IN-DRIVER (never extracted behind the shared Bearer contract, no `HopBearerMultipeer` package), so it is an iOS-only in-driver bearer, not one of the three packages. (Wi-Fi Direct was removed, commit c059d69, its per-device approval dialog breaks the passive/no-pairing principle.) Link-id assignment, the gentle push-to-peripheral central, scanning cadence. The core only sees `LinkId`s.
- **"presence"**, a *convention*, not a protocol feature: the topic name `"presence"`, the `fg|ios|HopDemo` meta string, the publish cadence, the private-mode toggle. The core only provides the generic `Service` advert; choosing to call one "presence" is the app's.
- **Address book / contacts** (`contacts.json`), **message history** (`messages.json`), threads, delivery UI, `SendingIndicator`.
- **QR identity exchange**, out-of-band handoff of `"<base58>|<name>"`; just calls `addContact`.
- **Identity seed + display-name string + app-secret value**, host supplies the 32-byte seed (→ keypair), the name (→ `identify`), and the app secret (→ `AppKeys`).
- **Multipart framing** (`[u32 count][parts]`), image downscale, notifications/badges, background scheduling (BGTask / beacon region / state restoration).

## Privacy / identity roadmap

The principle: **identity is opt-in; everything else carries you anonymously.** Relay never needs
to know who you are, it floods on the bundle's sealed destination. Status:

0. **Untraceable-by-default messaging (§39)**, SHIPPED. The default send is a `PrivateHeader` bundle (zeroed src, no signature) recognized by tag; per-epoch rotating mailbox-tags; receiver-beacon gradient + blind-spool pull. See the §39 rows above.
1. **Private-mode toggle**, DONE. Stops broadcasting the `presence` advert; you stay relay-capable + reachable by anyone who has your address.
2. **Anonymized provenance**, DONE. Device hops stamp a zeroed address; recipient sees count + "device"/"Hop Relay" type, never which devices.
3. **Anonymous links (Noise XX → NN)**, ATTEMPTED & REVERTED. Switching the link handshake to ephemeral-only passed in-memory but broke messaging on real BLE (apps key liveness off link-count and assume every link yields an identified peer), so it was reverted (only an auto-heal fix was kept). Revisit only with a real per-link identity story: make `Established.peer` optional + an **opt-in signed identity record** over the link, and fix the app assumptions first. E2E ratchet/messaging untouched by the design.
4. **Identity as a sealed mechanism (two complementary options):**
   - **(a) presence-over-hps**, re-home presence onto an hps **Invite service** with a content key. Your name/address advert is encrypted to a key you share only with contacts → discoverable to your circle, invisible to strangers, still anonymous-relay for everyone. Reuses §32 wholesale.
   - **(b) HNS-backed identity at `id.hopme.sh`**, publish a **DNSSEC-secured record at `<name>.id.hopme.sh`** mapping a claimed name → Hop address (and optionally prekey), with a **very long TTL** (identity is stable, so cache it for ~days). Resolving someone = an HNS lookup over §30 (works over the internet *or* over the mesh), DNSSEC-validated so a name can't be spoofed. "Backed" = a small service writes the record when a device claims a name. This gives **authoritative, cacheable, infra-anchored identity without flooding presence**, and `identify` (§29) already covers the sealed on-demand "who are you?" between two reachable nodes. Needs: the `id.hopme.sh` DNSSEC zone + a claim/write service (infra), plus an app "add by name" that resolves via the existing HNS path. (a) and (b) compose: (a) = private discovery within a circle; (b) = a public, verifiable handle you can hand out.

`identify` (§29) is already private (sealed, on-demand, you choose to answer), so the work is on
**presence/discovery**, not on-demand resolution.
