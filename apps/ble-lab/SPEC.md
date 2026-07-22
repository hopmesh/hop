# HOP BLE LAB, Canonical Dual-Role BLE Transport (Proof of Pipe)

> **Charter.** ble-lab is the clean-room repro rig for advertiser / link-formation wedges and the
> iOS L2CAP teardown, not a production bearer. It carries only BLE and LAN; Wi-Fi Direct was removed
> (commit c059d69) to match production. Production `bearers/` is the source of truth when the two
> diverge.

> **Status:** buildable specification. No further decisions required. Hardened against an adversarial
> review (R1 to R11); resolutions catalogued in **Appendix C**.
> **Goal:** two symmetric dual-role devices, Android (Kotlin) and Apple (Swift / CoreBluetooth),
> converge on **exactly one** reliable bidirectional L2CAP byte channel, keep it alive forever
> across drops, BLE address rotation, and repeated meet/part cycles. Cross-platform **Android↔Apple
> is the bar**; same-platform is table stakes. Prove the pipe: a 1 Hz monotonic counter that the
> peer's stream must advance with **no loss and no stall**, indefinitely.
>
> This document is the synthesis of three independent designs (`designs/reliability-first.md`,
> `designs/convergence-first.md`, `designs/platform-native.md`). Every conflict is resolved below
> with explicit engineering reasoning, grounded in current platform behavior (sources at the
> bottom) and this repo's own field evidence (`hopmac`, `HopLink.kt`, `GattDataLink.kt`, and the
> `ble-bearer-pure-l2cap-no-gatt` / `cross-platform-ble` memory notes). Field-verified facts are
> tagged **[field]**.

---

## 0. Architecture in one paragraph + the decisions that produced it

Every device runs identical, role-symmetric software and is **simultaneously** a BLE **peripheral**
(advertises the service, runs a GATT server with one read characteristic, hosts an L2CAP CoC
listener with a session-stable PSM) **and** a BLE **central** (one persistent service-filtered scan,
GATT client, L2CAP dialer). **All data flows over an insecure L2CAP connection-oriented channel
(CoC); data NEVER rides GATT.** GATT exists only for a single read that returns `[2B PSM][16B
nodeId]`, that read is also what primes Android's L2CAP accept path. Convergence to exactly one
channel is driven by an **ephemeral random 16-byte `nodeId`** carried in-band (a 6-byte prefix in
the advert as an accelerator; the full 16 bytes authoritatively in the L2CAP `HELLO`). Reliability
is an **app-layer 1 Hz PING** (which *is* the proof counter), an **adaptive** liveness watchdog
(5 s foreground / 15 s background), a 3 s half-open reaper, and a per-peer reconnect state machine
**keyed by the stable nodeId prefix, never by MAC/identifier** (which rotate).

### 0.1 What was grafted from each design, and why

| Decision | Chosen | Source | Why this side won |
|---|---|---|---|
| Data substrate | **Insecure L2CAP CoC**, GATT only for the PSM/nodeId read | all three | CoC is the only cross-platform connection-oriented byte stream that carries a 64 KB frame at interactive latency with credit-based flow control; secure CoC needs bonding (forbidden) and fails iOS↔Android. |
| GATT shape | **One characteristic, READ-only → `[2B PSM][16B nodeId]`** | reliability-first | The post-`HELLO` dedup model (below) means the peripheral does **not** need the central's nodeId before L2CAP, so convergence-first's extra GATT **WRITE** is removed (fewer round-trips, fewer 133s). Merging PSM+nodeId into one read drops platform-native's second characteristic. Minimal GATT also avoids the "over-built GATT stalls the PSM read" failure **[field]**. |
| Convergence model | **Post-`HELLO` dedup is authoritative; pre-connect tiebreaker is an accelerator; wait-timeout breaks deadlocks** | reliability-first + platform-native | Convergence-first's *strict* "acceptor never dials, channel is always greater→lesser" model **deadlocks** when the assigned dialer cannot see the assigned acceptor, exactly the required case of a backgrounded iOS peripheral (invisible to Android). Post-`HELLO` dedup is correct no matter which side dialed. |
| Tiebreaker direction | **Greater `nodeId` dials (initiator)** | convergence-first + platform-native (2 of 3) | Direction is arbitrary (both unbiased); pick the majority for consistency. Bound to BLE's central-opens asymmetry so the keeper is unambiguous. |
| nodeId size | **16 bytes (128-bit)** | reliability-first + convergence-first | Collision resistance is free; 128-bit is the conventional random id. 6-byte prefix still fits the advert. |
| Advert nodeId location | **6-byte prefix in the PRIMARY advert mfg data** (company `0xFFFF`) | reliability-first | Available on every *passive* scan hit (no scan-response round-trip), unlike platform-native's scan-response placement. It is an accelerator only; see §1.3. The prefix is **invariant across RPA rotation** (app-level, not the MAC), which makes it the correct rate-limit key (§6). |
| Keepalive / proof | **1 Hz PING = the proof counter** | reliability-first + convergence-first | The problem statement mandates a 1 s counter; unifying it with the keepalive means no idle channel ever exists. Overrides platform-native's 4 s keepalive. |
| Liveness threshold | **Adaptive: 5000 ms foreground, 15000 ms background, floored at 3× observed inter-arrival** | reliability-first + R7 | 5 s foreground is fast ("seconds, not Android's ~20 s") yet rides a brief radio stall without flapping. But iOS **relaxes the connection interval in background** toward the peripheral's slowest preferred value (hundreds of ms up to ~1 to 2 s), so a fixed 5 s deadline false-trips a healthy backgrounded link. The deadline therefore widens in background and adapts to the observed PONG cadence. |
| Half-open reaper | **3000 ms** | reliability-first | Kills the classic orphan (Android `accept()` succeeded, central abandoned its end) before it eats Android's concurrent-channel cap **[field]**. |
| iOS service discovery | **`discoverServices(nil)`** (discover all) | reliability-first | Targeted `discoverServices([SERVICE])` *stalls* against Android's GATT server; full discovery (what LightBlue does) succeeds **[field]**. |
| Android scan | **One persistent scan, never restarted; LOW_LATENCY when 0 links, BALANCED when ≥1, with hysteresis + a sliding-window start guard** | reliability-first + convergence-first + R9 | Restart-per-meet trips Android's 5-starts/30 s throttle (silent dead scanner). Continuous LOW_LATENCY starves our own peripheral role **[field]**. The 0↔1 downshift is debounced (≥10 s stability) and every `startScan` is gated to never be the 5th in any 30 s window. |
| GATT data fallback | **Specified as a documented drop-in (Appendix B), NOT in the core** | platform-native (demoted) | This lab's stated goal (`ble-bearer-pure-l2cap-no-gatt`) is reliable cross-platform L2CAP via the Ditto pattern; the GATT-first read is exactly what made L2CAP accept work. But the repo has burned on this assumption (`GattDataLink.kt`), so the fallback is fully specified and reuses the same framing, drop-in if a target Android OEM truly refuses L2CAP. See §11. |

---

## 1. Identifiers, advertisement bytes, and the in-band tiebreaker

### 1.1 Fresh UUID scheme (assume nothing pre-existing)

```
SERVICE_UUID   = 7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F   // the dual-role service (advertised + GATT)
ENDPOINT_CHAR  = 7ED70002-3C2A-4F19-9B8E-1A2B3C4D5E6F   // GATT READ → [2B PSM BE][16B nodeId]
MFG_COMPANY_ID = 0xFFFF                                  // "reserved for testing" company id
L2CAP_ENCRYPT  = false                                  // INSECURE CoC, no bonding
```

### 1.2 The nodeId (the unbiased, in-band tiebreaker, NOT a MAC, NOT platform)

At process start each device generates a **random 16-byte `nodeId`** (CSPRNG). It is:
- **Stable for the entire process lifetime**, generated once at launch and **NOT re-rolled on a
  BT-adapter recycle** (R11). An adapter bounce is not a new identity; the session continues. The
  nodeId is a valid dedup/rate-limit key precisely *because* it is independent of the BLE MAC, which
  rotates underneath it. It is regenerated only on a full process restart.
- **Unbiased**: pure randomness; no platform tag, no hardware address, no RSSI, no power-on order.
- **In-band**: a 6-byte prefix in the advert; the full 16 bytes authoritatively in `HELLO`.

**Tiebreaker rule (one sentence):** *the channel that survives is the one dialed by the device with
the numerically GREATER `nodeId`* (unsigned, byte 0 most significant). Both ends compute this
identically from in-band data. Exact 16-byte tie (≈2⁻¹²⁸): both re-roll `nodeId` and re-advertise.

### 1.3 Advertisement layout: legacy 31-byte ADV_IND (exact bytes)

The primary advertising packet, exactly 31 bytes (no extended advertising needed):

```
02 01 06                                                 Flags: LE General Discoverable, BR/EDR not supported
11 07 6F 5E 4D 3C 2B 1A 8E 9B 19 4F 2A 3C 01 00 D7 7E    Complete 128-bit Service UUID (little-endian on air)
09 FF FF FF NN NN NN NN NN NN                            Manufacturer data: len=09, type=FF, company=FFFF(LE), 6-byte nodeId prefix
```

- `3 + 18 + 10 = 31` bytes exactly. The 128-bit UUID is little-endian on air; for
  `7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F` the on-air bytes are
  `6F 5E 4D 3C 2B 1A 8E 9B 19 4F 2A 3C 01 00 D7 7E`.
- `NN…` = the first 6 bytes of `nodeId` (== the first 6 bytes of the value returned by the GATT read,
  so the advert prefix and the post-connect nodeId join on the same key).
- **No device name** in the primary packet (it would overflow). A name may go in the scan response
  for debugging only; it is never load-bearing.

**Critical platform truth about the advert id [field + sources]:**
- **Android peripheral** advertises the 6-byte prefix fine. So in the dominant cross-platform
  topology (iOS-central → Android-peripheral) and Android↔Android, the pre-connect tiebreaker has
  its data and can suppress a redundant dial.
- **iOS/macOS peripherals cannot advertise manufacturer data at all.** CoreBluetooth's
  `startAdvertising` honors only `CBAdvertisementDataServiceUUIDsKey` and
  `CBAdvertisementDataLocalNameKey`. When an iOS app is **backgrounded**, the name is dropped and
  the service UUID moves into Apple's proprietary **overflow area** (a hashed bloom filter in mfg
  type `0xFF`) that **only another iOS device scanning that exact UUID can match**: Android cannot
  see a backgrounded iOS advertiser at all.

**Consequence (it shapes the whole convergence design):** the advert-borne id is an **accelerator**,
present only when the peer is an Android peripheral. The **authoritative** tiebreaker/dedup signal
is the 16-byte id in the L2CAP `HELLO`, which is **always** present. The protocol is correct using
`HELLO` alone; the advert id merely avoids a redundant dial in the common case.

---

## 2. Convergence engine: how two dual-role devices agree on ONE channel

Three cooperating mechanisms, in priority order. The first minimizes work; the last guarantees
correctness regardless of visibility asymmetry. **Live-link identity is keyed by the full 16-byte
`nodeId`; rate-limiting/backoff is keyed by the stable 6-byte nodeId prefix; transient pre-connect
guards are keyed by the current MAC/identifier, never anything by MAC alone for state that must
survive RPA rotation (§6).**

### 2.1 Pre-connect tiebreaker (fast path; needs the advert prefix)

When a central discovers a peer whose advert carries a `nodeId` prefix `P` (6 bytes), compare it to
the first 6 bytes of `myNodeId`:
- `myPrefix > P` → **I dial** (become the L2CAP initiator).
- `myPrefix < P` → **I wait** (the peer should dial me; my peripheral side is always up).
- `myPrefix == P` (6-byte collision, rare) → fall through to §2.3: both may dial; dedup resolves it
  from the full 16-byte ids in `HELLO`.

Before either branch, the central first checks **"do I already hold a live link to this peer?"** by
prefix (`haveLinkToPrefix(P)`); if so it does nothing (R4). This halves channel attempts in the
Android-peripheral case and is the primary defense against the concurrent-L2CAP exhaustion that
degrades a busy Android radio **[field]**.

### 2.2 Wait-timeout safety net (breaks visibility-asymmetry deadlocks)

The "waiter" from §2.1 starts a timer `T_wait = 4 s + rand(0…1 s)` when it first sees the peer.
**Exactly one** wait is outstanding per discovered peer (deduped by identifier, R4); repeated
`didDiscover`/`onScanResult` deliveries (which `allowDuplicates` and a persistent scan produce in
volume) do **not** stack multiple dials. When `T_wait` fires the waiter dials **only if it still does
not hold a live link to that peer**, tested against the **node-level link map by prefix**
(`haveLinkToPrefix`), **not** against the central's own in-flight/dial set, because in the dominant
case the link comes `UP` via our **acceptor** role, which never touches the central's dial state
(R4). If a link already exists, the wait is dropped.

This is what makes the design robust when the side that *should* dial **cannot see us**, e.g. a
backgrounded iOS peripheral whose advert is in the overflow area (Android never learns it should
dial). The waiter (here iOS-as-central, which *can* scan in background) takes over. **No platform
bias is encoded**; it is purely "if the assigned dialer didn't act, and I still have no link, I do."
A peer discovered with **no** advert prefix at all (an iOS peripheral) is dialed immediately (there
is nothing to compare).

### 2.3 Post-`HELLO` dedup (universal backstop; always correct)

Immediately after an L2CAP channel opens, **each** side sends one `HELLO` carrying its full 16-byte
`nodeId` and a role flag. The link is `UP` only once `HELLO` is **both sent and received**. If a
device ever holds **two** live channels to the same `peerNodeId`, it keeps exactly one, computed
identically on both ends:

```
Survivor = the channel dialed by the GREATER-nodeId node.
  if myId > peerId : keep MY dialed channel (isDialer == true),  close my accepted one.
  if myId < peerId : keep MY accepted channel (isDialer == false), close my dialed one.
```

Both ends know both ids, so both pick the same survivor, no negotiation, no livelock. A **single**
channel always survives regardless of who dialed it (the rule only adjudicates *two* channels to the
same peer). The map entry is set to the survivor **before** the redundant channel is closed, and the
close handler removes a peer only if the closing link is **still the current occupant** of the map
(identity check), so the dedup-close can never evict the healthy kept link (R3). Even if both sides
dialed (no advert prefix, or both safety-nets fired), the mesh collapses to one channel within ~1 s
and the redundant L2CAP is closed promptly (freeing Android's scarce concurrent-channel slot).

**Address rotation is transparent:** a new MAC + same `nodeId` while `UP` ⇒ ignore (already linked);
new MAC + same `nodeId` while `LOST` ⇒ normal re-establish. Rotation never produces a duplicate
because dedup is by `nodeId`.

---

## 3. The EXACT channel-open handshake (every call, in order, both sides, both platforms)

**DIALER** = the central the convergence engine selected (greater id, or the timed-out waiter).
**ACCEPTOR** = the peripheral. Every device runs both roles concurrently; a given *link* has one of
each end.

### 3.1 ACCEPTOR setup (done once at startup; kept alive for the whole session)

Keep the L2CAP listener and its PSM **stable for the session**: a fresh `listenUsing…`/`publish…`
mints a **new PSM** and strands any peer that cached the old one. Open it once; only re-open on
failure (and then invalidate the GATT cache, §7.4).

**iOS / macOS (CBPeripheralManager):**
1. `CBPeripheralManager(delegate:queue:options:[CBPeripheralManagerOptionRestoreIdentifierKey: "hop.ble.peripheral"])`.
   The `queue` is `.main` for the macOS CLI; on the iOS **app** target it is a dedicated serial
   dispatch queue (§7.5 / §8.1, R8).
2. `peripheralManagerDidUpdateState` → `.poweredOn`:
3. `let ch = CBMutableCharacteristic(type: ENDPOINT_CHAR, properties: .read, value: nil, permissions: .readable)`,
  **`value: nil` ⇒ dynamic read**, answered live in the delegate (so PSM is always current).
4. `let svc = CBMutableService(type: SERVICE_UUID, primary: true); svc.characteristics = [ch]; pm.add(svc)`
5. `pm.publishL2CAPChannel(withEncryption: false)`, **insecure**.
6. `peripheralManager(_:didPublishL2CAPChannel:error:)` → store `psm`.
7. `pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID]])` (no mfg data possible
   on iOS, §1.3). iOS publishes the L2CAP channel and registers the service synchronously enough
   that advertising-after-publish is safe; on `willRestoreState`, **re-add the service before
   re-advertising** (R10).
8. **On read:** `peripheralManager(_:didReceiveRead:)` → `request.value = psm(2B BE) || nodeId(16B)`;
   `pm.respond(to: request, withResult: .success)`.
9. **On inbound L2CAP:** `peripheralManager(_:didOpen channel:error:)` → wrap `channel.inputStream`/
   `outputStream`, schedule on the **BLE I/O run loop** (`.main` on the CLI; the dedicated I/O
   thread's run loop on the iOS app, §8.1), `open()`; send `HELLO`; start the 3 s half-open reaper;
   role = acceptor.

**Android (peripheral):**
1. `server = adapter.listenUsingInsecureL2capChannel(); val psm = server.psm` (LE-only CoC, no bonding).
2. One **session-long accept loop** on a worker thread: `while (true) { val sock = server.accept(); handleAccepted(sock) }`.
   Each socket → wrap `inputStream`/`outputStream`; send `HELLO`; start the 3 s reaper; role = acceptor.
3. GATT server: `gattServer = mgr.openGattServer(ctx, cb)`;
   `svc = BluetoothGattService(SERVICE_UUID, SERVICE_TYPE_PRIMARY)`;
   `svc.addCharacteristic(BluetoothGattCharacteristic(ENDPOINT_CHAR, PROPERTY_READ, PERMISSION_READ))`;
   `gattServer.addService(svc)`, **asynchronous**.
4. **Gate advertising on registration (R10):** start advertising **only from `onServiceAdded`**
   (status `GATT_SUCCESS`), never before, otherwise a fast iOS central can connect and discover
   *no* service, fail, and back off on first contact.
5. **On read:** `onCharacteristicReadRequest` → `gattServer.sendResponse(device, requestId, GATT_SUCCESS, 0, psm(2B BE) || nodeId(16B))`.
6. Advertise via `startAdvertisingSet` in **legacy mode** (§7.1): service UUID + 6-byte prefix in mfg
   data; idempotent self-heal from the tick loop.

### 3.2 DIALER open sequence

**iOS / macOS (CBCentralManager):**
1. `CBCentralManager(delegate:queue:options:[CBCentralManagerOptionRestoreIdentifierKey: "hop.ble.central"])`
   (queue: `.main` on CLI; dedicated serial queue on the iOS app, §8.1).
2. `.poweredOn` → `scanForPeripherals(withServices: [SERVICE_UUID], options:[CBCentralManagerScanOptionAllowDuplicatesKey: true])`.
   **Service filter is mandatory for background scan**; `allowDuplicates` is honored in foreground
   (re-see a peer mid-restart) and silently ignored in background.
3. `centralManager(_:didDiscover:advertisementData:rssi:)` → parse the mfg prefix if present →
   check backoff (keyed by prefix, else identifier) → check `haveLinkToPrefix` → run §2. If we dial:
   **retain the `CBPeripheral` in a strong map** (else it deallocs and the connect silently dies),
   set `p.delegate = self`, `central.connect(p, options: nil)`, and **start a real 12 s dial-timeout
   (R6)**, on expiry call `cancelPeripheralConnection(p)` (CB's `connect` is otherwise an indefinite
   pending connect) and route into `reconnect`.
4. `centralManager(_:didConnect:)` → `p.discoverServices(nil)`. **Use `nil`, not `[SERVICE_UUID]`**:
   targeted discovery stalls against Android **[field]**.
5. `peripheral(_:didDiscoverServices:)` → find `SERVICE_UUID` → `p.discoverCharacteristics([ENDPOINT_CHAR], for: svc)`.
6. `peripheral(_:didDiscoverCharacteristicsFor:error:)` → `p.readValue(for: ch)`.
7. `peripheral(_:didUpdateValueFor:error:)` → parse `[2B PSM][16B peerNodeId]`; store `peerNodeId`.
   **If `haveLinkTo(peerNodeId)` (R4), meaning we already hold a live link to this exact node, cancel the
   connection and do NOT open a redundant CoC.** Otherwise promote the backoff key to the stable
   6-byte nodeId prefix and `p.openL2CAPChannel(psm)`.
8. `peripheral(_:didOpen channel:error:)`:
   - **error** ⇒ peer likely re-listened (stale PSM): drop cached PSM, `p.discoverServices(nil)` to
     re-read, or back off (§6).
   - **success** ⇒ cancel the dial-timeout, reset backoff, wrap streams, schedule on the BLE I/O run
     loop (§8.1), `open()`; send `HELLO`; start 1 Hz PING + adaptive liveness watchdog; role = dialer.

**Android (central):**
1. `scanner.startScan(listOf(ScanFilter.Builder().setServiceUuid(SERVICE_UUID).build()), settings, scanCb)`
   with one persistent scan (§7.3).
2. `onScanResult` → parse the mfg prefix → §2. If we dial AND `dialsInFlight < 2` AND not in
   prefix-keyed backoff AND not already linked to that prefix: `device.connectGatt(ctx,
   /*autoConnect=*/false, gattCb, TRANSPORT_LE)` **on the main thread** (off-thread connect is a
   frequent 133 cause **[field]**). Start a 12 s dial-timeout.
3. `onConnectionStateChange(STATE_CONNECTED)` → `gatt.requestConnectionPriority(CONNECTION_PRIORITY_HIGH)`
   then `gatt.discoverServices()`.
4. `onServicesDiscovered` → `gatt.getService(SERVICE_UUID).getCharacteristic(ENDPOINT_CHAR)` →
   `gatt.readCharacteristic(ch)`.
5. `onCharacteristicRead`, **override BOTH signatures (R1):** the 4-arg
   `onCharacteristicRead(gatt, char, value, status)` (added in **API 33**) **and** the deprecated
   3-arg `onCharacteristicRead(gatt, char, status)` (the **only** one invoked on API 29 to 32, which is
   the entire `minSdk 29` field below 33). Both route into one handler that parses
   `[2B PSM][16B peerNodeId]`. Without the 3-arg override the read callback **never fires** on
   Android 10/11/12 and cross-platform establishment is 0% there.
6. `val sock = device.createInsecureL2capChannel(psm)`; on a **worker thread** `sock.connect()`
   (blocking). Success → wrap streams; send `HELLO`; start 1 Hz PING + adaptive liveness;
   `gatt.requestConnectionPriority(CONNECTION_PRIORITY_BALANCED)` after `HELLO`; role = dialer.
7. **Any disconnect / failure / status-133** → `gatt.close()` **(mandatory, leaked GATT clients
   exhaust Android's cap and kill all future connects [field])**, free the dial slot, apply backoff.

### 3.3 The `HELLO` exchange (the moment a channel becomes a real link)

Each side sends one `HELLO` immediately after the channel opens and waits for the peer's. `UP` only
after `HELLO` is both sent and received. The acceptor's 3 s reaper closes any channel that never
delivers a `HELLO`, killing half-open orphans **[field]**.

```
HELLO body:  [0x01][16B nodeId][1B role: 0=acceptor 1=dialer][1B flags]
```

On receiving `HELLO`: record `peerNodeId`, run §2.3 dedup, transition to `UP`.

---

## 4. Data framing (identical on both platforms; carries the proof counter)

4-byte big-endian length prefix + body. Body byte 0 is the type. `len` covers the whole body
(type + payload). Matches this repo's proven `HopLink` framing, with a type byte added.

```
[len:u32 BE][ body (len bytes) ]
body = [type:u8][ payload ]
  0x01 HELLO : [16B nodeId][1B role][1B flags]
  0x02 PING  : [seq:u64 BE][t_send_ms:u64 BE]   // seq is the monotonic PROOF COUNTER (1 Hz)
  0x03 PONG  : [seq:u64 BE][t_send_ms:u64 BE]   // echoes a PING → RTT + reverse-direction liveness
  0x10 DATA  : [opaque upper-layer bytes]        // later: Noise handshake + messages
```

- **Readers** accumulate across reads and de-frame complete frames (handle multiple frames per read
  and a frame split across reads).
- **Writers** handle partial writes: buffer the tail, flush on "space available".
- A 64 KB `DATA` frame is one length-prefixed frame; L2CAP CoC fragments/reassembles the SDU
  transparently (negotiated MTU up to 64 KB+; iOS internally fragments above ~2 KB, invisibly).
- **Guards:** reject `len < 1` or `len > 4 MiB` (`MAX_FRAME`, matching the repo) and close, defends
  against a corrupt length.

---

## 5. Keepalive + liveness (fast, OS-independent, background-aware)

The keepalive **is** the proof, so no idle channel ever exists.

- **Send:** every **1000 ms** emit `PING` with `seq = ++txSeq`. The peer replies `PONG` (proves the
  reverse direction) and verifies `seq == lastRxSeq + 1`:
  - **any gap** ⇒ packet loss (logged, asserted in tests),
  - **stale `seq` too long** ⇒ stall (caught by the watchdog below).
  This is literally the spec's "monotonically increasing counter the peer's stream must advance with
  no loss or stall."
- **Liveness (primary detector), ADAPTIVE (R7):** track `lastRxMs` (any inbound frame). Declare the
  link **dead** when `now - lastRxMs` exceeds `DEAD = max(base, 3 × ewmaInterArrival)`, where
  `base = 5000 ms` in the **foreground** and `15000 ms` in the **background**, and
  `ewmaInterArrival` is an exponential moving average of inbound-frame gaps. This is the **only**
  detector that catches a *wedged-but-connected* channel (ACL alive, L2CAP stream stalled), the BLE
  supervision timeout will not. The background widening exists because **iOS relaxes the connection
  interval in background** (toward the peripheral's slowest preferred value, hundreds of ms up to
  ~1 to 2 s); a fixed 5 s deadline would false-trip a perfectly healthy backgrounded link, causing a
  reconnect storm that is itself slow in background. The app sets a single `appInBackground` flag
  from its lifecycle (`scenePhase`/`UIApplication` on iOS; foreground-service/CLI leave it `false`).
- **Liveness (secondary, fast path):** the OS disconnect callback (iOS `didDisconnectPeripheral` /
  Android `onConnectionStateChange(STATE_DISCONNECTED)`) and stream end/error events → immediate
  teardown.
- **Half-open reaper:** if a channel never delivers a `HELLO` within **3000 ms**, close it. (At
  connect time intervals are tight, so 3 s is safe even in background.)

Why 1 Hz / adaptive 5 to 15 s / 3 s: 1 Hz is mandated and keeps the iOS link warm (iOS tears down a
link silent for ~15 s, repo `HopLink` doc; 1 Hz is far safer than the proven 4 s). The adaptive
deadline recovers in seconds in the foreground without flapping a still-good link, and survives the
background connection-interval relaxation. 3 s reaps orphans before they exhaust Android's
concurrent-channel cap.

---

## 6. Reconnect / recovery state machine (per peer; rate-limited by the stable nodeId prefix)

```
          discover advert (service UUID seen)
   LOST ───────────────────────────────────────────► SEEN
    ▲                                                   │  §2: "I dial"  (greater id, or T_wait fired)
    │ advert gone > LOST_MS (30 s)                      ▼
    │                                            DIALING ──(GATT+PSM+L2CAP+HELLO ok)──► UP
    │                                                │                                   │
    │      dial-timeout(12s) / fail / status-133     │                                   │
    └──────────────── COOLDOWN ◄─────────────────────┘                                   │
                         ▲   │ backoff elapsed → SEEN/DIALING                             │
                         │   └─────────────────────────────────────────────────────────►│
                         │      watchdog OR OS disconnect OR dedup-close                  │
                         └────────────────────────────────────────────────────────────  ┘
```

- **Backoff keying, the correction (R2).** Backoff is **keyed by the stable 6-byte nodeId prefix**
  carried in the advert, which is **invariant across RPA rotation** (it is app-level, not the MAC).
  This makes a genuinely flapping/failing peer stay rate-limited even after it rotates its MAC,
  unlike the MAC/identifier, which for **non-bonded** peers is the rotating RPA on Android
  (`ScanResult.getDevice().getAddress()`) and a fresh `CBPeripheral.identifier` per RPA on iOS. The
  prefix is available at dial time (from the advert) **and** post-connect (the first 6 bytes of the
  nodeId read), so the two join cleanly. For peers that advertise **no** prefix (iOS peripherals seen
  by an Android/iOS central before the GATT read), backoff falls back to the per-session
  MAC/identifier as a best-effort guard, and is promoted to the nodeId prefix the instant the GATT
  read yields the full nodeId. A separate **MAC/identifier-keyed in-flight set** (short-lived,
  cleared on success/fail/timeout) prevents double-dialing the *same advertisement*. **All maps are
  TTL-bounded** (entries untouched for `LOST_MS = 30 s` are evicted) so rotation can never grow them
  unbounded. **Live-link identity remains keyed by the full 16-byte nodeId.**
- **Backoff schedule:** anti-flap ~1 s after any drop, then exponential 1→2→4→…→**30 s cap**, **+
  jitter**; reset to ~1 s after a link stayed `UP ≥ 30 s` (`stableUp`). Cheap fast recovery for
  transient drops; gentle on a genuinely absent/failing peer (so the central never storms
  `connectGatt`s that starve our own peripheral **[field]**).
- **Concurrency caps:** `MAX_DIALS_IN_FLIGHT = 2`; 12 s dial-timeout so one hung dial can't block
  progress; stagger dials. The §2 tiebreaker keeps steady state at exactly one channel per peer.
- **Adapter bounce / power state (R11):** **both platforms** proactively close all local links when
  the adapter powers off (iOS `didUpdateState .poweredOff`; Android `STATE_OFF` via the
  `ACTION_STATE_CHANGED` `BroadcastReceiver`), so the peer's watchdog is not the only thing cleaning
  up the now-dead links. On power-on, both **rebuild both planes WITHOUT re-rolling the nodeId**:
  re-add service, re-publish L2CAP, re-advertise, re-scan. Keeping the nodeId stable across the
  bounce avoids the transient duplicate link that an asymmetric re-roll used to create (the peer
  would have seen a "new" node and formed a second link until its watchdog reaped the first).
- **Meet/part forever:** part = watchdog/disconnect → COOLDOWN → LOST; meet = advert seen → SEEN → …
  → UP. No persistent per-MAC state accumulates (TTL-bounded), so the cycle runs indefinitely.

---

## 7. Platform-specific reliability rules (all field-verified in this repo)

### 7.1 Android advertiser: `startAdvertisingSet`, legacy mode, gated on `onServiceAdded`
Legacy `startAdvertising(...)` with `setIncludeDeviceName(true)` silently omits the GAP name on
Pixel; `startAdvertisingSet(... setLegacyMode(true).setConnectable(true).setScannable(true) ...)`
behaves. Start advertising **only from `onServiceAdded`** (R10) so a central can never connect before
the GATT service is registered. A connectable `AdvertisingSet` **persists across connections**: do
**not** stop/restart it per accepted connection (that races incoming connects into
`CONNECTION_ACCEPT_TIMEOUT`). Make `startAdvertise()` idempotent, null the handle in
`onAdvertisingSetStopped`, and self-heal from the tick loop (`if (ticks % 30 == 0) startAdvertise()`,
a no-op while live; recovers a wedged advertiser).

### 7.2 Android GATT lifecycle: always `gatt.close()`; the dialer's GATT client is scarce
On any connect failure/disconnect/133, `gatt.close()` and remove from the in-flight set, or leaked
GATT clients exhaust Android's cap and every later connect times out. `connectGatt` on the **main
thread**, `autoConnect = false` (fast, deterministic direct connect); rely on our own state machine
for re-establish, not `autoConnect=true`'s opaque slow reconnect. A poisoned `gatt` is never reused.
**GATT-client slot pressure (R5):** Android caps concurrent GATT *client* connections (commonly ~7,
OEM-dependent, system-wide). The dialer holds its `BluetoothGatt` for the session by default, which
is the **safe** choice for the core proof. An optional, **flag-gated** optimization
(`CLOSE_GATT_AFTER_L2CAP`, **default OFF**) closes the GATT client once the L2CAP channel is `UP`,
freeing the slot, but on a minority of OEM stacks `gatt.close()` may drop the underlying LE ACL and
kill the L2CAP socket. **Do not enable it without per-OEM verification** (§10: confirm the counter
keeps advancing after the close on the target hardware). In the dominant iOS-central→Android-
peripheral topology Android dials rarely, so default-OFF rarely approaches the cap; enable the flag
only for dense-mesh deployments after verifying the ACL survives the close. *(This is a deliberate
divergence from the reviewer's "default ON": for the core 1:1 / small-mesh proof, killing a live
socket is strictly worse than slot pressure, and the ACL-refcount behavior is not publicly
documented.)*

### 7.3 Android radio sharing: don't let central starve peripheral; respect the scan throttle
Continuous `SCAN_MODE_LOW_LATENCY` + failing `connectGatt`s saturate the radio so peers can't even
*discover* this device. **One persistent scan, never restarted** in steady state. `LOW_LATENCY`
while we hold **0** links (fast discovery), downshift to `BALANCED` while we hold **≥1** link. Two
guards make this safe against a flapping peer (R9):
- **Hysteresis:** a mode change is applied only after the link count has been **stable for ≥10 s**
  (downshift) / ~2 s (upshift), so a peer that crosses the 0↔1 boundary repeatedly does not toggle
  the scan on every flap.
- **Sliding-window start guard:** every `stopScan`+`startScan` pair counts as one start; the code
  tracks start timestamps and **never issues a start that would be the 5th within any 30 s window**
  (Android's 5-starts/30 s throttle is **silent**: it returns success and delivers nothing). A
  start that would breach the window is **deferred** until the window frees.

In the dominant iOS↔Android topology Android barely needs to scan (iOS is the central; Android is the
always-on discoverable peripheral). Never scan >30 min without a stop or Android silently makes it
opportunistic.

### 7.4 iOS GATT cache + PSM staleness
iOS caches GATT handles/values. If the Android peripheral re-creates GATT or re-listens (new PSM),
iOS may keep opening L2CAP with a **stale PSM** (`No such L2CAP connection`, errors 431/436).
Mitigations: (a) keep the listener + PSM stable for the session (§3.1); (b) implement
`peripheral(_:didModifyServices:)` → drop cached PSM and re-discover; (c) when the peripheral *must*
re-listen, remove+re-add the GATT service to force a structure change so iOS re-reads.

### 7.5 iOS threading, background, and state restoration
- **Threading (R8):** the macOS CLI runs the CB managers and the L2CAP streams on `.main` and that is
  correct **only because no UI contends for the main thread**. On the iOS **app** target the main
  thread also runs UIKit/SwiftUI; a main-thread hitch would starve the CB callbacks and the L2CAP
  `InputStream`/`OutputStream` events, making `lastRxMs` go stale and the watchdog declare a
  **false** DEAD (the same class as this repo's `ui-refresh-must-coalesce` 0x8BADF00D lesson).
  Therefore on iOS: run the CB managers on a **dedicated serial dispatch queue**, and run the L2CAP
  streams + their PING/watchdog timers on a **dedicated thread with its own run loop** (the watchdog
  timer on that same run loop). The field rule "keep streams on MAIN" meant *don't move streams onto
  a different thread than the run loop servicing them*; it did **not** mandate the UI main thread.
  See §8.1 for the exact adaptation.
- **Background + restoration:** set `UIBackgroundModes = [bluetooth-central, bluetooth-peripheral]`
  and `NSBluetoothAlwaysUsageDescription`. Pass the restore-identifier options and handle
  `willRestoreState` so iOS can relaunch the app into the background with connections intact and
  pending connects re-armed; **re-add the GATT service before re-advertising** (R10). Background scan
  works **only** with a service-UUID filter. On launch also
  `retrieveConnectedPeripherals(withServices:[SERVICE_UUID])` to re-adopt system-kept links. Android
  keeps both planes alive via the existing `connectedDevice` foreground service (manifest already has
  `FOREGROUND_SERVICE_CONNECTED_DEVICE`).

### 7.6 Cross-platform wake for a *killed* iOS peer (optional, Appendix A)
A suspended/killed iOS peripheral is invisible to Android. To let Android initiate to an iOS device
that isn't running, broadcast a non-connectable iBeacon and monitor a `CLBeaconRegion` that
relaunches the killed app into the background. Optional; the core proof does not require it.

---

## 8. Critical source: Apple (Swift / CoreBluetooth)

Build the macOS CLI as the fast iteration loop (`swiftc -framework CoreBluetooth`, model on
`apple/hopmac/build.sh`); the same types are iOS-faithful. This is the reliability-critical core:
the framed, heartbeat-driven `Link`, both role delegates, and the dedup glue + `main`. The CLI runs
everything on `.main`; §8.1 gives the iOS-app threading adaptation.

```swift
import Foundation
import CoreBluetooth

let SERVICE_UUID  = CBUUID(string: "7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F")
let ENDPOINT_CHAR = CBUUID(string: "7ED70002-3C2A-4F19-9B8E-1A2B3C4D5E6F")
let PING_S = 1.0, DEAD_FG_S = 5.0, DEAD_BG_S = 15.0, REAP_S = 3.0    // §5

// R8: macOS CLI runs everything on .main (no UI contends). The iOS APP TARGET must point
// bleQueue at a dedicated serial queue and bleRunLoop at a dedicated I/O thread's RunLoop,
// and perform Link stream setup ON that thread. See §8.1.
let bleQueue: DispatchQueue = .main
let bleRunLoop: RunLoop = .main
// R7: the iOS app sets this from scenePhase / UIApplication; the CLI leaves it false.
var bleAppInBackground = false

func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
func nowS()  -> Double { Date().timeIntervalSince1970 }
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func gt(_ a: Data, _ b: Data) -> Bool {                // unsigned big-endian compare a > b
    for i in 0..<min(a.count, b.count) { if a[i] != b[i] { return a[i] > b[i] } }
    return a.count > b.count
}

// ---- One L2CAP link: 4-byte BE framing, 1 Hz PING (proof counter), adaptive liveness watchdog ----
final class Link: NSObject, StreamDelegate {
    let isDialer: Bool; let myId: Data
    var peerId: Data?                                  // learned from HELLO; the dedup/tiebreak key
    var up = false
    var stableUp: Bool { guard let b = becameUpMs else { return false }; return nowMs() - b >= 30_000 } // §6
    private let input: InputStream, output: OutputStream
    private var inBuf = [UInt8](), outBuf = [UInt8]()
    private var lastRxMs = nowMs(); private var openedMs = nowMs(); private var becameUpMs: UInt64?
    private var ewmaGapMs = 1000.0                      // R7: inbound inter-arrival EWMA
    private var txSeq: UInt64 = 0; private var rxSeq: UInt64 = 0
    private var ping: Timer?, watchdog: Timer?
    private let onUp: (Link) -> Void, onClose: (Link) -> Void
    private var closed = false

    init(channel: CBL2CAPChannel, isDialer: Bool, myId: Data,
         onUp: @escaping (Link)->Void, onClose: @escaping (Link)->Void) {
        self.isDialer = isDialer; self.myId = myId; self.onUp = onUp; self.onClose = onClose
        self.input = channel.inputStream; self.output = channel.outputStream
        super.init()
        for s in [input, output] { s.delegate = self; s.schedule(in: bleRunLoop, forMode: .common); s.open() }
        var hello = Data([0x01]); hello.append(myId); hello.append(isDialer ? 1 : 0); hello.append(0)
        sendFrame(hello)                                                    // HELLO first
        let p = Timer(timeInterval: PING_S, repeats: true) { [weak self] _ in self?.sendPing() }
        let w = Timer(timeInterval: 1.0,    repeats: true) { [weak self] _ in self?.tick() }
        bleRunLoop.add(p, forMode: .common); bleRunLoop.add(w, forMode: .common)   // bound to the I/O run loop
        ping = p; watchdog = w
    }
    private func deadLimitS() -> Double {                                   // R7: adaptive deadline
        max(bleAppInBackground ? DEAD_BG_S : DEAD_FG_S, 3.0 * ewmaGapMs / 1000.0)
    }
    private func tick() {
        if !up && Double(nowMs() - openedMs)/1000 > REAP_S { close("no-HELLO reap"); return }
        if up && Double(nowMs() - lastRxMs)/1000 > deadLimitS() { close("liveness DEAD") }
    }
    private func sendPing() { txSeq += 1; var b = Data([0x02]); appU64(&b, txSeq); appU64(&b, nowMs()); sendFrame(b) }
    private func sendFrame(_ body: Data) {
        guard !closed else { return }
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { outBuf.append(contentsOf: $0) }
        outBuf.append(contentsOf: body); drain()
    }
    func close(_ why: String) {
        guard !closed else { return }; closed = true
        ping?.invalidate(); watchdog?.invalidate()
        for s in [input, output] { s.close(); s.remove(from: bleRunLoop, forMode: .common) }
        FileHandle.standardError.write("LINK CLOSED (\(why))\n".data(using:.utf8)!)
        onClose(self)
    }
    func stream(_ s: Stream, handle e: Stream.Event) {
        switch e {
        case .hasBytesAvailable: read()
        case .hasSpaceAvailable: drain()
        case .endEncountered, .errorOccurred: close("stream end/error")
        default: break }
    }
    private func drain() {
        while !outBuf.isEmpty && output.hasSpaceAvailable {
            let n = output.write(outBuf, maxLength: outBuf.count)
            if n > 0 { outBuf.removeFirst(n) } else { break }
        }
    }
    private func read() {
        var tmp = [UInt8](repeating: 0, count: 16384)
        while input.hasBytesAvailable { let n = input.read(&tmp, maxLength: tmp.count); if n > 0 { inBuf.append(contentsOf: tmp[0..<n]) } else { break } }
        let gap = Double(nowMs() - lastRxMs); ewmaGapMs = 0.8*ewmaGapMs + 0.2*gap   // R7
        lastRxMs = nowMs(); deframe()
    }
    private func deframe() {
        while inBuf.count >= 4 {
            let len = Int(UInt32(inBuf[0])<<24 | UInt32(inBuf[1])<<16 | UInt32(inBuf[2])<<8 | UInt32(inBuf[3]))
            guard len >= 1, len <= 4*1024*1024 else { close("bad len"); return }
            let total = 4 + len; guard inBuf.count >= total else { break }
            handle(Array(inBuf[4..<total])); inBuf.removeFirst(total)
        }
    }
    private func handle(_ b: [UInt8]) {
        switch b[0] {
        case 0x01: if b.count >= 17 { peerId = Data(b[1..<17]); if !up { up = true; becameUpMs = nowMs(); onUp(self) } } // HELLO
        case 0x02:                                                                                    // PING → PONG
            let seq = u64(b, 1)
            if rxSeq != 0 && seq != rxSeq + 1 { print("⚠️ counter gap \(rxSeq) -> \(seq)") }
            rxSeq = seq
            var p = Data([0x03]); p.append(contentsOf: b[1..<min(17, b.count)]); sendFrame(p)
        case 0x03: break                                                                              // PONG (lastRxMs bumped)
        default: break }                                                                             // 0x10 DATA → upper layer
    }
    private func appU64(_ d: inout Data, _ v: UInt64) { var be = v.bigEndian; withUnsafeBytes(of:&be){ d.append(contentsOf:$0) } }
    private func u64(_ b: [UInt8], _ o: Int) -> UInt64 { var v: UInt64 = 0; for i in 0..<8 { v = v<<8 | UInt64(b[o+i]) }; return v }
}

// ---- ACCEPTOR (peripheral) ----
final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    var pm: CBPeripheralManager!; var psm: CBL2CAPPSM = 0
    let myId: Data; let onLink: (Link)->Void, onClose: (Link)->Void, onPowerOff: ()->Void
    init(myId: Data, onLink: @escaping (Link)->Void, onClose: @escaping (Link)->Void, onPowerOff: @escaping ()->Void) {
        self.myId = myId; self.onLink = onLink; self.onClose = onClose; self.onPowerOff = onPowerOff; super.init()
        pm = CBPeripheralManager(delegate: self, queue: bleQueue,
             options: [CBPeripheralManagerOptionRestoreIdentifierKey: "hop.ble.peripheral"]) }
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        if p.state == .poweredOff { onPowerOff() }                          // R11: drop links on power-off
        guard p.state == .poweredOn else { return }
        let ch = CBMutableCharacteristic(type: ENDPOINT_CHAR, properties: .read, value: nil, permissions: .readable)
        let svc = CBMutableService(type: SERVICE_UUID, primary: true); svc.characteristics = [ch]
        p.add(svc)
        p.publishL2CAPChannel(withEncryption: false)                       // INSECURE
    }
    func peripheralManager(_ p: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        psm = PSM
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID]])   // UUID only (§1.3)
    }
    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead req: CBATTRequest) {
        var v = Data([UInt8(psm >> 8), UInt8(psm & 0xff)]); v.append(myId)         // [2B PSM][16B id]
        req.value = v; p.respond(to: req, withResult: .success)
    }
    func peripheralManager(_ p: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel else { return }
        _ = Link(channel: channel, isDialer: false, myId: myId, onUp: onLink, onClose: onClose)
    }
    func peripheralManager(_ p: CBPeripheralManager, willRestoreState dict: [String:Any]) {
        // R10: re-add the GATT service BEFORE re-advertising, then re-publish L2CAP if needed.
    }
}

// ---- DIALER (central) ----
final class Central: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var cm: CBCentralManager!; let myId: Data
    var retained = [UUID: CBPeripheral]()              // strong ref while dialing/linked
    var dialTimers = [UUID: DispatchWorkItem]()        // R6: 12s dial-timeout per peer
    var pendingWaits = Set<UUID>()                     // R4: one outstanding wait per peer
    var advPrefixById = [UUID: Data]()                 // backoff-key source (prefix once known)
    var backoff = [String: Double]()                   // R2: key = 6B-prefix hex (stable), else identifier
    let onLink: (Link)->Void, onClose: (Link)->Void, onPowerOff: ()->Void
    let haveLinkTo: (Data)->Bool, haveLinkToPrefix: (Data)->Bool
    init(myId: Data,
         onLink: @escaping (Link)->Void, onClose: @escaping (Link)->Void, onPowerOff: @escaping ()->Void,
         haveLinkTo: @escaping (Data)->Bool, haveLinkToPrefix: @escaping (Data)->Bool) {
        self.myId = myId; self.onLink = onLink; self.onClose = onClose; self.onPowerOff = onPowerOff
        self.haveLinkTo = haveLinkTo; self.haveLinkToPrefix = haveLinkToPrefix; super.init()
        cm = CBCentralManager(delegate: self, queue: bleQueue,
             options: [CBCentralManagerOptionRestoreIdentifierKey: "hop.ble.central"]) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOff { onPowerOff() }                                 // R11
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: [SERVICE_UUID],                        // filter REQUIRED for bg
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String:Any], rssi: NSNumber) {
        var advPrefix: Data? = nil
        if let mfg = d[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 8,
           mfg[0] == 0xFF, mfg[1] == 0xFF { advPrefix = mfg.subdata(in: 2..<8) }  // 6-byte prefix
        let bkey = advPrefix.map(hex) ?? p.identifier.uuidString
        if let until = backoff[bkey], nowS() < until { return }                   // R2: rate-limited
        if let pre = advPrefix, haveLinkToPrefix(pre) { return }                  // R4: already linked
        guard retained[p.identifier] == nil else { return }                       // already dialing
        let dialNow = advPrefix.map { gt(myId.prefix(6), $0) } ?? true            // §2.1 (no prefix ⇒ dial)
        if dialNow { dial(c, p, advPrefix) }
        else if pendingWaits.insert(p.identifier).inserted {                      // R4: one wait per peer
            bleQueue.asyncAfter(deadline: .now() + 4 + .random(in: 0...1)) { [weak self] in
                guard let self else { return }
                self.pendingWaits.remove(p.identifier)
                if let pre = advPrefix, self.haveLinkToPrefix(pre) { return }     // R4: gate on link map, not retained
                if self.retained[p.identifier] != nil { return }
                self.dial(c, p, advPrefix)
            }
        }
    }
    private func dial(_ c: CBCentralManager, _ p: CBPeripheral, _ advPrefix: Data?) {
        retained[p.identifier] = p; advPrefixById[p.identifier] = advPrefix
        p.delegate = self; c.connect(p, options: nil)
        let t = DispatchWorkItem { [weak self] in self?.dialTimedOut(p) }         // R6
        dialTimers[p.identifier] = t
        bleQueue.asyncAfter(deadline: .now() + 12, execute: t)
    }
    private func dialTimedOut(_ p: CBPeripheral) {
        guard retained[p.identifier] != nil else { return }
        cm.cancelPeripheralConnection(p)                                          // R6: abort indefinite connect
        reconnect(p)
    }
    private func clearDialTimer(_ p: CBPeripheral) { dialTimers[p.identifier]?.cancel(); dialTimers[p.identifier] = nil }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices(nil) }  // nil!
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { reconnect(p) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { reconnect(p) }
    func peripheral(_ p: CBPeripheral, didModifyServices invalidated: [CBService]) { p.discoverServices(nil) } // defeat stale cache
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == SERVICE_UUID { p.discoverCharacteristics([ENDPOINT_CHAR], for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == ENDPOINT_CHAR { p.readValue(for: ch) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value, v.count >= 18 else { return }
        let peerId = v.subdata(in: 2..<18)
        if haveLinkTo(peerId) {                                                    // R4: already linked → no redundant CoC
            clearDialTimer(p); cm.cancelPeripheralConnection(p); retained[p.identifier] = nil; return
        }
        advPrefixById[p.identifier] = peerId.prefix(6)                             // R2: promote to stable nodeId prefix
        let psm = CBL2CAPPSM(UInt16(v[0]) << 8 | UInt16(v[1]))
        p.openL2CAPChannel(psm)
    }
    func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if error != nil { p.discoverServices(nil); return }                       // stale PSM → re-read
        guard let channel else { return }
        clearDialTimer(p)                                                          // R6: dial succeeded
        backoff[advPrefixById[p.identifier].map(hex) ?? p.identifier.uuidString] = nil   // reset on success
        _ = Link(channel: channel, isDialer: true, myId: myId, onUp: onLink,
                 onClose: { [weak self] l in self?.dialerLinkClosed(p, l); self?.onClose(l) })
    }
    private func dialerLinkClosed(_ p: CBPeripheral, _ l: Link) {
        let key = advPrefixById[p.identifier].map(hex) ?? p.identifier.uuidString
        if l.stableUp { backoff[key] = nil }                                      // §6: reset after a long-lived link
        if retained[p.identifier] != nil { cm.cancelPeripheralConnection(p) }     // → didDisconnect → reconnect
    }
    func reconnect(_ p: CBPeripheral) {
        clearDialTimer(p); retained[p.identifier] = nil
        let key = advPrefixById[p.identifier].map(hex) ?? p.identifier.uuidString
        let base = backoff[key].map { max($0 - nowS(), 0.5) } ?? 0.5              // §6 (keyed by stable prefix)
        backoff[key] = nowS() + min(base * 2, 30) + .random(in: 0...1)
        evictBackoff()                                                            // R2: TTL bound
        // persistent scan keeps delivering didDiscover; no scan restart here (avoids churn)
    }
    private func evictBackoff() { let cut = nowS() - 30; backoff = backoff.filter { $0.value > cut } }
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String:Any]) { /* re-arm scan + pending; retrieveConnectedPeripherals */ }
}

// ---- Top-level node: owns myId, both planes, the dedup map (§2.3) ----
final class Node {
    let myId = { var d = Data(count: 16); _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }; return d }()  // R11: stable for process lifetime
    var peripheral: Peripheral!, central: Central!
    var linksByPeerId = [Data: Link]()
    init() {
        peripheral = Peripheral(myId: myId,
            onLink: { [weak self] in self?.onUp($0) },
            onClose: { [weak self] in self?.onClose($0) },
            onPowerOff: { [weak self] in self?.closeAllLinks() })
        central = Central(myId: myId,
            onLink: { [weak self] in self?.onUp($0) },
            onClose: { [weak self] in self?.onClose($0) },
            onPowerOff: { [weak self] in self?.closeAllLinks() },
            haveLinkTo: { [weak self] in self?.linksByPeerId[$0] != nil },
            haveLinkToPrefix: { [weak self] pre in self?.linksByPeerId.keys.contains { $0.prefix(6) == pre } ?? false })
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            print("STATUS links=\(self?.linksByPeerId.count ?? 0)") }
    }
    func onUp(_ link: Link) {                                                 // §2.3 dedup
        guard let peer = link.peerId else { return }
        guard let existing = linksByPeerId[peer], existing !== link else { linksByPeerId[peer] = link; return }
        let keepDialed = gt(myId, peer)                                       // keep MY dialed iff I'm greater
        let keep = [existing, link].first { $0.isDialer == keepDialed } ?? link
        let drop = (keep === link) ? existing : link
        linksByPeerId[peer] = keep                                            // R3: set survivor BEFORE closing
        drop.close("dedup")
        print("DEDUP kept isDialer=\(keep.isDialer) peer=\(hex(peer.prefix(4)))")
    }
    func onClose(_ link: Link) {                                             // R3: identity-checked removal
        guard let peer = link.peerId else { return }
        if linksByPeerId[peer] === link { linksByPeerId.removeValue(forKey: peer) }
    }
    func closeAllLinks() { for l in linksByPeerId.values { l.close("power-off") } }   // R11
}

setbuf(stdout, nil)                                                          // unbuffered logs under `timeout`
let node = Node()
RunLoop.main.run()
```

### 8.1 iOS device-target threading adaptation (R8): apply when building the app, not the CLI

The CLI above is correct as-is. For the **iOS app**, make exactly these substitutions; nothing else
in §8 changes:

```swift
// A dedicated serial queue services the CB delegates (off the UI main thread).
let bleQueue = DispatchQueue(label: "hop.ble.cb")

// A dedicated thread owns the run loop that services the L2CAP streams + PING/watchdog timers.
final class BLEIO {
    static let shared = BLEIO()
    private(set) var runLoop: RunLoop!
    private let ready = DispatchSemaphore(value: 0)
    private init() {
        Thread.detachNewThread { [weak self] in
            self?.runLoop = RunLoop.current
            self?.ready.signal()
            RunLoop.current.add(Port(), forMode: .common)   // keep the run loop alive
            RunLoop.current.run()
        }
        ready.wait()
    }
}
let bleRunLoop: RunLoop = BLEIO.shared.runLoop
var bleAppInBackground = false   // set from scenePhase: .background → true, .active → false
```

Because `bleQueue` (CB callbacks) and `bleRunLoop`'s thread differ, hand each opened channel to the
I/O thread before scheduling its streams: in both `didOpen` handlers, wrap the `Link(...)`
construction in `bleRunLoop.perform { ... }` (or a `Thread.perform(onThread:)` to `BLEIO.shared`'s
thread) so `Stream.schedule(in:bleRunLoop:)` and the `Timer`s attach on the thread that owns the run
loop. The dedup `Node` callbacks then hop back to `bleQueue`/`.main` as needed for shared-state
mutation; keep `linksByPeerId` accessed on a single queue.

---

## 9. Critical source: Android (Kotlin)

Model the build on `android/HopDemo` (`gradlew`, `compileSdk 34`, `minSdk 29`). Permissions are
already in the manifest (`BLUETOOTH_ADVERTISE`, `BLUETOOTH_SCAN` `neverForLocation`,
`BLUETOOTH_CONNECT`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`). Run both planes inside the existing
`HopService` foreground service. Reliability-critical core:

```kotlin
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.*
import android.util.Log
import java.io.IOException
import java.security.SecureRandom
import java.util.ParcelUuid
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

val SERVICE_UUID  = ParcelUuid.fromString("7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F")
val ENDPOINT_CHAR = UUID.fromString("7ED70002-3C2A-4F19-9B8E-1A2B3C4D5E6F")
const val MFG_ID = 0xFFFF
const val PING_MS = 1000L; const val DEAD_MS = 5000L; const val DEAD_BG_MS = 15_000L; const val REAP_MS = 3000L
const val MAX_DIALS = 2; const val DIAL_TIMEOUT_MS = 12_000L
const val LOST_MS = 30_000L
const val CLOSE_GATT_AFTER_L2CAP = false      // R5: free the GATT slot after L2CAP up, OEM-risky; verify before enabling
@Volatile var appInBackground = false         // R7: set from app lifecycle; foreground-service default = false
val myId = ByteArray(16).also { SecureRandom().nextBytes(it) }   // §1.2: stable for process lifetime; NOT re-rolled on adapter cycle (R11)

fun gt(a: ByteArray, b: ByteArray): Boolean {                               // unsigned big-endian a > b
    for (i in 0 until minOf(a.size, b.size)) { val x=a[i].toInt() and 0xff; val y=b[i].toInt() and 0xff; if (x!=y) return x>y }
    return a.size > b.size
}
fun ByteArray.toHex() = joinToString(""){ "%02x".format(it) }

// ---- One L2CAP link over a BluetoothSocket: 4-byte BE framing, 1 Hz PING, adaptive watchdog ----
class Link(
    private val socket: BluetoothSocket, val isDialer: Boolean, private val myId: ByteArray,
    private val onUp: (Link) -> Unit, private val onClose: (Link) -> Unit,
) {
    @Volatile var peerId: ByteArray? = null
    @Volatile var up = false
    @Volatile private var becameUpMs = 0L
    @Volatile private var lastRxMs = System.currentTimeMillis()
    private val openedMs = System.currentTimeMillis()
    private var ewmaGapMs = 1000.0
    private var txSeq = 0L; private var rxSeq = 0L
    @Volatile private var closed = false
    private val out = socket.outputStream; private val inp = socket.inputStream
    private val writeLock = Any()
    private val sched = Executors.newSingleThreadScheduledExecutor()

    fun stableUp(): Boolean = up && becameUpMs != 0L && System.currentTimeMillis() - becameUpMs >= 30_000L  // §6
    fun start() {
        sendFrame(byteArrayOf(0x01) + myId + byteArrayOf(if (isDialer) 1 else 0, 0))   // HELLO
        thread(name = "l2cap-rx") { readLoop() }
        sched.scheduleAtFixedRate({ tick() }, PING_MS, PING_MS, TimeUnit.MILLISECONDS)
    }
    private fun deadLimit(): Long {                                                     // R7: adaptive
        val base = if (appInBackground) DEAD_BG_MS else DEAD_MS
        return maxOf(base, (3.0 * ewmaGapMs).toLong())
    }
    private fun tick() {
        val now = System.currentTimeMillis()
        if (!up && now - openedMs > REAP_MS) { close("no-HELLO reap"); return }
        if (up && now - lastRxMs > deadLimit()) { close("liveness DEAD"); return }
        txSeq++; sendFrame(byteArrayOf(0x02) + u64(txSeq) + u64(now))                   // PING
    }
    private fun sendFrame(body: ByteArray) {
        if (closed) return
        val n = body.size
        val hdr = byteArrayOf((n ushr 24).toByte(),(n ushr 16).toByte(),(n ushr 8).toByte(), n.toByte())
        try { synchronized(writeLock) { out.write(hdr); out.write(body); out.flush() } }
        catch (e: IOException) { close("write: ${e.message}") }
    }
    private fun readLoop() {
        val hdr = ByteArray(4)
        try {
            while (!closed) {
                readFully(hdr, 4)
                val len = ((hdr[0].i shl 24) or (hdr[1].i shl 16) or (hdr[2].i shl 8) or hdr[3].i)
                if (len < 1 || len > 4*1024*1024) { close("bad len"); return }
                val body = ByteArray(len); readFully(body, len)
                val now = System.currentTimeMillis()
                ewmaGapMs = 0.8*ewmaGapMs + 0.2*(now - lastRxMs); lastRxMs = now; handle(body)   // R7
            }
        } catch (e: IOException) { close("read: ${e.message}") }
    }
    private fun readFully(b: ByteArray, n: Int) { var o=0; while (o<n) { val r=inp.read(b,o,n-o); if (r<0) throw IOException("eof"); o+=r } }
    private fun handle(b: ByteArray) {
        when (b[0].toInt()) {
            0x01 -> if (b.size >= 17 && !up) { peerId = b.copyOfRange(1,17); up = true; becameUpMs = System.currentTimeMillis(); onUp(this) }  // HELLO
            0x02 -> {                                                                                  // PING → PONG
                val seq = u64dec(b,1)
                if (rxSeq != 0L && seq != rxSeq + 1) Log.w("HOPLOG","counter gap $rxSeq -> $seq")
                rxSeq = seq
                sendFrame(byteArrayOf(0x03) + b.copyOfRange(1, minOf(17, b.size)))
            }
        }
    }
    fun close(why: String) {
        if (closed) return; closed = true
        Log.i("HOPLOG","LINK CLOSED ($why)")
        sched.shutdownNow(); try { socket.close() } catch (_: IOException) {}
        onClose(this)
    }
    private fun u64(v: Long) = ByteArray(8) { (v ushr (56 - it*8)).toByte() }
    private fun u64dec(b: ByteArray, o: Int): Long { var v=0L; for (i in 0..7) v=(v shl 8) or (b[o+i].toLong() and 0xff); return v }
    private val Byte.i get() = toInt() and 0xff
}

// ---- ACCEPTOR (peripheral): listener (session-stable PSM) + GATT char + advertiser ----
class Peripheral(private val ctx: Context, private val myId: ByteArray,
                 private val onLink: (Link) -> Unit, private val onClose: (Link) -> Unit) {
    private val adapter = (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    private lateinit var server: BluetoothServerSocket
    @Volatile private var psm = 0
    private var gattServer: BluetoothGattServer? = null
    private var advSet: AdvertisingSet? = null

    fun start() {
        server = adapter.listenUsingInsecureL2capChannel(); psm = server.psm                  // INSECURE LE CoC
        thread(name = "l2cap-accept") {
            while (true) {
                val sock = try { server.accept() } catch (e: IOException) { break }
                Link(sock, isDialer = false, myId, onLink, onClose).start()                   // reaper kills orphans
            }
        }
        startGattServer()                                                                      // R10: advertise from onServiceAdded only
    }
    fun closeAllLinks() { /* Node owns the link map; STATE_OFF path calls Node.closeAll() */ } // R11 (see Node)
    private fun startGattServer() {
        val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        gattServer = mgr.openGattServer(ctx, object : BluetoothGattServerCallback() {
            override fun onServiceAdded(status: Int, service: BluetoothGattService) {          // R10
                if (status == BluetoothGatt.GATT_SUCCESS) startAdvertise()
            }
            override fun onCharacteristicReadRequest(d: BluetoothDevice, reqId: Int, off: Int, ch: BluetoothGattCharacteristic) {
                val v = byteArrayOf((psm ushr 8).toByte(), psm.toByte()) + myId               // [2B PSM][16B id]
                gattServer?.sendResponse(d, reqId, BluetoothGatt.GATT_SUCCESS, 0, v)
            }
        })
        val svc = BluetoothGattService(SERVICE_UUID.uuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        svc.addCharacteristic(BluetoothGattCharacteristic(ENDPOINT_CHAR,
            BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
        gattServer?.addService(svc)                                                            // async → onServiceAdded
    }
    fun startAdvertise() {                                                                     // idempotent self-heal
        if (advSet != null) return
        val adv = adapter.bluetoothLeAdvertiser ?: return
        val params = AdvertisingSetParameters.Builder()
            .setLegacyMode(true).setConnectable(true).setScannable(true)
            .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM).build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(SERVICE_UUID)
            .addManufacturerData(MFG_ID, myId.copyOfRange(0, 6))                               // 6-byte prefix
            .build()
        adv.startAdvertisingSet(params, data, null, null, null, object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) { advSet = set }
            override fun onAdvertisingSetStopped(set: AdvertisingSet?) { advSet = null }
        })
    }
}

// ---- DIALER (central): scan → connectGatt → read PSM+id → createInsecureL2capChannel ----
class Central(private val ctx: Context, private val myId: ByteArray,
              private val onLink: (Link) -> Unit, private val onClose: (Link) -> Unit,
              private val haveLinkTo: (ByteArray) -> Boolean,
              private val haveLinkToPrefix: (ByteArray) -> Boolean) {
    private val adapter = (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    private val main = Handler(Looper.getMainLooper())
    private val inFlight = mutableSetOf<String>()                 // R2: short-lived, MAC-keyed
    private val backoff = mutableMapOf<String, Long>()            // R2: prefix-hex (stable) or MAC
    private val addrToBkey = HashMap<String, String>()            // MAC → backoff key (prefix once known)
    private val pendingWaits = mutableSetOf<String>()             // R4: one wait per MAC
    private val gattByAddr = HashMap<String, BluetoothGatt>()
    private val scanStarts = ArrayDeque<Long>()                   // R9: 30s sliding window of startScan times
    private var scanning = false
    private var currentMode = -1

    fun start() { applyScan(ScanSettings.SCAN_MODE_LOW_LATENCY) }

    fun requestScanMode(mode: Int, debounceMs: Long) {           // R9: hysteresis (Node passes 10s down / 2s up)
        main.postDelayed({ if (mode != currentMode) applyScan(mode) }, debounceMs)
    }
    private fun applyScan(mode: Int) {                            // R9: never the 5th startScan in any 30s window
        val now = System.currentTimeMillis()
        while (scanStarts.isNotEmpty() && now - scanStarts.first() > 30_000) scanStarts.removeFirst()
        if (scanStarts.size >= 4) { main.postDelayed({ applyScan(mode) }, 30_000 - (now - scanStarts.first()) + 100); return }
        val sc = adapter.bluetoothLeScanner ?: return
        if (scanning) sc.stopScan(scanCb)
        val filters = listOf(ScanFilter.Builder().setServiceUuid(SERVICE_UUID).build())
        sc.startScan(filters, ScanSettings.Builder().setScanMode(mode).build(), scanCb)
        scanning = true; currentMode = mode; scanStarts.addLast(now)
    }
    private val scanCb = object : ScanCallback() {
        override fun onScanResult(type: Int, r: ScanResult) {
            val pre = r.scanRecord?.getManufacturerSpecificData(MFG_ID)?.let { if (it.size >= 6) it.copyOfRange(0,6) else null }
            val dev = r.device
            val dialNow = if (pre != null) gt(myId.copyOfRange(0,6), pre) else true
            if (dialNow) tryDial(dev, pre)
            else if (pendingWaits.add(dev.address)) {                                          // R4: dedupe wait closures
                main.postDelayed({
                    pendingWaits.remove(dev.address)
                    if (pre != null && haveLinkToPrefix(pre)) return@postDelayed              // R4: gate on link map
                    tryDial(dev, pre)
                }, 4000L + (0..1000L).random())
            }
        }
    }
    private fun tryDial(dev: BluetoothDevice, pre: ByteArray?) {
        val addr = dev.address
        if (inFlight.size >= MAX_DIALS || addr in inFlight) return
        if (pre != null && haveLinkToPrefix(pre)) return                                       // R4
        val bkey = pre?.toHex() ?: addr
        if (System.currentTimeMillis() < (backoff[bkey] ?: 0L)) return                         // R2
        addrToBkey[addr] = bkey; inFlight += addr
        val g = dev.connectGatt(ctx, false, gattCb, BluetoothDevice.TRANSPORT_LE)              // MAIN thread, autoConnect=false
        gattByAddr[addr] = g
        main.postDelayed({ if (addr in inFlight) { g.close(); gattByAddr.remove(addr); fail(addr) } }, DIAL_TIMEOUT_MS)  // R6
    }
    private val gattCb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            val addr = g.device.address
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH); g.discoverServices()
            } else { g.close(); gattByAddr.remove(addr); fail(addr) }                          // ALWAYS close
        }
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val ch = g.getService(SERVICE_UUID.uuid)?.getCharacteristic(ENDPOINT_CHAR)
            if (ch != null) g.readCharacteristic(ch) else { g.close(); gattByAddr.remove(g.device.address); fail(g.device.address) }
        }
        // R1: API 33+ delivers the 4-arg form...
        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray, status: Int) =
            handleRead(g, value, status)
        // R1: ...but API 29 to 32 (the whole sub-33 field) delivers ONLY this deprecated 3-arg form.
        @Deprecated("Deprecated in API 33")
        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION") handleRead(g, ch.value ?: ByteArray(0), status)
        }
    }
    private fun handleRead(g: BluetoothGatt, value: ByteArray, status: Int) {
        val addr = g.device.address
        if (status != BluetoothGatt.GATT_SUCCESS || value.size < 18) { g.close(); gattByAddr.remove(addr); fail(addr); return }
        val peerId = value.copyOfRange(2, 18)
        addrToBkey[addr] = peerId.copyOfRange(0,6).toHex()                                     // R2: promote to stable prefix
        if (haveLinkTo(peerId)) { g.close(); gattByAddr.remove(addr); inFlight -= addr; return } // R4: pre-dial dedup
        val psm = ((value[0].toInt() and 0xff) shl 8) or (value[1].toInt() and 0xff)
        val dev = g.device
        thread(name = "l2cap-dial") {
            try {
                val sock = dev.createInsecureL2capChannel(psm); sock.connect()
                g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_BALANCED)
                inFlight -= addr; backoff.remove(addrToBkey[addr] ?: addr)
                val link = Link(sock, isDialer = true, myId, onLink,
                                onClose = { l -> dialerLinkClosed(g, addr, l); onClose(l) })
                if (CLOSE_GATT_AFTER_L2CAP) { g.close(); gattByAddr.remove(addr) }             // R5 (flagged, default off)
                link.start()
            } catch (e: IOException) { g.close(); gattByAddr.remove(addr); fail(addr) }
        }
    }
    private fun dialerLinkClosed(g: BluetoothGatt, addr: String, l: Link) {
        if (!CLOSE_GATT_AFTER_L2CAP) { try { g.close() } catch (_: Exception) {} ; gattByAddr.remove(addr) }
        inFlight -= addr
        if (l.stableUp()) backoff.remove(addrToBkey[addr] ?: addr)                             // §6 reset after long-lived link
        // persistent scan re-discovers; backoff (if any) gates the re-dial
    }
    private fun fail(addr: String) {
        inFlight -= addr
        val key = addrToBkey[addr] ?: addr
        val remaining = (backoff[key] ?: 0L) - System.currentTimeMillis()
        val base = remaining.coerceAtLeast(500L)
        backoff[key] = System.currentTimeMillis() + minOf(base * 2, 30_000L) + (0..1000L).random()
        evictBackoff()                                                                         // R2: TTL bound
    }
    private fun evictBackoff() {
        val now = System.currentTimeMillis()
        backoff.entries.removeAll { it.value < now - LOST_MS }
    }
}

// ---- Top-level node: dedup map (§2.3) + scan-mode downshift + power-off teardown ----
class Node(ctx: Context) {
    private val linksByPeerId = HashMap<String, Link>()
    private val central: Central
    private val peripheral = Peripheral(ctx, myId, onLink = { onUp(it) }, onClose = { onClose(it) })
    init {
        central = Central(ctx, myId, onLink = { onUp(it) }, onClose = { onClose(it) },
            haveLinkTo = { synchronized(linksByPeerId) { linksByPeerId.containsKey(it.toHex()) } },
            haveLinkToPrefix = { pre -> synchronized(linksByPeerId) { val h = pre.toHex(); linksByPeerId.keys.any { it.startsWith(h) } } })
        peripheral.start(); central.start()
        Executors.newSingleThreadScheduledExecutor().scheduleAtFixedRate(
            { synchronized(linksByPeerId){ Log.i("HOPLOG","STATUS links=${linksByPeerId.size}") } }, 5, 5, TimeUnit.SECONDS)
    }
    @Synchronized private fun onUp(link: Link) {                                                // §2.3 dedup
        val peer = link.peerId ?: return; val key = peer.toHex()
        val existing = linksByPeerId[key]
        if (existing == null || existing === link) { linksByPeerId[key] = link; updateScan(); return }
        val keepDialed = gt(myId, peer)                                                         // keep MY dialed iff greater
        val keep = listOf(existing, link).firstOrNull { it.isDialer == keepDialed } ?: link
        val drop = if (keep === link) existing else link
        linksByPeerId[key] = keep                                                               // R3: set survivor BEFORE close
        drop.close("dedup"); updateScan()
        Log.i("HOPLOG","DEDUP kept isDialer=${keep.isDialer} peer=${key.take(8)}")
    }
    @Synchronized private fun onClose(link: Link) {                                             // R3: identity-checked removal
        val peer = link.peerId ?: return; val key = peer.toHex()
        if (linksByPeerId[key] === link) { linksByPeerId.remove(key); updateScan() }
    }
    fun closeAll() {                                                                            // R11: STATE_OFF receiver calls this
        val all = synchronized(linksByPeerId) { linksByPeerId.values.toList() }
        all.forEach { it.close("power-off") }
    }
    private fun updateScan() {
        if (linksByPeerId.isEmpty()) central.requestScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY, 2000)
        else central.requestScanMode(ScanSettings.SCAN_MODE_BALANCED, 10_000)                   // R9: 10s downshift hysteresis
    }
}
```

> **Adapter-state wiring (R11):** register a `BroadcastReceiver` for
> `BluetoothAdapter.ACTION_STATE_CHANGED`. On `STATE_OFF`: `node.closeAll()` and null
> scanner/advertiser/GATT-server/listener. On `STATE_ON`: rebuild both planes **without re-rolling
> `myId`** (re-open the listener, re-register the GATT service, re-advertise from `onServiceAdded`,
> re-scan). `onClose` is fully wired above (no "brevity" gaps): every `Link` removes itself from
> `linksByPeerId` only if it is still the current occupant.

---

## 10. Bring-up + reliability TEST procedure and pass/fail metrics

### 10.1 Build
- **Apple:** `swiftc -O -framework CoreBluetooth ble-lab/apple/main.swift -o ble-lab/apple/blepeer`
  (model on `apple/hopmac/build.sh`). First run from Terminal grants the Bluetooth permission.
- **Android:** model on `android/HopDemo` (`./gradlew installDebug`). Logcat tag `HOPLOG`. Cycle the
  stack with `adb shell cmd bluetooth_manager disable` / `enable`. **Test on at least one API 29 to 32
  device (R1):** confirm the deprecated 3-arg `onCharacteristicRead` path fires (the read completes
  and the L2CAP dial proceeds), a regression here is silent on API 33+.

### 10.2 Bring-up (clean radio first)
1. `adb shell cmd bluetooth_manager disable && adb shell cmd bluetooth_manager enable`, a freshly
   cycled stack avoids a wedged advertiser **[field]**.
2. Launch Android; confirm advertising via `adb shell dumpsys bluetooth_manager` (GATT Advertiser
   Map lists the service + connectable/scannable/legacy flags), or nRF Connect / LightBlue as ground
   truth. Confirm the advert appears **after** the service registers (R10).
3. Launch the macOS peer. Expect within ~3 s: scan → discover → connect → `didDiscoverServices` →
   read `[PSM|id]` → `openL2CAPChannel` → channel open → `HELLO` both ways → `UP`.

### 10.3 Staging
- **Stage A (table stakes):** macOS↔macOS, then Android↔Android. Exactly one channel; counters advance.
- **Stage B (THE BAR):** macOS CLI ↔ Android. Then iOS device ↔ Android (apply §8.1 threading and
  exercise the background scenario §10.5 #6 with the adaptive watchdog).
- **Optional Stage C (only if enabling `CLOSE_GATT_AFTER_L2CAP`):** on the target Android OEM, set
  the flag and confirm the proof counter keeps advancing **after** the GATT client closes (R5). If it
  stalls, the OEM drops the ACL on `gatt.close()`; leave the flag OFF for that hardware.

### 10.4 The metrics that prove "established AND maintained" (not "connected once")
Each peer logs a STATUS line every 5 s; assert over a long soak:

| Signal | Proves | Pass criterion |
|---|---|---|
| time(scan-start → first `HELLO`) | fast establishment | < 3 s in-room; < 10 s through one wall |
| live channel count per `peerNodeId` | single-channel convergence | **exactly 1**, ever; dedup-close logged if 2 briefly appeared |
| `rxSeq` increments by exactly 1 / s | no loss, no stall (the proof) | **0 gaps**; max inter-arrival < `DEAD` for the active state over the whole soak |
| PONG RTT | reverse direction live | bounded (< 200 ms in-room), no growth-to-timeout |
| false-dead count | watchdog isn't flapping a good link | **0** over a ≥ 1 h foreground soak; **0** over a ≥ 1 h background soak (adaptive deadline, R7) |
| reconnect latency after induced drop | automatic recovery | `UP` again within current backoff (≤ ~2 s first drop) |
| orphan/half-open L2CAP count | no channel-cap exhaustion | **0** (reaper fires on any orphan); no `Unknown error` open-storms |
| `startScan` count per 30 s | scan-throttle safety (R9) | **≤ 4** in any rolling 30 s window; scanner never goes silent |

### 10.5 Reliability scenarios (each indefinitely repeatable)
1. **Idle soak (≥ 1 h):** stationary; counter advances every second, 0 gaps, 0 false-dead.
2. **Induced ACL drop:** `adb shell cmd bluetooth_manager disable; sleep 2; … enable`. Both ends
   detect within `DEAD`, COOLDOWN→re-establish; `rxSeq` restarts cleanly; no duplicate channel; the
   nodeId is unchanged across the bounce (R11) so no transient second link appears.
3. **Meet/part cycles (×50+):** walk the macOS peer out of range until LOST, back in; each cycle
   re-establishes exactly one channel. No per-MAC/identifier state accumulation (TTL-bounded), no
   degradation.
4. **Address-rotation soak (hours):** the peer's RPA rotates repeatedly; the link persists or
   re-forms with **no duplicate**, dedup is by `nodeId`, backoff by the stable nodeId prefix (R2),
   so rotation is a non-event and the backoff/in-flight maps stay bounded.
5. **Contention:** add 2 to 3 extra centrals (more macOS peers / LightBlue). No orphan accumulation, no
   L2CAP-open `Unknown error` storms, tiebreaker + reaper + dial caps keep Android's budget healthy.
   If running near the GATT-client cap on Android, evaluate `CLOSE_GATT_AFTER_L2CAP` (R5, Stage C).
6. **iOS background (device only):** background the app; a service-filtered scan still discovers the
   Android peer and `connect` completes; with state restoration the app relaunches into the
   background on a peripheral event. The adaptive watchdog (15 s base in background) holds the link
   without false-dead despite the relaxed connection interval (R7); CB callbacks and streams run off
   the UI main thread (R8) so a UI hitch cannot starve them.

Concrete log lines to grep: `LINK CLOSED (...)`, `STATUS links=N`, `DEDUP kept ...`, `counter gap`.
Android: `adb logcat -s HOPLOG`. macOS: stdout (`setbuf(stdout, nil)` flushes under `timeout`). A
passing run shows two counters climbing in lockstep on both sides with **0 gaps** for the full
duration, channel count pinned at **1**, and automatic recovery after every induced fault.

---

## 11. Riskiest assumption (and the hedge)

**The single riskiest assumption: that iOS/macOS `openL2CAPChannel` reliably opens against an
Android `listenUsingInsecureL2capChannel` peripheral once GATT-first sequencing (connect → discover
all services → read a characteristic) is done.** This repo holds *conflicting* evidence:
`apple/hopmac` + the `ble-bearer-pure-l2cap-no-gatt` memory note say it works **iff** GATT
discovery + a characteristic read precede the open (which this design does: that read is the PSM/id
read), while `GattDataLink.kt` and the `HopLink.kt` reaper comment say CoreBluetooth returns
CBErrorDomain "Unknown error" opening L2CAP to Android, on some OEM stacks. The reaper (§5) and the
dial backoff (§6) already keep the system healthy when an open fails; if a *target* Android OEM
truly refuses L2CAP, drop in **Appendix B** with zero changes above it.

A **second** unverified assumption, surfaced by the review (R5): that the L2CAP CoC `BluetoothSocket`
survives `gatt.close()` because it rides its own channel on the LE ACL (ACL refcount independent of
the GATT client). This is **not** publicly documented, so `CLOSE_GATT_AFTER_L2CAP` defaults OFF and
is gated behind per-OEM verification (Stage C). The core proof does not depend on it.

Other risks, each already mitigated: a **backgrounded iOS advertiser is invisible to Android**
(mitigated by always keeping the iOS-central→Android-peripheral edge and the §2.2 wait-timeout;
never depend on Android seeing iOS); **iOS connection parameters aren't controllable** (mitigated by
the 1 Hz keepalive plus the adaptive background liveness deadline, R7); **double-connect races**
(mitigated by the §2.3 post-`HELLO` nonce dedup plus the pre-connect `haveLinkTo`/`haveLinkToPrefix`
guards, R4).

---

## Appendix A: iBeacon wake for a *killed* iOS peripheral (optional, iOS device only)
Broadcast a non-connectable iBeacon (`AdvertisingSet`, Apple company `0x004C`, payload `02 15
<BEACON_UUID> <major> <minor> <txpower>`) as a second concurrent set. The iOS app monitors a
`CLBeaconRegion(BEACON_UUID, notifyOnEntry, notifyEntryStateOnDisplay)` which relaunches the killed
app into the background, after which its central path dials normally. Not required for the core proof.

## Appendix B: GATT data-plane fallback (drop-in if L2CAP refuses on target hardware)
Reuse this repo's `GattDataLink.kt` verbatim. Add two characteristics to the service:
`RX_CHAR` (WRITE / WRITE_NO_RESPONSE, central→peripheral) and `TX_CHAR` (NOTIFY/INDICATE,
peripheral→central). When `openL2CAPChannel` errors (iOS `didOpen` error / Android
`createInsecureL2capChannel.connect()` throws), bind the **same §4 framing + §3.3 HELLO + §5
1 Hz PING/liveness** over GATT instead: central writes framed chunks of `MTU−3` to `RX_CHAR` with
strict one-op-at-a-time flow control (write → await completion → next), peripheral indicates back
over `TX_CHAR`. HELLO, PING/PONG, dedup, watchdog, and the state machine are all unchanged, only
the byte transport differs. This makes "pipe proven" hold even if cross-platform L2CAP never opens.

## Appendix C: Adversarial-review resolutions (R1 to R11)

| ID | Issue | Disposition | Where fixed |
|---|---|---|---|
| **R1** | Android 4-arg `onCharacteristicRead` is API 33+; on API 29 to 32 (the whole sub-33 `minSdk` field) only the deprecated 3-arg fires → read never completes, 0% cross-platform establishment | **ACCEPTED**: override **both** signatures into one `handleRead` | §3.2 step 5, §9 `gattCb`, §10.1 |
| **R2** | Backoff keyed by MAC/identifier (rotating RPA), not nodeId → maps grow unbounded and a flapping peer is never rate-limited after rotation; §6 prose was false | **ACCEPTED, refined**: backoff keyed by the **stable 6-byte nodeId prefix** (invariant across RPA rotation, available pre- and post-connect); MAC/identifier only for the short-lived in-flight guard and as pre-read fallback; all maps TTL-bounded | §2, §6, §8/§9 `backoff`/`addrToBkey`/`evictBackoff` |
| **R3** | `onClose` "brevity" glue (`remove(peerId)`) evicts the surviving link because both ends share the `peerId` key | **ACCEPTED**: set survivor in map *before* closing the dropped channel; `onClose` removes only if the closing link is still the current occupant (identity check) | §2.3, §8/§9 `Node.onClose`/`onUp` |
| **R4** | Wait-timeout (and iOS path) checked the central's own dial map, not the link map → redundant dial on every wait, multiplied by `allowDuplicates` | **ACCEPTED**: gate dials on the node link map (`haveLinkToPrefix`/`haveLinkTo`); dedupe wait closures (one per peer); add iOS pre-`openL2CAPChannel` `haveLinkTo` check | §2.1/§2.2, §3.2, §8/§9 |
| **R5** | Dialer never closes the GATT client → each link holds a scarce (~7) GATT-client slot for the session | **PARTIAL**: added `CLOSE_GATT_AFTER_L2CAP`, but **default OFF** (reviewer wanted ON): the ACL-survives-close assumption is undocumented and killing a live socket is worse than slot pressure for the core proof; enable only after Stage-C per-OEM verification | §7.2, §9, §10.3 Stage C, §11 |
| **R6** | iOS `connect()` has no timeout; `dial()` implemented none → permanent stall if peer vanishes mid-connect | **ACCEPTED**: real 12 s `DispatchWorkItem` timer → `cancelPeripheralConnection` → `reconnect` | §3.2, §8 `dial`/`dialTimedOut` |
| **R7** | Fixed 5 s liveness deadline false-trips a healthy backgrounded iOS link (relaxed connection interval) | **ACCEPTED**: adaptive deadline: 5 s foreground / 15 s background, floored at 3× observed inter-arrival (EWMA) | §0.1, §5, §8/§9 `deadLimit`/`ewmaGap` |
| **R8** | CB delegate + streams on `.main` is a foot-gun on a real iOS app (UI hitch → false-dead) | **ACCEPTED**: CLI stays on `.main` (no UI); iOS app uses a dedicated serial CB queue + a dedicated I/O thread/run loop for streams and timers | §7.5, §8.1 |
| **R9** | Scan-mode 0↔1 churn can trip Android's silent 5-starts/30 s throttle → dead scanner | **ACCEPTED**: downshift hysteresis (≥10 s stability) + a 30 s sliding-window guard that never issues the 5th start (defers it) | §7.3, §9 `requestScanMode`/`applyScan`, §10.4 |
| **R10** | Android advertises before async `addService` completes → fast central finds no service | **ACCEPTED**: advertise only from `onServiceAdded(GATT_SUCCESS)`; iOS re-adds service before re-advertising on `willRestoreState` | §3.1, §7.1, §9 |
| **R11** | Asymmetric nodeId re-roll on adapter cycle → transient duplicate link | **ACCEPTED**: nodeId is stable for the process lifetime on **both** platforms (no re-roll on adapter bounce); both proactively close all local links on power-off | §1.2, §6, §8/§9 |

**Affirmed correct by the review (unchanged):** MSB-first prefix-vs-full-id ordering is consistent
with the 16-byte dedup; the 2-channel dedup is symmetric (no livelock in the double-dial case); the
18-byte read fits a default 23-byte ATT MTU (no long-read handling); insecure CoC both ways,
`discoverServices(nil)`, single persistent scan, and always-`gatt.close()`-on-failure match field
reality.

---

## Sources
- Apple, Core Bluetooth Background Processing (overflow area; bg name dropped, UUIDs hashed): https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html
- David G. Young, Hacking the iOS BLE Overflow Area: https://davidgyoungtech.com/2020/05/07/hacking-the-overflow-area  •  repo: https://github.com/davidgyoung/ios-overflow-area
- Punch Through, iOS BLE Scanning guide (bg scan needs a service filter): https://punchthrough.com/ios-ble-scanning-guide/
- Punch Through, Android BLE guide (4-arg `onCharacteristicRead` added API 33; implement both below 33): https://punchthrough.com/android-ble-guide/
- Apple, `CBL2CAPChannel`: https://developer.apple.com/documentation/corebluetooth/cbl2capchannel  •  `publishL2CAPChannel(withEncryption:)`: https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/publishl2capchannel(withencryption:)
- Apple Developer Forums #675960, secure L2CAP fails iOS↔Android, insecure works: https://developer.apple.com/forums/thread/675960
- Apple Developer Forums #713800, iOS connection-interval floor 15 ms + periodic background callback disruption; L2CAP avoids GATT-cadence stalls: https://developer.apple.com/forums/thread/713800
- Silicon Labs, Apple connection-parameter guidance / RPA & IRK privacy: https://docs.silabs.com/bluetooth/latest/bluetooth-application-security-design-considerations/03-privacy-and-tracking
- Android, `ScanResult` (non-bonded `getAddress()` returns the rotating RPA): https://developer.android.com/reference/android/bluetooth/le/ScanResult
- JuulLabs/kable #588, cross-platform L2CAP (insecure works, secure fails): https://github.com/JuulLabs/kable/discussions/588
- Android, `listenUsingInsecureL2capChannel` / `createInsecureL2capChannel` / `BluetoothServerSocket.psm` (LE CoC, no bonding): https://developer.android.com/reference/android/bluetooth/BluetoothAdapter#listenUsingInsecureL2capChannel()
- Demystifying Android BLE "GATT Status 133" (connectGatt on main thread, always close, jittered backoff): https://dev.to/ble_advertiser/demystifying-android-ble-gatt-status-133-common-causes-and-robust-solutions-for-connection-32la
- Android BLE scan throttle, 5 startScan/30 s silent block; >30 min → opportunistic: https://punchthrough.com/android-ble-scan-errors/
- Apple, `startAdvertising(_:)` honored keys (service UUID + local name only): https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:)
- BLE throughput / L2CAP CoC MTU & credit-based flow control: https://github.com/chrisc11/ble-guides/blob/master/ble-throughput.md
- Repo field evidence: `apple/hopmac`, `android/HopDemo/.../HopLink.kt` + `GattDataLink.kt`; memory notes `ble-bearer-pure-l2cap-no-gatt`, `cross-platform-ble`.
```
