# Reliability-First Dual-Role BLE Transport — Design + Critical Source

> Goal: two devices (Android Kotlin, Apple Swift/CoreBluetooth), each running identical
> dual-role software, converge on **exactly one** bidirectional byte channel and **keep it
> alive forever** across drops, BLE address rotation, and repeated meet/part cycles. Prove the
> pipe (a per-second monotonic counter that never loses or stalls). Cross-platform
> Android↔Apple is the bar, not same-platform.

This design is grounded in current platform behavior (sources at the bottom) **and** in
hard-won field results from this repo's BLE bearer (the `hopmac` CLI + `HopDemo`). Where a
choice is empirically load-bearing it is called out as **[field]**.

---

## 0. The one-paragraph architecture (Ditto "mechanism A")

Each device is simultaneously a **peripheral** (advertises the service, runs an L2CAP
*listener*, and serves the listener's PSM from a single GATT characteristic) and a **central**
(scans for the service, connects, reads the PSM, opens the L2CAP channel). **All data flows over
the L2CAP connection-oriented channel (CoC); data NEVER rides GATT.** GATT is used only for the
tiny PSM/identity read that bootstraps the L2CAP open. The channel is **insecure** L2CAP (no
OS pairing/bonding) — the secure variant fails iOS↔Android **[field]**, and identity/crypto are
an upper layer's job. Convergence to a single channel is driven by an **ephemeral random 16-byte
node-id** carried in-band; reliability is driven by an **application-layer 1 Hz heartbeat** (which
doubles as the proof counter), fast dead-link detection, and a per-peer reconnect state machine.

Why this shape and not alternatives:
- **Why L2CAP CoC for data, not GATT notify/write?** CoC is a real flow-controlled byte stream
  with credit-based backpressure and SDU fragmentation up to a 64 KB+ MTU, so a single
  length-prefixed 64 KB frame just works; GATT would force MTU-sized chunking, ATT congestion,
  and reliability headaches. CoC is connection-oriented and duplex, exactly what we need.
- **Why a GATT read at all (not advert-only L2CAP)?** Advert-only L2CAP (publish PSM in the
  advert, `openL2CAPChannel` straight after connect) **does not work to Android [field]**:
  CoreBluetooth returns `CBErrorDomain 0 "Unknown error"` and Android's `accept()` never fires.
  GATT activity before the L2CAP open is what makes Android's stack accept the channel. This is
  precisely Ditto's documented design (central reads the PSM from a GATT characteristic).
- **Why insecure L2CAP?** Secure CoC requires a bonded/authenticated link key; iOS↔Android
  bonding is fragile and the task forbids OS-level pairing. Insecure CoC is link-key-free; the
  upper layer (Noise) provides authentication and confidentiality.

---

## 1. Identifiers, advertisement format, and the in-band tiebreaker

### 1.1 Fresh UUID scheme (assume nothing pre-existing)

```
SERVICE_UUID   = 7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F   // the dual-role service
ENDPOINT_CHAR  = 7ED70002-3C2A-4F19-9B8E-1A2B3C4D5E6F   // GATT read → [2B PSM][16B node-id]
BEACON_UUID    = 7ED7BEAC-0000-4000-8000-000000000000   // iBeacon proximity UUID (iOS wake)
MFG_COMPANY_ID = 0xFFFF                                  // "reserved for testing" company id
L2CAP_ENCRYPT  = false                                  // insecure CoC
```

### 1.2 The node-id (the unbiased, in-band tiebreaker — NOT MAC, NOT platform)

At process start each device generates a **random 16-byte `nodeId`** (CSPRNG). It is:
- **Ephemeral** (regenerated each app launch) but **stable for the whole session** — so it is a
  valid dedup key even while the BLE MAC rotates underneath it.
- **Unbiased**: pure randomness; no platform tag, no hardware address, no RSSI.
- **In-band**: carried in the advert (a 6-byte prefix, see below) and **authoritatively** in the
  L2CAP `HELLO` frame (all 16 bytes).

**Tiebreaker rule (single sentence):** *the channel that survives is the one initiated by the
device with the numerically lower `nodeId`.* Both ends compute this identically from in-band
data, so they converge without negotiation. (Astronomically-unlikely exact tie → both re-roll
`nodeId` and re-advertise.)

### 1.3 Advertisement layout (legacy 31-byte ADV_IND, what every scanner expects)

Primary advertisement (exactly 31 bytes, fits with no extended advertising):

| AD field | bytes | content |
|---|---|---|
| Flags | 3 | `02 01 06` (LE General Discoverable, BR/EDR not supported) |
| Complete 128-bit Service UUID | 18 | `11 07 <SERVICE_UUID little-endian>` |
| Manufacturer Specific Data | 10 | `09 FF FF FF <6-byte nodeId prefix>` |

Scan response (separate 31 bytes): the device name (debugging only; not load-bearing).

**Critical platform truth about the advert id [field + sources]:**
- **Android** advertises the 6-byte `nodeId` prefix in manufacturer data fine — so for the
  dominant cross-platform topology (iOS-central → Android-peripheral) and Android↔Android, the
  pre-connect tiebreaker has the data it needs to suppress redundant dials.
- **iOS/macOS peripherals cannot advertise manufacturer data at all.** `startAdvertising`
  honors only `CBAdvertisementDataServiceUUIDsKey` and `CBAdvertisementDataLocalNameKey`. And
  when an iOS app is **backgrounded**, the local name is dropped and the service UUID moves to
  the Apple-proprietary **overflow area** (manufacturer-data byte `0x01`), which only another
  iOS device explicitly scanning that UUID can decode — **Android cannot see it.**

Consequence (and it shapes the whole convergence design): **the advert-borne id is an
accelerator, available only when the peer is an Android peripheral. The authoritative tiebreaker
/ dedup signal is the 16-byte id in the L2CAP `HELLO`, which is ALWAYS present.** The protocol is
correct using only the `HELLO`; the advert id merely lets us avoid a redundant dial in the common
case.

---

## 2. Convergence engine: how two dual-role devices agree on ONE channel

Three cooperating mechanisms, in priority order. The first minimizes work; the last guarantees
correctness regardless of visibility asymmetry.

### 2.1 Pre-connect tiebreaker (fast path; needs advert id)

When a central discovers a peer whose advert carries a `nodeId` prefix:
- If `myNodeId < peerNodeIdPrefix` → **I dial** (become the L2CAP initiator).
- If `myNodeId > peerNodeIdPrefix` → **I wait** (stay peripheral toward this peer; the peer
  will dial me).
- If prefixes compare equal (6-byte collision) → fall through to §2.3 (dial + dedup).

This halves channel attempts in the Android-peripheral case and is the primary defense against
the concurrent-L2CAP-channel exhaustion that degrades a busy Android radio **[field]**.

### 2.2 Wait-timeout safety net (breaks visibility-asymmetry deadlocks)

The "waiter" from §2.1 starts a timer `T_wait = 4 s` (+ up to 1 s jitter) when it first sees the
peer. If no channel to that peer reaches `UP` before `T_wait` expires, the waiter **dials anyway**.

This is what makes the design robust when the side that *should* dial **can't see us** — e.g. we
are a backgrounded iOS peripheral (overflow area: Android can't see our advert id, so Android
never learns it should dial). The waiter (here, iOS-as-central, which *can* scan in background)
takes over. No platform bias is encoded; it is purely "if the assigned dialer didn't act, I do."

### 2.3 Post-`HELLO` dedup (universal backstop; always correct)

Whenever a channel reaches "HELLO exchanged," both ends know `(dialerId, acceptorId)`. If a
device finds it has **two** live channels to the same `peerNodeId`, it keeps exactly one using
the tiebreaker rule, computed identically on both ends:

```
KEEP  the channel where dialerId < acceptorId
CLOSE the channel where dialerId > acceptorId
```

For *my* dialed channel `(dialerId=me, acceptorId=peer)` I keep it iff `me < peer`; for *my*
accepted channel `(dialerId=peer, acceptorId=me)` I keep it iff `peer < me`. I therefore keep
exactly one, and the peer independently agrees. Result: even if both sides dial (no advert id,
or both safety-nets fired), the mesh collapses to a single channel within ~1 s, and the
redundant L2CAP is closed promptly (which also frees Android's scarce concurrent-channel slot).

**Dedup key = `nodeId`, never MAC.** When the peer's BLE MAC rotates mid-session, its advert
still carries the same `nodeId` and its `HELLO` still carries the same 16 bytes, so we recognize
"already linked, do not re-dial" and the rotation is transparent.

---

## 3. The EXACT channel-open handshake (every call, in order, both sides, both platforms)

Notation: **DIALER** = the central that the convergence engine selected. **ACCEPTOR** = the
peripheral. Every device runs both roles concurrently; a given *link* has one of each end.

### 3.1 ACCEPTOR setup (done once at startup, kept alive for the whole session)

Keeping the listener and PSM **stable for the session** is a deliberate reliability choice: a
fresh `listenUsing…` mints a **new PSM** each call, which strands any peer that cached the old
one. Open the listener once; only re-open on failure, and when you do, update the GATT
characteristic and invalidate the peer's GATT cache (§5.4).

**iOS / macOS (CBPeripheralManager):**
1. `CBPeripheralManager(delegate:queue:options:[CBPeripheralManagerOptionRestoreIdentifierKey: "hop.ble.peripheral"])`
2. `peripheralManagerDidUpdateState` → `.poweredOn`:
3. Build GATT: `let svc = CBMutableService(type: SERVICE_UUID, primary: true)`;
   `let ch = CBMutableCharacteristic(type: ENDPOINT_CHAR, properties: .read, value: nil,
   permissions: .readable)` (value `nil` ⇒ dynamic read, answered live); `svc.characteristics =
   [ch]`; `peripheralManager.add(svc)`.
4. `peripheralManager.publishL2CAPChannel(withEncryption: false)`.
5. `peripheralManager(_:didPublishL2CAPChannel:error:)` → store `psm` (this is what the GATT char
   returns).
6. `peripheralManager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID],
   CBAdvertisementDataLocalNameKey: name])`. (No mfg data is possible on iOS — see §1.3.)
7. **On read:** `peripheralManager(_:didReceiveRead:)` → `request.value = psm(2B BE) || nodeId(16B)`;
   `peripheralManager.respond(to: request, withResult: .success)`.
8. **On inbound L2CAP:** `peripheralManager(_:didOpen channel:error:)` → wrap
   `channel.inputStream`/`channel.outputStream`, `schedule(in: .main, forMode: .common)`, `open()`.
   Start the **HELLO-reap timer (3 s)**; role = acceptor.

**Android (peripheral):**
1. `serverSocket = adapter.listenUsingInsecureL2capChannel()`  → `val psm = serverSocket.psm`
   (LE-only CoC).
2. Accept loop on a worker thread: `while (running) { val sock = serverSocket.accept();
   handleAccepted(sock) }`. Each accepted socket → wrap `sock.inputStream`/`sock.outputStream`,
   start the **HELLO-reap timer (3 s)**; role = acceptor.
3. GATT server: `gattServer = manager.openGattServer(ctx, gattServerCb)`;
   `val svc = BluetoothGattService(SERVICE_UUID, SERVICE_TYPE_PRIMARY)`;
   `val ch = BluetoothGattCharacteristic(ENDPOINT_CHAR, PROPERTY_READ, PERMISSION_READ)`;
   `svc.addCharacteristic(ch)`; `gattServer.addService(svc)`.
4. **On read:** `onCharacteristicReadRequest` → `gattServer.sendResponse(device, requestId,
   GATT_SUCCESS, 0, psm(2B BE) || nodeId(16B))`.
5. Advertise via `startAdvertisingSet` in **legacy mode** (see §5.1), service UUID + 6-byte
   nodeId prefix in mfg data; name in scan response; idempotent self-heal each tick.

### 3.2 DIALER open sequence

**iOS / macOS (CBCentralManager):**
1. `CBCentralManager(delegate:queue:options:[CBCentralManagerOptionRestoreIdentifierKey:
   "hop.ble.central"])`.
2. `centralManagerDidUpdateState` → `.poweredOn`:
   `scanForPeripherals(withServices: [SERVICE_UUID], options:
   [CBCentralManagerScanOptionAllowDuplicatesKey: true])`. **Filtering by service UUID is
   mandatory for background scan**; `allowDuplicates` is honored in foreground (so a peer
   mid-restart is re-seen) and silently ignored in background.
3. `centralManager(_:didDiscover:advertisementData:rssi:)` → parse mfg `nodeId` prefix if
   present → run §2 convergence. If we dial: **retain the `CBPeripheral` in a strong map**
   (else it deallocs and the connect silently dies), set its delegate, `central.connect(p,
   options: nil)`, start a **dial-timeout (12 s)**.
4. `centralManager(_:didConnect:)` → `p.discoverServices(nil)`. **Use `nil` (discover all), not
   `[SERVICE_UUID]`** — targeted discovery *stalls* against Android's GATT server; full discovery
   (what LightBlue does) succeeds **[field]**.
5. `peripheral(_:didDiscoverServices:)` → find `SERVICE_UUID` →
   `p.discoverCharacteristics([ENDPOINT_CHAR], for: svc)`.
6. `peripheral(_:didDiscoverCharacteristicsFor:error:)` → `p.readValue(for: ch)`.
7. `peripheral(_:didUpdateValueFor:error:)` → parse `[2B PSM][16B peerNodeId]`; store peerNodeId;
   `p.openL2CAPChannel(psm)`.
8. `peripheral(_:didOpen channel:error:)`:
   - error ⇒ peer likely re-listened (stale PSM) → drop cached PSM, `p.discoverServices(nil)` to
     re-read, or back off (§4.4).
   - success ⇒ wrap `channel.inputStream`/`channel.outputStream`,
     `schedule(in: .main, forMode: .common)`, `open()`. **Keep streams on the MAIN runloop — moving
     them to a private thread breaks Noise/data flow [field].** Send `HELLO`; start 1 Hz PING +
     liveness watchdog; role = dialer.

**Android (central):**
1. `scanner.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()),
   ScanSettings.Builder().setScanMode(scanMode).build(), scanCb)`. `scanMode` =
   `SCAN_MODE_LOW_LATENCY` for a short burst after a drop/expected meet, `SCAN_MODE_BALANCED`
   steady-state — **continuous LOW_LATENCY scanning starves the peripheral role [field]**.
2. `onScanResult` → parse mfg `nodeId` prefix → §2 convergence. If we dial AND
   `dialsInFlight < MAX_DIALS_IN_FLIGHT (2)` AND not in per-peer backoff:
   `device.connectGatt(ctx, /*autoConnect=*/false, gattCb, BluetoothDevice.TRANSPORT_LE)`
   **on the main thread** (a frequent status-133 cause is connecting off the binder/scan thread
   **[field]**). Start a **dial-timeout (12 s)**.
3. `onConnectionStateChange(STATE_CONNECTED)` → `gatt.requestConnectionPriority(
   CONNECTION_PRIORITY_HIGH)` (fast param negotiation + lower supervision timeout during setup),
   then `gatt.discoverServices()`.
4. `onServicesDiscovered` → `val ch = gatt.getService(SERVICE_UUID).getCharacteristic(
   ENDPOINT_CHAR)`; `gatt.readCharacteristic(ch)`.
5. `onCharacteristicRead` → parse `[2B PSM][16B peerNodeId]`; store peerNodeId.
6. `val sock = device.createInsecureL2capChannel(psm)`; on a **worker thread** `sock.connect()`
   (blocking). On success → wrap `sock.inputStream`/`sock.outputStream`; send `HELLO`; start 1 Hz
   PING + liveness; `gatt.requestConnectionPriority(CONNECTION_PRIORITY_BALANCED)` after `HELLO`
   (save power once stable); role = dialer.
7. `onConnectionStateChange(STATE_DISCONNECTED)` or any failure/status-133 → **`gatt.close()`
   (mandatory — leaked GATT clients exhaust Android's cap and kill all future connects [field])**,
   free the dial slot, apply backoff (§4.4).

### 3.3 The `HELLO` exchange (the moment the channel becomes a real link)

Immediately after the L2CAP channel opens, **each** side sends one `HELLO` frame and waits for
the peer's. The link is `UP` only after `HELLO` is both sent and received. The acceptor's 3 s
**HELLO-reap** closes any channel that never delivers a `HELLO` — this kills the *half-open
orphans* (Android `accept()` succeeded but the central abandoned its end) that otherwise pile up
and exhaust the concurrent-channel cap **[field]**.

```
HELLO frame body:  [0x01][16B nodeId][1B role: 0=acceptor 1=dialer][1B flags]
```

On receiving `HELLO`: record `peerNodeId`, run §2.3 dedup, transition `DIALING/ACCEPTING → UP`.

---

## 4. Reliability: framing, keepalive, liveness, and the recovery state machine

This is the heart of the design. Assume the radio is hostile and flaky.

### 4.1 Framing (identical on both platforms; carries the proof counter)

4-byte big-endian length prefix + body. Body byte 0 is the type.

```
[len:u32 BE][ body (len bytes) ]
body = [type:u8][ payload ]
  0x01 HELLO  : [16B nodeId][1B role][1B flags]
  0x02 PING   : [seq:u64 BE][t_send_ms:u64 BE]   // seq is the monotonic PROOF COUNTER
  0x03 PONG   : [seq:u64 BE][t_send_ms:u64 BE]   // echoes a PING (RTT + bidirectional liveness)
  0x10 DATA   : [opaque upper-layer bytes]        // the real payload later (Noise, messages)
```

Writers must handle partial writes (buffer the tail, flush on "space available"); readers must
reassemble across reads (accumulate, deframe complete frames). A 64 KB `DATA` frame is a single
length-prefixed frame; L2CAP CoC fragments/reassembles the SDU transparently (MTU negotiated up
to 64 KB+; iOS internally fragments above ~2 KB, invisibly).

### 4.2 Keepalive + proof counter (1 Hz)

Each side emits a `PING` **every 1000 ms** with `seq = ++txCounter`. The peer:
- replies `PONG` (gives RTT and proves the *reverse* direction is live), and
- verifies `seq == lastRxSeq + 1` — **any gap = packet loss**, **stale `seq` for too long =
  stall**. This is the literal "monotonically increasing counter that the peer's stream must
  advance with no loss or stall" the proof requires. The keepalive and the proof are the same
  traffic — no idle channel ever exists.

### 4.3 Liveness / fast dead-link detection (defense in depth)

Three independent detectors, fastest wins:
1. **App-layer watchdog (primary).** Track `lastRxMs` (any frame). If `now - lastRxMs >
   DEAD_MS = 5000` (5 missed 1 Hz beats), declare the link **dead**, close streams, tear down,
   and trigger recovery. This is the only detector that catches a **wedged-but-connected**
   channel (ACL alive, L2CAP stream stalled) — which the BLE supervision timeout will *not*
   catch.
2. **BLE disconnect callback (secondary, fast path).** iOS `didDisconnectPeripheral` / Android
   `onConnectionStateChange(STATE_DISCONNECTED)` fire on a real ACL loss. Android's supervision
   timeout is ~5 s when we requested `CONNECTION_PRIORITY_HIGH` during setup, ~20 s on
   `BALANCED`; we keep `BALANCED` steady-state for battery but the app watchdog (5 s) is the
   real floor.
3. **Stream end/error events** (`endEncountered`/`errorOccurred`; `IOException` on the Android
   stream) → immediate teardown.

`DEAD_MS = 5000` with a 1 Hz beat is the chosen reliability/false-positive tradeoff: fast enough
to recover within seconds, lenient enough (5 misses) to ride out a brief radio stall without
flapping a still-good link.

### 4.4 Per-peer reconnect / recovery state machine (keyed by `nodeId`, never MAC)

```
          discover advert (service UUID seen)
   LOST ───────────────────────────────────────────► SEEN
    ▲                                                   │  §2 says "I dial"  (or T_wait fired)
    │ advert gone > LOST_MS (30s)                       ▼
    │                                            DIALING ──(GATT+PSM+L2CAP+HELLO ok)──► UP
    │                                                │                                   │
    │      dial-timeout / fail / status-133          │                                   │
    └──────────────── COOLDOWN ◄─────────────────────┘                                   │
                         ▲   │ backoff elapsed → SEEN/DIALING                             │
                         │   └─────────────────────────────────────────────────────────►│
                         │      DEAD_MS watchdog OR BLE disconnect OR dedup-close         │
                         └────────────────────────────────────────────────────────────  ┘
```

- **COOLDOWN backoff:** anti-flap 1 s after any drop, then exponential 1 s→2 s→4 s→…→**30 s cap**
  on repeated failures, **+ jitter**; reset to 1 s after a link stayed `UP ≥ 30 s`. Cheap, fast
  recovery for transient drops; gentle on a genuinely absent/failing peer (so the central never
  hammers it with `connectGatt` storms that starve our own peripheral **[field]**).
- **Concurrency caps:** `MAX_DIALS_IN_FLIGHT = 2`; 12 s dial-timeout so one hung dial can't block
  progress; stagger dials. The §2 tiebreaker keeps the steady-state channel count at exactly one
  per peer.
- **Address rotation:** new MAC + same `nodeId` while `UP` ⇒ ignore (already linked). New MAC +
  same `nodeId` while `LOST` ⇒ normal re-establish. Rotation is invisible to the link.
- **Meet/part forever:** part = `DEAD_MS`/disconnect → COOLDOWN → LOST; meet = advert seen →
  SEEN → … → UP. No persistent per-MAC state accumulates, so the cycle runs indefinitely.

---

## 5. Platform-specific reliability rules (all field-verified in this repo)

### 5.1 Android advertiser — use `startAdvertisingSet`, legacy mode
Legacy `startAdvertising(...)` with `setIncludeDeviceName(true)` **silently omits the GAP name**
on Pixel. `startAdvertisingSet(AdvertisingSetParameters.Builder().setLegacyMode(true)
.setConnectable(true).setScannable(true)…, advData, scanResponse, null, null, callback)` emits
it. A connectable `AdvertisingSet` **persists across connections** — so do **not** stop/restart
it per accepted connection (that resets the scan response and races incoming connects into
`CONNECTION_ACCEPT_TIMEOUT`). Make `startAdvertise()` idempotent, null the handle in
`onAdvertisingSetStopped`, and self-heal from the tick loop (`if (ticks % 30 == 0)
startAdvertise()` — no-op while live; recovers a silently-wedged advertiser).

### 5.2 Android GATT lifecycle — always `gatt.close()`
On any connect failure/disconnect, `gatt.close()` and remove from the in-flight set, or leaked
GATT clients exhaust Android's cap and every later connect times out. `connectGatt` on the main
thread. `autoConnect = false` (aggressive, fast) for the active dial; rely on our own state
machine for re-establish rather than `autoConnect=true`'s opaque, slow background reconnect.

### 5.3 Android radio sharing — don't let central starve peripheral
Continuous `SCAN_MODE_LOW_LATENCY` + failing `connectGatt`s saturate the radio so peers can't
even *discover* this device. Steady-state `SCAN_MODE_BALANCED`; LOW_LATENCY only in short bursts;
cap dials; back off. In the dominant iOS↔Android topology Android barely needs to scan (iOS is
the central; Android is the always-on discoverable peripheral).

### 5.4 iOS GATT cache + PSM staleness
iOS caches GATT handles/values. If the Android peripheral re-creates its GATT or re-listens
(new PSM), iOS may keep opening L2CAP with a **stale PSM** (`No such L2CAP connection`,
errors 431/436). Mitigations: (a) keep the L2CAP listener + PSM stable for the session (§3.1);
(b) implement `peripheral(_:didModifyServices:)` → drop cached PSM and re-discover; (c) when the
peripheral *must* re-listen, remove+re-add the GATT service to force a structure change so iOS
re-reads.

### 5.5 iOS background + state restoration
Set `UIBackgroundModes = [bluetooth-central, bluetooth-peripheral]` and
`NSBluetoothAlwaysUsageDescription`. Pass `CBCentralManagerOptionRestoreIdentifierKey` /
`CBPeripheralManagerOptionRestoreIdentifierKey` and handle `willRestoreState` so iOS can
relaunch the app into the background with connections intact and pending connects re-armed (a
central `connect` never times out, so it completes when the peer returns). Background scan still
works **only** with a service-UUID filter.

### 5.6 The cross-platform wake (optional but recommended for "backgrounded peer")
A **suspended/killed iOS peripheral is invisible to Android** (overflow area + no mfg data). To
let Android initiate to an iOS device that isn't running, also broadcast a **non-connectable
iBeacon** (`AdvertisingSet`, Apple company `0x004C`, payload `02 15 <BEACON_UUID> <major>
<minor> <txpower>`); the iOS app monitors a `CLBeaconRegion(BEACON_UUID, notifyOnEntry,
notifyEntryStateOnDisplay)` which **relaunches the killed app into the background**, after which
its central path dials normally. iBeacon (~25 B) needs its own advert; run it as a second
concurrent set alongside the connectable Hop advert.

---

## 6. Critical source — Apple (Swift / CoreBluetooth)

The macOS CLI is the fast iteration loop (build with `swiftc -framework CoreBluetooth`, model on
`apple/hopmac/build.sh`); the same types are iOS-faithful. Below is the reliability-critical
core: the framed, heartbeat-driven link, plus both roles' delegate paths.

```swift
import Foundation
import CoreBluetooth

let SERVICE_UUID = CBUUID(string: "7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F")
let ENDPOINT_CHAR = CBUUID(string: "7ED70002-3C2A-4F19-9B8E-1A2B3C4D5E6F")
let PING_MS = 1.0           // 1 Hz keepalive + proof counter
let DEAD_S  = 5.0           // declare dead after 5 s of silence
let HELLO_REAP_S = 3.0      // close half-open channels with no HELLO

func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

// One L2CAP link: 4-byte BE length framing, 1 Hz PING (proof counter), liveness watchdog.
final class Link: NSObject, StreamDelegate {
    let isDialer: Bool
    let myId: Data
    var peerId: Data?              // learned from HELLO; the dedup/tiebreaker key
    var up = false
    private let input: InputStream, output: OutputStream
    private var inBuf = [UInt8](), outBuf = [UInt8]()
    private var lastRxMs = nowMs(); private var openedMs = nowMs()
    private var txSeq: UInt64 = 0; private var rxSeq: UInt64 = 0
    private var ping: Timer?, watchdog: Timer?
    private let onUp: (Link) -> Void
    private let onClose: (Link) -> Void
    private var closed = false

    init(channel: CBL2CAPChannel, isDialer: Bool, myId: Data,
         onUp: @escaping (Link) -> Void, onClose: @escaping (Link) -> Void) {
        self.isDialer = isDialer; self.myId = myId; self.onUp = onUp; self.onClose = onClose
        self.input = channel.inputStream; self.output = channel.outputStream
        super.init()
        for s in [input, output] { s.delegate = self; s.schedule(in: .main, forMode: .common); s.open() }
        // send HELLO immediately
        var body = Data([0x01]); body.append(myId)
        body.append(isDialer ? 1 : 0); body.append(0)
        sendFrame(body)
        ping = Timer.scheduledTimer(withTimeInterval: PING_MS, repeats: true) { [weak self] _ in self?.sendPing() }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !self.up && Double(nowMs() - self.openedMs)/1000 > HELLO_REAP_S { self.close("no-HELLO reap") }
            if self.up && Double(nowMs() - self.lastRxMs)/1000 > DEAD_S { self.close("liveness DEAD") }
        }
    }
    private func sendPing() {
        txSeq += 1
        var b = Data([0x02]); appendU64(&b, txSeq); appendU64(&b, nowMs()); sendFrame(b)
    }
    private func sendFrame(_ body: Data) {
        guard !closed else { return }
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { outBuf.append(contentsOf: $0) }
        outBuf.append(contentsOf: body); drain()
    }
    func close(_ why: String) {
        guard !closed else { return }; closed = true
        ping?.invalidate(); watchdog?.invalidate()
        for s in [input, output] { s.close(); s.remove(from: .main, forMode: .common) }
        onClose(self)
    }
    func stream(_ s: Stream, handle e: Stream.Event) {
        switch e {
        case .hasBytesAvailable: read()
        case .hasSpaceAvailable: drain()
        case .endEncountered, .errorOccurred: close("stream end/error")
        default: break
        }
    }
    private func drain() {
        while !outBuf.isEmpty && output.hasSpaceAvailable {
            let n = output.write(outBuf, maxLength: outBuf.count)
            if n > 0 { outBuf.removeFirst(n) } else { break }
        }
    }
    private func read() {
        var tmp = [UInt8](repeating: 0, count: 16384)
        while input.hasBytesAvailable {
            let n = input.read(&tmp, maxLength: tmp.count)
            if n > 0 { inBuf.append(contentsOf: tmp[0..<n]) } else { break }
        }
        lastRxMs = nowMs(); deframe()
    }
    private func deframe() {
        while inBuf.count >= 4 {
            let len = Int(UInt32(inBuf[0]) << 24 | UInt32(inBuf[1]) << 16 | UInt32(inBuf[2]) << 8 | UInt32(inBuf[3]))
            let total = 4 + len; guard inBuf.count >= total, len >= 1 else { break }
            handle(Array(inBuf[4..<total])); inBuf.removeFirst(total)
        }
    }
    private func handle(_ body: [UInt8]) {
        switch body[0] {
        case 0x01:                                   // HELLO
            if body.count >= 17 { peerId = Data(body[1..<17]); up = true; onUp(self) }
        case 0x02:                                   // PING → verify counter, reply PONG
            let seq = u64(body, 1)
            if rxSeq != 0 && seq != rxSeq + 1 { print("⚠️ counter gap: \(rxSeq) -> \(seq)") }
            rxSeq = seq
            var p = Data([0x03]); p.append(contentsOf: body[1..<min(17, body.count)]); sendFrame(p)
        case 0x03: break                             // PONG (RTT/reverse liveness; already bumped lastRxMs)
        default: break                               // 0x10 DATA → hand to upper layer
        }
    }
    private func appendU64(_ d: inout Data, _ v: UInt64) { var be = v.bigEndian; withUnsafeBytes(of: &be){ d.append(contentsOf:$0) } }
    private func u64(_ b: [UInt8], _ o: Int) -> UInt64 { var v: UInt64 = 0; for i in 0..<8 { v = v << 8 | UInt64(b[o+i]) }; return v }
}

// ---- ACCEPTOR (peripheral) ----
final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    var pm: CBPeripheralManager!
    var psm: CBL2CAPPSM = 0
    let myId: Data
    let onLink: (Link) -> Void
    init(myId: Data, onLink: @escaping (Link) -> Void) { self.myId = myId; self.onLink = onLink; super.init()
        pm = CBPeripheralManager(delegate: self, queue: .main,
             options: [CBPeripheralManagerOptionRestoreIdentifierKey: "hop.ble.peripheral"]) }
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        guard p.state == .poweredOn else { return }
        let ch = CBMutableCharacteristic(type: ENDPOINT_CHAR, properties: .read, value: nil, permissions: .readable)
        let svc = CBMutableService(type: SERVICE_UUID, primary: true); svc.characteristics = [ch]
        p.add(svc)
        p.publishL2CAPChannel(withEncryption: false)        // INSECURE — secure fails iOS<->Android
    }
    func peripheralManager(_ p: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        psm = PSM
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID],
                            CBAdvertisementDataLocalNameKey: "hop"])   // iOS can't advertise mfg data
    }
    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead req: CBATTRequest) {
        var v = Data([UInt8(psm >> 8), UInt8(psm & 0xff)]); v.append(myId)   // [2B PSM][16B id]
        req.value = v; p.respond(to: req, withResult: .success)
    }
    func peripheralManager(_ p: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel else { return }
        let link = Link(channel: channel, isDialer: false, myId: myId, onUp: onLink, onClose: { _ in })
        onLink(link)
    }
    func peripheralManager(_ p: CBPeripheralManager, willRestoreState dict: [String: Any]) { /* re-arm */ }
}

// ---- DIALER (central) ----
final class Central: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var cm: CBCentralManager!
    let myId: Data
    var retained = [UUID: CBPeripheral]()
    var psmByPeer = [UUID: CBL2CAPPSM]()
    var backoff = [UUID: Double]()
    let shouldDial: (Data?) -> Bool                 // §2 convergence decision from advert nodeId
    let onLink: (Link) -> Void
    init(myId: Data, shouldDial: @escaping (Data?) -> Bool, onLink: @escaping (Link) -> Void) {
        self.myId = myId; self.shouldDial = shouldDial; self.onLink = onLink; super.init()
        cm = CBCentralManager(delegate: self, queue: .main,
             options: [CBCentralManagerOptionRestoreIdentifierKey: "hop.ble.central"]) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: [SERVICE_UUID],            // service filter REQUIRED for bg scan
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData d: [String: Any], rssi: NSNumber) {
        var advId: Data? = nil
        if let mfg = d[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 8,
           mfg[0] == 0xFF, mfg[1] == 0xFF { advId = mfg.subdata(in: 2..<8) }   // 6-byte nodeId prefix
        guard retained[p.identifier] == nil, shouldDial(advId) else { return }
        retained[p.identifier] = p; p.delegate = self
        c.connect(p, options: nil)                  // no timeout → we add our own dial-timeout elsewhere
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices(nil) } // nil!
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { reconnect(p) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { reconnect(p) }
    func peripheral(_ p: CBPeripheral, didModifyServices invalidated: [CBService]) {
        psmByPeer[p.identifier] = nil; p.discoverServices(nil)            // defeat stale-PSM/GATT cache
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == SERVICE_UUID { p.discoverCharacteristics([ENDPOINT_CHAR], for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == ENDPOINT_CHAR { p.readValue(for: ch) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value, v.count >= 2 else { return }
        let psm = CBL2CAPPSM(UInt16(v[0]) << 8 | UInt16(v[1])); psmByPeer[p.identifier] = psm
        p.openL2CAPChannel(psm)
    }
    func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if error != nil { psmByPeer[p.identifier] = nil; p.discoverServices(nil); return }  // stale PSM → re-read
        guard let channel else { return }
        let link = Link(channel: channel, isDialer: true, myId: myId, onUp: onLink, onClose: { _ in })
        onLink(link)
    }
    func reconnect(_ p: CBPeripheral) {
        let delay = min((backoff[p.identifier] ?? 1) * 2, 30); backoff[p.identifier] = delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + Double.random(in: 0...1)) { [weak self] in
            guard let self, let pp = self.retained[p.identifier] else { return }; self.cm.connect(pp, options: nil)
        }
    }
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) { /* re-arm scan + pending */ }
}
```

The top-level glue (one per process) holds `myId`, both `Central` and `Peripheral`, a
`linksByPeerId` map, and implements §2.3 dedup in the shared `onLink`/`onUp` callback:

```swift
var linksByPeerId = [Data: Link]()
func onUp(_ link: Link) {
    guard let peer = link.peerId else { return }
    if let existing = linksByPeerId[peer], existing !== link {
        // keep the channel initiated by the lower nodeId; close the other (both ends agree)
        let keepMineDialed = myId.lexBefore(peer)
        let keep = keepMineDialed ? (link.isDialer ? link : existing) : (link.isDialer ? existing : link)
        let drop = (keep === link) ? existing : link
        drop.close("dedup"); linksByPeerId[peer] = keep
    } else { linksByPeerId[peer] = link }
}
```

---

## 7. Critical source — Android (Kotlin)

Model the build on `android/HopDemo` (gradlew + SDK config). Permissions:
`BLUETOOTH_ADVERTISE`, `BLUETOOTH_SCAN` (`usesPermissionFlags="neverForLocation"`),
`BLUETOOTH_CONNECT`. The reliability-critical core:

```kotlin
val SERVICE_UUID  = ParcelUuid.fromString("7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F")
val ENDPOINT_CHAR = UUID.fromString("7ED70002-3C2A-4F19-9B8E-1A2B3C4D5E6F")
const val MFG_ID = 0xFFFF
const val PING_MS = 1000L
const val DEAD_MS = 5000L
const val HELLO_REAP_MS = 3000L
const val MAX_DIALS_IN_FLIGHT = 2

// One L2CAP link over a BluetoothSocket: 4-byte BE framing, 1 Hz PING (proof counter), watchdog.
class Link(
    private val socket: BluetoothSocket,
    val isDialer: Boolean,
    private val myId: ByteArray,
    private val onUp: (Link) -> Unit,
    private val onClose: (Link) -> Unit,
) {
    @Volatile var peerId: ByteArray? = null
    @Volatile var up = false
    @Volatile private var lastRxMs = System.currentTimeMillis()
    private val openedMs = System.currentTimeMillis()
    private var txSeq = 0L; private var rxSeq = 0L
    @Volatile private var closed = false
    private val out = socket.outputStream; private val inp = socket.inputStream
    private val writeLock = Any()
    private val sched = Executors.newSingleThreadScheduledExecutor()

    fun start() {
        sendFrame(byteArrayOf(0x01) + myId + byteArrayOf(if (isDialer) 1 else 0, 0))   // HELLO
        thread(name = "l2cap-rx") { readLoop() }
        sched.scheduleAtFixedRate({ tick() }, PING_MS, PING_MS, TimeUnit.MILLISECONDS)
    }
    private fun tick() {
        if (!up && System.currentTimeMillis() - openedMs > HELLO_REAP_MS) { close("no-HELLO reap"); return }
        if (up && System.currentTimeMillis() - lastRxMs > DEAD_MS) { close("liveness DEAD"); return }
        txSeq++; sendFrame(byteArrayOf(0x02) + u64(txSeq) + u64(System.currentTimeMillis()))   // PING
    }
    private fun sendFrame(body: ByteArray) {
        if (closed) return
        val len = body.size
        val hdr = byteArrayOf((len ushr 24).toByte(), (len ushr 16).toByte(), (len ushr 8).toByte(), len.toByte())
        try { synchronized(writeLock) { out.write(hdr); out.write(body); out.flush() } }
        catch (e: IOException) { close("write: ${e.message}") }
    }
    private fun readLoop() {
        val hdr = ByteArray(4)
        try {
            while (!closed) {
                readFully(hdr, 4); val len = ((hdr[0].i shl 24) or (hdr[1].i shl 16) or (hdr[2].i shl 8) or hdr[3].i)
                if (len < 1 || len > 1 shl 20) { close("bad len"); return }
                val body = ByteArray(len); readFully(body, len)
                lastRxMs = System.currentTimeMillis(); handle(body)
            }
        } catch (e: IOException) { close("read: ${e.message}") }
    }
    private fun readFully(b: ByteArray, n: Int) {
        var off = 0; while (off < n) { val r = inp.read(b, off, n - off); if (r < 0) throw IOException("eof"); off += r }
    }
    private fun handle(b: ByteArray) {
        when (b[0].toInt()) {
            0x01 -> if (b.size >= 17) { peerId = b.copyOfRange(1, 17); up = true; onUp(this) }   // HELLO
            0x02 -> {                                                                            // PING
                val seq = u64dec(b, 1)
                if (rxSeq != 0L && seq != rxSeq + 1) Log.w("HOP", "counter gap $rxSeq -> $seq")
                rxSeq = seq
                sendFrame(byteArrayOf(0x03) + b.copyOfRange(1, minOf(17, b.size)))               // PONG
            }
            // 0x03 PONG: lastRxMs already bumped; 0x10 DATA → upper layer
        }
    }
    fun close(why: String) {
        if (closed) return; closed = true
        sched.shutdownNow(); try { socket.close() } catch (_: IOException) {}
        onClose(this)
    }
    private fun u64(v: Long) = ByteArray(8) { (v ushr (56 - it * 8)).toByte() }
    private fun u64dec(b: ByteArray, o: Int): Long { var v = 0L; for (i in 0..7) v = (v shl 8) or (b[o + i].toLong() and 0xff); return v }
    private val Byte.i get() = toInt() and 0xff
}

// ---- ACCEPTOR (peripheral): L2CAP listener (session-stable PSM) + GATT PSM char + advertiser ----
class Peripheral(private val ctx: Context, private val myId: ByteArray, private val onLink: (Link) -> Unit) {
    private val adapter = (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    private lateinit var server: BluetoothServerSocket
    @Volatile private var psm = 0
    private var gattServer: BluetoothGattServer? = null
    private var advSet: AdvertisingSet? = null

    fun start() {
        server = adapter.listenUsingInsecureL2capChannel()   // INSECURE LE CoC; mints a PSM
        psm = server.psm
        thread(name = "l2cap-accept") {                      // one accept loop for the whole session
            while (true) {
                val sock = try { server.accept() } catch (e: IOException) { break }
                val link = Link(sock, isDialer = false, myId, onLink, onClose = {})
                onLink(link); link.start()                   // HELLO-reap closes orphans
            }
        }
        startGattServer(); startAdvertise()
    }
    private fun startGattServer() {
        val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        gattServer = mgr.openGattServer(ctx, object : BluetoothGattServerCallback() {
            override fun onCharacteristicReadRequest(d: BluetoothDevice, reqId: Int, off: Int, ch: BluetoothGattCharacteristic) {
                val v = byteArrayOf((psm ushr 8).toByte(), psm.toByte()) + myId   // [2B PSM][16B id]
                gattServer?.sendResponse(d, reqId, BluetoothGatt.GATT_SUCCESS, 0, v)
            }
        })
        val svc = BluetoothGattService(SERVICE_UUID.uuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        svc.addCharacteristic(BluetoothGattCharacteristic(ENDPOINT_CHAR,
            BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
        gattServer?.addService(svc)
    }
    fun startAdvertise() {                                    // idempotent; call from tick self-heal
        if (advSet != null) return
        val adv = adapter.bluetoothLeAdvertiser ?: return
        val params = AdvertisingSetParameters.Builder()
            .setLegacyMode(true).setConnectable(true).setScannable(true)
            .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM).build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(SERVICE_UUID)
            .addManufacturerData(MFG_ID, myId.copyOfRange(0, 6))   // 6-byte nodeId prefix (tiebreaker)
            .build()
        val scanResp = AdvertiseData.Builder().setIncludeDeviceName(true).build()
        adv.startAdvertisingSet(params, data, scanResp, null, null, object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) { advSet = set }
            override fun onAdvertisingSetStopped(set: AdvertisingSet?) { advSet = null }
        })
    }
}

// ---- DIALER (central): scan (service filter) → connectGatt → read PSM → createInsecureL2capChannel ----
class Central(private val ctx: Context, private val myId: ByteArray,
              private val shouldDial: (ByteArray?) -> Boolean, private val onLink: (Link) -> Unit) {
    private val adapter = (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    private val main = Handler(Looper.getMainLooper())
    private val inFlight = mutableSetOf<String>()         // by current MAC, just for dial-concurrency cap
    private val backoff = mutableMapOf<String, Long>()

    fun start() {
        val filters = listOf(ScanFilter.Builder().setServiceUuid(SERVICE_UUID).build())
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build()
        adapter.bluetoothLeScanner.startScan(filters, settings, scanCb)
    }
    private val scanCb = object : ScanCallback() {
        override fun onScanResult(type: Int, r: ScanResult) {
            val advId = r.scanRecord?.getManufacturerSpecificData(MFG_ID)   // 6-byte nodeId prefix or null
            if (!shouldDial(advId)) return
            val dev = r.device
            main.post {                                                     // connectGatt on MAIN thread
                if (inFlight.size >= MAX_DIALS_IN_FLIGHT || dev.address in inFlight) return@post
                if (System.currentTimeMillis() < (backoff[dev.address] ?: 0)) return@post
                inFlight += dev.address
                val gattRef = arrayOfNulls<BluetoothGatt>(1)
                gattRef[0] = dev.connectGatt(ctx, false, gattCb(gattRef), BluetoothDevice.TRANSPORT_LE)
                main.postDelayed({ if (dev.address in inFlight) { gattRef[0]?.close(); fail(dev.address) } }, 12_000) // dial-timeout
            }
        }
    }
    private fun gattCb(ref: Array<BluetoothGatt?>) = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH); g.discoverServices()
            } else { g.close(); fail(g.device.address) }   // ALWAYS close on disconnect/133
        }
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val ch = g.getService(SERVICE_UUID.uuid)?.getCharacteristic(ENDPOINT_CHAR)
            if (ch != null) g.readCharacteristic(ch) else { g.close(); fail(g.device.address) }
        }
        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS || value.size < 2) { g.close(); fail(g.device.address); return }
            val psm = ((value[0].toInt() and 0xff) shl 8) or (value[1].toInt() and 0xff)
            val dev = g.device
            thread(name = "l2cap-dial") {                  // blocking connect off main
                try {
                    val sock = dev.createInsecureL2capChannel(psm); sock.connect()
                    g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_BALANCED)
                    val link = Link(sock, isDialer = true, myId, onLink, onClose = {})
                    inFlight -= dev.address; backoff.remove(dev.address)
                    onLink(link); link.start()
                } catch (e: IOException) { g.close(); fail(dev.address) }
            }
        }
    }
    private fun fail(addr: String) {
        inFlight -= addr
        val d = minOf((backoff[addr]?.let { it - System.currentTimeMillis() } ?: 1000L) * 2, 30_000L)
        backoff[addr] = System.currentTimeMillis() + d + (0..1000L).random()
    }
}
```

---

## 8. Bring-up + reliability test procedure (the rig)

**Build.** Apple: `swiftc -O -framework CoreBluetooth … -o ble-lab/peer` (model on
`apple/hopmac/build.sh`); grant the Terminal Bluetooth permission. Android: `./gradlew
installDebug` against `android/HopDemo`'s proven SDK config; logcat tag `HOP`.

**Topology under test.** Run the macOS CLI (dual role) and the Android app (dual role) in the
same room. macOS is the fast loop and is iOS-faithful; promote to a physical iPhone for the
background/restoration cases.

**Bring-up (clean radio first).**
1. `adb shell cmd bluetooth_manager disable && adb shell cmd bluetooth_manager enable` — a freshly
   cycled stack avoids a wedged advertiser **[field]** (the canonical "onStartSuccess but nothing
   on air" failure).
2. Launch the Android app; confirm it advertises: `adb shell dumpsys bluetooth_manager` →
   "GATT Advertiser Map" lists the service + connectable/scannable/legacy flags. (Or LightBlue /
   nRF Connect as ground truth.)
3. Launch the macOS peer. Expect within ~3 s: scan → discover → connect → `didDiscoverServices`
   → read PSM → `openL2CAPChannel` → channel open → `HELLO` both ways → `UP`.

**The metrics that prove "established AND maintained" (not "connected once").** Each peer logs a
STATUS line every 5 s; the test asserts on these over a long soak:

| Signal | Proves | Pass criterion |
|---|---|---|
| time(scan-start → first `HELLO`) | fast establishment | < 3 s in-room; < 10 s through one wall |
| live channel count per `peerNodeId` | single-channel convergence | **exactly 1**, ever; dedup-close logged if 2 briefly appeared |
| `rxSeq` increments by exactly 1 / s | no loss, no stall (the proof) | 0 gaps; max inter-arrival < `DEAD_MS` over the whole soak |
| PONG RTT | reverse direction live | bounded (e.g. < 200 ms in-room), no growth-to-timeout |
| false-dead count | watchdog isn't flapping a good link | 0 over a ≥ 1 h stationary soak |
| reconnect latency after induced drop | automatic recovery | link `UP` again within current backoff (≤ ~2 s first drop) |
| orphan/half-open L2CAP count | no channel-cap exhaustion | 0 (HELLO-reap fires on any orphan); no `Unknown error` open-storms |

**Reliability scenarios (run each, indefinitely-repeatable).**
1. **Idle soak (≥ 1 h):** stationary; counter must advance every second with 0 gaps, 0 false-dead.
2. **Induced ACL drop:** `adb shell cmd bluetooth_manager disable; sleep 2; … enable`. Both ends
   detect via watchdog/disconnect within `DEAD_MS`, COOLDOWN→re-establish; counter resumes; `rxSeq`
   restarts cleanly with no duplicate channel.
3. **Meet/part cycles (×50+):** walk the macOS peer out of range until LOST, back into range;
   each cycle must re-establish exactly one channel. No per-MAC state accumulation, no degradation
   across cycles.
4. **Address rotation soak:** run hours so the peer's RPA rotates repeatedly; assert the link
   persists (or re-forms) with **no duplicate channel** — dedup is by `nodeId`, so rotation is a
   non-event.
5. **Contention:** add 2–3 extra centrals (more macOS peers / LightBlue). Assert no orphan
   accumulation and no L2CAP-open `Unknown error` storms — the tiebreaker (one dialer),
   HELLO-reap, and dial caps keep Android's concurrent-channel budget healthy.
6. **iOS background (device only):** background the app; a service-filtered scan still discovers
   the Android peer and `connect` completes; with state restoration the app relaunches into the
   background on a peripheral event. (Validate the §5.6 beacon-wake separately for the
   killed-app case.)

---

## Sources

- [Core Bluetooth Background Processing for iOS Apps (Apple)](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [Hacking the iOS BLE Overflow Area — David G. Young](https://davidgyoungtech.com/2020/05/07/hacking-the-overflow-area) / [ios-overflow-area repo](https://github.com/davidgyoung/ios-overflow-area)
- [iOS BLE Scanning guide — Punch Through](https://punchthrough.com/ios-ble-scanning-guide/)
- [CBL2CAPChannel (Apple)](https://developer.apple.com/documentation/corebluetooth/cbl2capchannel) / [publishL2CAPChannel(withEncryption:)](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/publishl2capchannel(withencryption:))
- [startAdvertising(_:) (Apple — honored keys)](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/startadvertising(_:))
- [CBCentralManager State Restoration Options (Apple)](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/central_manager_state_restoration_options)
- [Android createInsecureL2capChannel / listenUsingInsecureL2capChannel (LE-only CoC)](https://learn.microsoft.com/en-us/dotnet/api/android.bluetooth.bluetoothdevice.createinsecurel2capchannel) / [BluetoothServerSocket.Psm](https://learn.microsoft.com/en-us/dotnet/api/android.bluetooth.bluetoothserversocket.psm)
- [L2CAP implementation in Android — Girish Yadawad](https://medium.com/@girishby90/l2cap-implementation-in-android-588f5b867f01)
- [Demystifying Android BLE 'GATT Status 133'](https://dev.to/ble_advertiser/demystifying-android-ble-gatt-status-133-common-causes-and-robust-solutions-for-connection-32la) / [Android BLE timeouts & internal errors — Classy Code](https://blog.classycode.com/a-short-story-about-android-ble-connection-timeouts-and-gatt-internal-errors-fa89e3f6a456)
- [BLE throughput / L2CAP CoC MTU & flow control — chrisc11/ble-guides](https://github.com/chrisc11/ble-guides/blob/master/ble-throughput.md) / [CoreBluetooth L2CAP MTU — Apple Forums](https://developer.apple.com/forums/thread/81120)
- Repo field notes: `ble-bearer-pure-l2cap-no-gatt`, `cross-platform-ble` (this project's memory).
