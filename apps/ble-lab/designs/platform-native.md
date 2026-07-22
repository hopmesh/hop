# Proof-of-Pipe BLE Transport: the PLATFORM-NATIVE design

A minimal, symmetric, dual-role BLE transport that establishes **exactly one** reliable
bidirectional byte channel between two nearby devices and keeps it healthy across drops,
BLE address rotation, and repeated meet/part cycles, indefinitely. Android (Kotlin) and
Apple (Swift / CoreBluetooth), with **Android↔Apple as the bar**.

Design lens: **platform-native**. Every choice below is the most-documented, most-blessed
happy path for each OS BLE stack, and we deliberately do not fight OS defaults, background
restrictions, or connection-parameter negotiation. Where the two stacks disagree, we bend
to the *more restrictive* one (iOS background), because that is the only way the cross-
platform pair survives in the real world.

---

## 0. The one fact that shapes everything: asymmetric discoverability

This is the load-bearing constraint. Everything else is downstream of it.

| Advertiser \ Scanner | Android scans | iOS scans (fg) | iOS scans (bg, screen on) |
|---|---|---|---|
| **Android advertises** | ✅ | ✅ | ✅ |
| **iOS advertises (fg)** | ✅ | ✅ | ✅ |
| **iOS advertises (bg)** | ❌ (overflow area) | ✅ (overflow) | ✅ (overflow) |

Sources: Apple's [Core Bluetooth Background Processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
("while your app is in the background the local name is not advertised and all service UUIDs
are placed in the overflow area"), David Young's [overflow-area reverse engineering](https://github.com/davidgyoung/ios-overflow-area)
(the overflow area is an Apple-proprietary hashed bloom filter, **discoverable only by another
iOS device explicitly scanning for that UUID**), and [PunchThrough's iOS scanning guide](https://punchthrough.com/ios-ble-scanning/).

Consequences we must design around:

1. **A backgrounded iOS advertiser is invisible to Android.** Its service UUID is in the
   overflow area (Android can't parse it) and its `LocalName` / manufacturer data / service
   data are stripped entirely. So **any in-band data carried in an iOS advertisement is
   unavailable in the background**, the tiebreaker cannot live *only* in the advert.
2. **iOS-as-central scanning with a service-UUID filter works in the background** (screen on),
   and Android-as-advertiser is always visible. Therefore the single edge that survives all
   states is **iOS(central) → Android(peripheral)**. The design must guarantee that edge is
   always available and never depends on Android seeing a backgrounded iOS.
3. Same-platform is table stakes and falls out for free (iOS↔iOS via overflow; Android↔Android
   via normal adverts).

**Net rule:** every device is a *full* dual-role node (advertises **and** scans, runs a GATT
server **and** a GATT client, hosts an L2CAP listener **and** can open one). But the *initiation
bias under uncertainty* always favors "central dials peripheral," because that is the only
direction that is guaranteed to work when the peer is a backgrounded iPhone.

---

## 1. Identifiers, the in-band nonce, and the advertisement

Fresh UUID scheme (assume nothing pre-existing). 128-bit, one service, four characteristics:

```
SERVICE   7D5E0001-9A0B-4C3D-8E2F-A1B2C3D4E5F6   the Hop pipe service
PSM_CHAR  7D5E0002-9A0B-4C3D-8E2F-A1B2C3D4E5F6   READ  -> 2-byte big-endian L2CAP PSM
INFO_CHAR 7D5E0003-9A0B-4C3D-8E2F-A1B2C3D4E5F6   READ  -> 8-byte node nonce (tiebreaker/dedup)
RX_CHAR   7D5E0004-9A0B-4C3D-8E2F-A1B2C3D4E5F6   WRITE-NO-RSP   central->peripheral (GATT fallback)
TX_CHAR   7D5E0005-9A0B-4C3D-8E2F-A1B2C3D4E5F6   NOTIFY         peripheral->central (GATT fallback)
```

### The node nonce (in-band identity, NEVER a MAC)
Each process generates **8 random bytes once per launch**: `nonce`. It is:
- the **tiebreaker** (compared as a big-endian u64),
- the **dedup key** ("have I already linked this peer?"),
- stable for the lifetime of the app process, and **rotates on relaunch**, so it is never a
  hardware address and never survives long enough to be a tracking identity.

It is carried **in-band three ways**, in increasing order of authority:
1. *(best-effort)* in the advertisement, as manufacturer data in the **scan-response** packet
   (company id `0xFFFF` test range, then the 8 bytes). Lets two devices that can both see each
   other's adverts pre-decide who dials, avoiding a double-connect. **Absent for backgrounded iOS.**
2. *(authoritative for the dialer)* readable from `INFO_CHAR` over GATT after connect.
3. *(authoritative for the acceptor)* the first in-band **HELLO** frame on the opened channel
   (§5), the acceptor of an L2CAP channel otherwise has no GATT identity for the peer.

### Advertisement layout (why this exact split)
- **Primary ADV packet:** Flags (3 B) + the 128-bit `SERVICE` UUID (18 B). That is ~21 of the
  31 bytes. The 128-bit UUID *must* be here so (a) Android can filter on it and (b) iOS puts
  exactly this UUID into its background overflow area for iOS↔iOS discovery.
- **Scan-response packet:** manufacturer data = `FF FF <8-byte nonce>` (12 B). The nonce goes in
  the scan response, not the primary packet, because the 128-bit UUID already nearly fills the
  primary packet ([Android AdvertiseData 31-byte limit](https://developer.android.com/reference/android/bluetooth/le/AdvertiseData)).
- We do **not** advertise a local name (saves bytes; iOS drops it in background anyway).

We never advertise service *data* keyed by the 128-bit UUID (that would re-spend 16 bytes on the
UUID). Manufacturer data in the scan response is the cheapest in-band slot.

---

## 2. Roles, discovery, and the channel substrate

Every device runs, concurrently and identically:

- **Peripheral plane:** a GATT server exposing the 4 characteristics; an **L2CAP CoC listener**;
  and an advertiser broadcasting `SERVICE` + nonce.
- **Central plane:** a scanner filtering on `SERVICE`; a GATT client; and an L2CAP dialer.

**Channel substrate: L2CAP CoC primary, GATT data fallback.** The data plane is an **L2CAP
Connection-oriented Channel**. This is the platform-blessed connection-oriented byte stream on
both OSes, Apple introduced it at [WWDC 2017 "What's New in Core Bluetooth"](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager/publishl2capchannel(withencryption:))
and Android exposes [`createInsecureL2capChannel` / `listenUsingInsecureL2capChannel`](https://developer.android.com/reference/android/bluetooth/BluetoothAdapter#listenUsingInsecureL2capChannel()).
It gives true stream semantics with built-in L2CAP credit-based flow control and no ATT/MTU
chunking. We use the **insecure** (un-encrypted) variant deliberately: cross-platform *secure*
L2CAP fails: the Android socket is never created when iOS asks for encryption ([Apple forum
675960](https://developer.apple.com/forums/thread/675960)), and our upper layer (a Noise
handshake) provides confidentiality/auth/MITM resistance, so OS-level encryption/bonding is
both unnecessary and harmful (it would require pairing UI, which is forbidden).

A **GATT write-no-response + notify** data plane (`RX_CHAR`/`TX_CHAR`) is the **co-equal
fallback**, used automatically when L2CAP open fails. It is the lowest-common-denominator that
works on every stack and survives iOS background. (See §11, whether iOS↔Android L2CAP opens
at all is the riskiest assumption, which is exactly why the fallback is not optional.)

---

## 3. Single-channel convergence: the unbiased tiebreaker + dedup

### Comparator
`initiatorOf(a, b)` = the node whose 8-byte nonce is **numerically greater** (big-endian u64).
Unbiased: it depends only on random per-launch bytes, not platform, not MAC, not who powered on
first. Ties (equal 8 random bytes) are astronomically unlikely; if it ever happens both sides
re-roll their nonce and re-advertise.

### Pre-connect (optimization, when the advert nonce is visible)
On discovering a peer and reading its advert nonce `P`:
- if `myNonce > P` → **I dial** (I'm the initiator).
- else → **I wait** for the peer to dial me, but arm a **grace timer** = `1.5s + rand(0..1s)`.
  If no inbound channel presenting nonce `P` arrives before it fires, **I dial anyway**.

The grace-timer fallback is what makes this robust to asymmetric visibility and lost adverts:
if the "should-dial" side can't actually see me (e.g. it's a backgrounded iPhone and I'm
Android: it sees me, I don't see it; but symmetric loss happens on flaky adverts too), the
non-initiator still establishes the link rather than deadlocking.

### Post-connect dedup (authoritative: this is what guarantees "exactly one")
A meet can momentarily produce **two** channels (one per direction), e.g. the grace timer
fires just as the peer's dial lands, or both saw each other and a race slipped through. We
resolve it deterministically *after the fact*, keyed on the in-band nonce (never the MAC):

1. Every channel, immediately on open, sends a **HELLO** frame carrying `myNonce` + a 1-byte
   role flag (`0x01` = I dialed this channel, `0x00` = I accepted it). HELLO is mandatory and
   must arrive within the half-open reap window (§6).
2. Maintain `linksByNonce: nonce -> Link`. When HELLO identifies a channel's peer:
   - if no existing live link for that nonce → record it, channel is **UP**.
   - if one already exists → **keep the channel that was dialed by the higher-nonce node;
     close the other.** Both endpoints know both nonces (from their own value + the peer's
     HELLO), so both compute the identical winner with no further messaging:
       - The higher-nonce node closes its *inbound/accepted* duplicate, keeping its *outbound*.
       - The lower-nonce node closes its *outbound* duplicate, keeping the *inbound* it accepted.
     Net: the single survivor is "the channel the higher-nonce node dialed." Deterministic,
     symmetric, no livelock, no coordinator.

This is the Ditto-style "converge on exactly one, decide in-band, don't trust the MAC" model,
adapted to our nonce.

---

## 4. The channel-open handshake: EXACT API call order

The single most important platform-native correctness rule, learned the hard way on real
hardware and confirmed across the rig: **on the dialing side you MUST drive GATT first
(connect → discover service → read a characteristic) BEFORE calling openL2CAP. Opening L2CAP
straight from the advertised PSM, with no prior GATT activity, fails to an Android peripheral
with CoreBluetooth "Unknown error."** The GATT exchange settles the ACL/connection context that
Android's L2CAP accept path requires. We exploit this anyway because we *need* the GATT read to
fetch the PSM and the peer nonce. So the natural happy path is also the correct one.

Notation: **D** = dialing (central) side, **A** = accepting (peripheral) side.

### 4a. Apple, ACCEPTING side (CBPeripheralManager)
1. `CBPeripheralManager(delegate:queue:options:)` with
   `CBPeripheralManagerOptionRestoreIdentifierKey` set (background relaunch).
2. `peripheralManagerDidUpdateState` → `.poweredOn`:
   a. Build `CBMutableService(SERVICE, primary:true)` with `CBMutableCharacteristic`s for
      `PSM_CHAR`(read), `INFO_CHAR`(read), `RX_CHAR`(writeWithoutResponse),
      `TX_CHAR`(notify) → `addService`.
   b. `publishL2CAPChannel(withEncryption: false)`.
3. `peripheralManager(_:didPublishL2CAPChannel:error:)` → store `PSM`. Now start advertising:
   `startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE]])`. (CoreBluetooth has no
   API to set manufacturer/scan-response data, so the iOS advert carries only the UUID; the
   nonce reaches peers via `INFO_CHAR`/HELLO. This is fine; see §0/§1.)
4. Central connects + reads:
   - `peripheralManager(_:didReceiveRead:)` for `PSM_CHAR` → `request.value = PSM (2B BE)`;
     `respond(to:withResult:.success)`.
   - for `INFO_CHAR` → `request.value = myNonce (8B)`; `respond(.success)`.
5. `peripheralManager(_:didOpen:error:)` → wrap the `CBL2CAPChannel` in a `Link` (open streams,
   schedule on run loop). Expect a HELLO frame; dedup; mark **UP**.

### 4b. Apple, DIALING side (CBCentralManager)
1. `CBCentralManager(delegate:queue:options:)` with `CBCentralManagerOptionRestoreIdentifierKey`.
2. `.poweredOn` → `scanForPeripherals(withServices: [SERVICE], options:)`
   (`CBCentralManagerScanOptionAllowDuplicatesKey: true` in foreground for fast RSSI/tiebreak;
   **omit it in background**: it is ignored there and wastes power).
3. `centralManager(_:didDiscover:advertisementData:rssi:)` → tiebreaker (§3). If I dial:
   retain the `CBPeripheral`, set its delegate, `central.connect(peripheral)`.
4. `centralManager(_:didConnect:)` → `peripheral.discoverServices([SERVICE])`.   ← GATT-first
5. `peripheral(_:didDiscoverServices:)` → `discoverCharacteristics([INFO_CHAR, PSM_CHAR], for: svc)`.
6. `peripheral(_:didDiscoverCharacteristicsFor:)` → `readValue(for: INFO_CHAR)`.
7. `peripheral(_:didUpdateValueFor: INFO_CHAR)` → store peer nonce; **re-check dedup** (close now
   if we already hold a live link to that nonce per §3); then `readValue(for: PSM_CHAR)`.
8. `peripheral(_:didUpdateValueFor: PSM_CHAR)` → parse 2-byte PSM → `peripheral.openL2CAPChannel(PSM)`.
9. `peripheral(_:didOpen:error:)`:
   - success → wrap `CBL2CAPChannel` in a `Link`, **send HELLO(myNonce, role=dialer)**, mark UP.
   - error → **fall back to GATT data plane** on this same connection: `setNotifyValue(true,
     for: TX_CHAR)`, and send/receive framed bytes via `writeValue(.withoutResponse, RX_CHAR)` /
     `didUpdateValueFor TX_CHAR`. Send HELLO over that.

### 4c. Android, ACCEPTING side (BluetoothGattServer + L2CAP listener)
1. `BluetoothManager.openGattServer(context, callback)`; add a `BluetoothGattService(SERVICE,
   SERVICE_TYPE_PRIMARY)` with the 4 characteristics → `addService`.
2. `bluetoothAdapter.listenUsingInsecureL2capChannel()` → `BluetoothServerSocket`; read
   `serverSocket.psm`. (**Insecure**, secure fails cross-platform, §2.)
3. Background thread: loop `serverSocket.accept()` → `BluetoothSocket` → wrap in a `Link`; expect
   HELLO; dedup; UP. (Accept loop keeps running to accept the next peer.)
4. `BluetoothLeAdvertiser.startAdvertising(settings, advData, scanResponse, callback)`:
   - `settings`: `ADVERTISE_MODE_LOW_LATENCY`, `ADVERTISE_TX_POWER_MEDIUM`, `connectable=true`.
   - `advData`: `addServiceUuid(SERVICE)`, `includeDeviceName=false`.
   - `scanResponse`: `addManufacturerData(0xFFFF, nonce)`.
   - (Prefer `startAdvertisingSet` on API 26+ for a long-running set; `startAdvertising` is fine
     for the proof.)
5. `BluetoothGattServerCallback.onCharacteristicReadRequest`:
   - `PSM_CHAR` → `sendResponse(device, requestId, GATT_SUCCESS, 0, psm2BE)`.
   - `INFO_CHAR` → `sendResponse(... nonce)`.
6. (Fallback only) if the peer drives GATT data: `onCharacteristicWriteRequest(RX_CHAR)` →
   feed bytes to the link; to send, `TX_CHAR.value = chunk; notifyCharacteristicChanged(device,
   TX_CHAR, false)` and wait for `onNotificationSent` before the next chunk.

### 4d. Android, DIALING side (BluetoothLeScanner + GATT client + L2CAP dialer)
1. `bluetoothLeScanner.startScan(filters=[ScanFilter.setServiceUuid(SERVICE)], settings=
   SCAN_MODE_LOW_LATENCY, callback)`.
2. `onScanResult` → read nonce from `result.scanRecord.getManufacturerSpecificData(0xFFFF)` →
   tiebreaker (§3). If I dial: `device.connectGatt(context, autoConnect=false, gattCb,
   TRANSPORT_LE)`. (`autoConnect=false` for a fast, deterministic direct connect; we own
   reconnection ourselves, §7.)
3. `onConnectionStateChange(STATE_CONNECTED)` → `gatt.requestMtu(517)`.
4. `onMtuChanged` → `gatt.requestConnectionPriority(CONNECTION_PRIORITY_HIGH)`;
   `gatt.discoverServices()`.   ← GATT-first
5. `onServicesDiscovered` → `gatt.readCharacteristic(INFO_CHAR)`.
6. `onCharacteristicRead(INFO_CHAR)` → store peer nonce; re-check dedup;
   `gatt.readCharacteristic(PSM_CHAR)`.
7. `onCharacteristicRead(PSM_CHAR)` → parse PSM. On a worker thread:
   `socket = device.createInsecureL2capChannel(psm); socket.connect()`.
8. connect():
   - success → wrap `BluetoothSocket` in a `Link`, **send HELLO(myNonce, role=dialer)**, UP.
   - throws/`IOException` → **fall back to GATT data plane** on the existing `gatt`:
     `setCharacteristicNotification(TX_CHAR, true)` + write its CCCD `ENABLE_NOTIFICATION_VALUE`;
     send via `RX_CHAR` `WRITE_TYPE_NO_RESPONSE`; receive via `onCharacteristicChanged(TX_CHAR)`.
     Send HELLO over that.

---

## 5. Data framing

One framing for both substrates (L2CAP stream and GATT payloads), identical on both platforms,
exactly the repo's proven `HopLink` framing:

```
[ u32 big-endian length N ][ N bytes payload ]
```

- `N == 0` is a **keepalive** (liveness only; surfaces nothing upward).
- On L2CAP, frames are written/read directly to the stream; the reader buffers until it has a
  full `4 + N`.
- On the GATT fallback, the same framed bytes are split into `MTU − 3` chunks; strict
  one-op-at-a-time flow control (send chunk → await completion callback → send next), reassembled
  by the same deframer.

**Message types (first payload byte):**
- `0x01 HELLO`  : `nonce(8) | roleFlag(1)`, sent first on every channel (§3 dedup).
- `0x02 PING`   : `seq(u64 BE)`, the proof-of-pipe counter, one per second.
- `0x03 PONG`   : `seq(u64 BE)`, echo of the latest received PING (for RTT).
- `0x00`        : reserved / opaque upper-layer payload (where the real Noise+messages go later).

Max payload ~64 KB is well within `u32` and within L2CAP CoC SDU limits; for the GATT fallback
it is chunked. (Repo `MAX_FRAME` cap = 4 MiB guards against a corrupt length.)

---

## 6. Keepalive + liveness policy (exact numbers, from proven repo values)

- **Keepalive:** every **4 s**, send a 0-length frame. iOS aggressively tears down a connection
  that goes idle; steady 4 s traffic keeps the connection interval warm and the link alive in
  both directions. (Without it, an idle Android↔iOS link dies within seconds, repo
  `HopLink` documents iOS dropping silent links with GATT status 19.)
- **Liveness watchdog:** if **nothing** (any frame, including keepalives) has been received for
  **15 s**, declare the link dead and close. 15 s > 3× keepalive, so a single lost keepalive
  doesn't false-trip.
- **Half-open reaper:** if a channel opens but **no HELLO arrives within 3.5 s**, close it. This
  kills the classic L2CAP half-open: iOS's `openL2CAPChannel` fails and abandons its end, but
  Android's `accept()` already returned a socket that then waits forever. Reaping fast also keeps
  us under the BT stack's concurrent-L2CAP-channel cap (orphans otherwise pile up and cause
  *more* open failures).
- Close is **idempotent** and always: cancels timers, closes streams/socket, removes the
  `nonce → Link` entry, and notifies the recovery state machine.

---

## 7. Reconnect / recovery state machine

Per discovered peer (keyed by **nonce**, never MAC):

```
            ┌────────────────────────── always running ──────────────────────────┐
            │  ADVERTISING (peripheral)            SCANNING (central)              │
            └───────────────────────────────────────────────────────────────────┘
 SCANNING ──discover+tiebreak(dial)──▶ DIALING ──connect──▶ GATT_DISCOVER
   ▲  │                                                           │
   │  └──tiebreak(wait)──▶ GRACE(1.5s+jit) ──timeout──▶ DIALING   │ read INFO,PSM
   │                                  │                            ▼
   │                          inbound channel arrives      L2CAP_OPENING ──ok──▶ UP
   │                                  │                            │              │
   │                                  ▼                       fail │              │ HELLO+dedup
   │                                 UP ◀───────────────── GATT_DATA_UP ◀─────────┘
   │                                  │
   │            drop / 15s liveness / half-open reap / dedup-loser
   │                                  ▼
   └──────────────── COOLDOWN(backoff, keyed by nonce) ◀──────────┘
```

- **Drop / dead / dedup-loser → COOLDOWN:** close the link, drop the `nonce→Link` entry,
  back off `2s × 1.5ⁿ` capped at **20 s** with ±jitter (gentle; don't hammer a flapping peer),
  keyed by nonce so a peer that reappears under a **rotated MAC** is still rate-limited correctly.
  Then return to SCANNING (we never stop scanning/advertising).
- **BLE address rotation:** transparent. We never key anything on the MAC. A rotated address is
  simply a new advert → a new `CBPeripheral`/`BluetoothDevice` → dialed fresh; dedup by nonce
  prevents a second channel to the same logical peer; the old MAC's link dies on its watchdog.
- **Repeated meet/part, indefinitely:** scanning + advertising never stop; each meet re-runs the
  tiebreaker; each part trips the watchdog and returns to COOLDOWN→SCANNING.
- **Adapter bounce** (`adb shell cmd bluetooth_manager disable/enable`, or iOS BT toggle):
  - Android: `BroadcastReceiver` on `BluetoothAdapter.ACTION_STATE_CHANGED`. On `STATE_OFF`
    close all links + null out scanner/advertiser/gatt server/L2CAP listener. On `STATE_ON`
    rebuild the whole peripheral+central plane.
  - iOS: `didUpdateState` to `.poweredOff` → tear down; to `.poweredOn` → re-add service,
    re-publish L2CAP, re-advertise, re-scan.
- **iOS background relaunch:** both managers created with a restore identifier. On relaunch the
  system calls `willRestoreState`; we re-adopt restored peripherals/server and resume timers
  ([state preservation & restoration](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/init(delegate:queue:options:))).
  We also `retrieveConnectedPeripherals(withServices:[SERVICE])` on launch to re-adopt links the
  system kept alive.

---

## 8. Connection parameters, MTU, background (platform-native posture)

- **Android central** drives the negotiation it's allowed to: `requestMtu(517)` (use
  `min(local, peer)` from `onMtuChanged`), then `requestConnectionPriority(CONNECTION_PRIORITY_
  HIGH)` while actively moving data and `…_BALANCED` when idle, so we don't starve the radio
  scheduler ([Nordic guidance](https://github.com/NordicSemiconductor/Android-BLE-Library)).
- **iOS** exposes no connection-parameter API by design; the platform-native move is **don't
  fight it**: accept CoreBluetooth's negotiated interval and just keep the 4 s keepalive flowing
  so iOS keeps the link in a responsive state.
- **Background:** Android keeps the peripheral+central plane alive in a **foreground service**
  with `connectedDevice` type (already in the repo manifest). iOS relies on the
  `bluetooth-central` + `bluetooth-peripheral` `UIBackgroundModes`, filtered background scanning,
  and state restoration. Remember: a backgrounded iOS peer is reachable only by the
  iOS-central→Android-peripheral edge (§0), which this design always keeps open.

---

## 9. Minimal source, critical paths

> These are the load-bearing critical paths (discovery, tiebreak, the exact open handshake,
> framing, keepalive/liveness, dedup, recovery). Boilerplate (permission prompts, service
> lifecycle, UI) is omitted; model the build on the existing `apple/hopmac/build.sh` (swiftc +
> `-framework CoreBluetooth`) and the `android/HopDemo` gradle setup.

### 9a. Apple, Swift / CoreBluetooth

```swift
import Foundation
import CoreBluetooth

let SERVICE   = CBUUID(string: "7D5E0001-9A0B-4C3D-8E2F-A1B2C3D4E5F6")
let PSM_CHAR  = CBUUID(string: "7D5E0002-9A0B-4C3D-8E2F-A1B2C3D4E5F6")
let INFO_CHAR = CBUUID(string: "7D5E0003-9A0B-4C3D-8E2F-A1B2C3D4E5F6")
let RX_CHAR   = CBUUID(string: "7D5E0004-9A0B-4C3D-8E2F-A1B2C3D4E5F6")
let TX_CHAR   = CBUUID(string: "7D5E0005-9A0B-4C3D-8E2F-A1B2C3D4E5F6")

func u64(_ d: ArraySlice<UInt8>) -> UInt64 { d.reduce(0) { ($0 << 8) | UInt64($1) } }

// ---- One channel over a CBL2CAPChannel: framing + keepalive + liveness + HELLO -------------
final class Link: NSObject, StreamDelegate {
    let dialer: Bool
    var peerNonce: [UInt8]? = nil               // learned from HELLO
    private let input: InputStream, output: OutputStream
    private let onFrame: (Link, [UInt8]) -> Void
    private let onClose: (Link) -> Void
    private var inBuf = [UInt8](), outBuf = [UInt8]()
    private var lastRx = Date(); private let born = Date()
    private var gotHello = false; private var closed = false
    private var ka: Timer?, wd: Timer?

    init(channel: CBL2CAPChannel, dialer: Bool, myNonce: [UInt8],
         onFrame: @escaping (Link, [UInt8]) -> Void, onClose: @escaping (Link) -> Void) {
        self.dialer = dialer; self.onFrame = onFrame; self.onClose = onClose
        self.input = channel.inputStream; self.output = channel.outputStream
        super.init()
        for s in [input, output] { s.delegate = self; s.schedule(in: .main, forMode: .common); s.open() }
        send([0x01] + myNonce + [dialer ? 1 : 0])                       // HELLO first, always
        ka = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.send([]) }
        wd = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            if !s.gotHello && Date().timeIntervalSince(s.born) > 3.5 { s.close() }   // half-open reap
            if Date().timeIntervalSince(s.lastRx) > 15 { s.close() }                 // liveness
        }
    }
    func send(_ p: [UInt8]) {
        guard !closed else { return }
        let n = UInt32(p.count)
        outBuf += [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)] + p
        drain()
    }
    func close() {
        guard !closed else { return }; closed = true; ka?.invalidate(); wd?.invalidate()
        for s in [input, output] { s.close(); s.remove(from: .main, forMode: .common) }
        onClose(self)
    }
    func stream(_ s: Stream, handle e: Stream.Event) {
        switch e {
        case .hasBytesAvailable: read()
        case .hasSpaceAvailable: drain()
        case .endEncountered, .errorOccurred: close()
        default: break }
    }
    private func drain() {
        while !outBuf.isEmpty && output.hasSpaceAvailable {
            let n = output.write(outBuf, maxLength: outBuf.count); if n > 0 { outBuf.removeFirst(n) } else { break }
        }
    }
    private func read() {
        var t = [UInt8](repeating: 0, count: 8192)
        while input.hasBytesAvailable { let n = input.read(&t, maxLength: t.count); if n > 0 { inBuf += t[0..<n] } else { break } }
        lastRx = Date()
        while inBuf.count >= 4 {
            let len = Int(u64(inBuf[0..<4])); let total = 4 + len
            guard inBuf.count >= total else { break }
            let p = Array(inBuf[4..<total]); inBuf.removeFirst(total)
            if p.isEmpty { continue }                                   // keepalive
            if p[0] == 0x01 { peerNonce = Array(p[1..<9]); gotHello = true } // HELLO
            onFrame(self, p)
        }
    }
}

// ---- Peripheral (accepting) plane ----------------------------------------------------------
final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    private var mgr: CBPeripheralManager!
    private var psm: CBL2CAPPSM = 0
    let myNonce: [UInt8]
    var onChannel: ((CBL2CAPChannel) -> Void)!
    init(myNonce: [UInt8]) { self.myNonce = myNonce; super.init()
        mgr = CBPeripheralManager(delegate: self, queue: .main,
              options: [CBPeripheralManagerOptionRestoreIdentifierKey: "hop.peripheral"]) }
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        guard p.state == .poweredOn else { return }
        let svc = CBMutableService(type: SERVICE, primary: true)
        let psmC  = CBMutableCharacteristic(type: PSM_CHAR,  properties: .read,  value: nil, permissions: .readable)
        let infoC = CBMutableCharacteristic(type: INFO_CHAR, properties: .read,  value: nil, permissions: .readable)
        let rxC   = CBMutableCharacteristic(type: RX_CHAR,   properties: .writeWithoutResponse, value: nil, permissions: .writeable)
        let txC   = CBMutableCharacteristic(type: TX_CHAR,   properties: .notify, value: nil, permissions: .readable)
        svc.characteristics = [psmC, infoC, rxC, txC]
        p.add(svc)
        p.publishL2CAPChannel(withEncryption: false)                   // insecure: Noise secures upper layer
    }
    func peripheralManager(_ p: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        psm = PSM
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE]]) // UUID only; iOS strips the rest in bg
    }
    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead r: CBATTRequest) {
        switch r.characteristic.uuid {
        case PSM_CHAR:  r.value = Data([UInt8(psm >> 8), UInt8(psm & 0xff)])
        case INFO_CHAR: r.value = Data(myNonce)
        default: break }
        p.respond(to: r, withResult: .success)
    }
    func peripheralManager(_ p: CBPeripheralManager, didOpen ch: CBL2CAPChannel?, error: Error?) {
        if let ch = ch, error == nil { onChannel(ch) }                 // accepted: dialer=false
    }
    func peripheralManager(_ p: CBPeripheralManager, willRestoreState d: [String: Any]) { /* re-adopt + re-advertise */ }
}

// ---- Central (dialing) plane + tiebreaker + dedup ------------------------------------------
final class Central: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var mgr: CBCentralManager!
    let myNonce: [UInt8]
    private var retained = [UUID: CBPeripheral](), psmByDev = [UUID: CBL2CAPPSM]()
    private var graceTimers = [UInt64: Timer]()
    var linksByNonce = [UInt64: Link]()                                // shared dedup map (peripheral+central)
    var onChannel: ((CBL2CAPChannel) -> Void)!
    init(myNonce: [UInt8]) { self.myNonce = myNonce; super.init()
        mgr = CBCentralManager(delegate: self, queue: .main,
              options: [CBCentralManagerOptionRestoreIdentifierKey: "hop.central"]) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: [SERVICE],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])   // omit in bg
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi: NSNumber) {
        var peer: UInt64? = nil
        if let mfg = d[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 10 {
            let b = [UInt8](mfg); if b[0] == 0xFF && b[1] == 0xFF { peer = u64(b[2..<10]) }
        }
        let me = u64(myNonce[0..<8])
        if let peer = peer {                                           // advert nonce visible: pre-decide
            if linksByNonce[peer] != nil { return }                   // already linked this peer
            if me > peer { dial(c, p) }                               // I'm initiator
            else if graceTimers[peer] == nil {                        // wait, but break deadlock
                graceTimers[peer] = Timer.scheduledTimer(withTimeInterval: 1.5 + Double.random(in: 0...1), repeats: false) {
                    [weak self] _ in self?.graceTimers[peer] = nil
                    if self?.linksByNonce[peer] == nil { self?.dial(c, p) } }
            }
        } else { dial(c, p) }                                          // backgrounded-iOS peer: just dial
    }
    private func dial(_ c: CBCentralManager, _ p: CBPeripheral) {
        guard retained[p.identifier] == nil else { return }
        retained[p.identifier] = p; p.delegate = self; c.connect(p)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([SERVICE]) } // GATT-first
    func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        for s in p.services ?? [] where s.uuid == SERVICE { p.discoverCharacteristics([INFO_CHAR, PSM_CHAR], for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error e: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == INFO_CHAR { p.readValue(for: ch) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error e: Error?) {
        guard let v = ch.value else { return }
        if ch.uuid == INFO_CHAR, v.count >= 8 {
            let peer = u64([UInt8](v)[0..<8])
            if linksByNonce[peer] != nil { c_disconnect(p); return }   // dedup: already linked
            for s in p.services ?? [] where s.uuid == SERVICE {
                for c2 in s.characteristics ?? [] where c2.uuid == PSM_CHAR { p.readValue(for: c2) } }
        } else if ch.uuid == PSM_CHAR, v.count >= 2 {
            let psm = CBL2CAPPSM(UInt16(v[0]) << 8 | UInt16(v[1])); psmByDev[p.identifier] = psm
            p.openL2CAPChannel(psm)                                     // ONLY after GATT activity
        }
    }
    func peripheral(_ p: CBPeripheral, didOpen ch: CBL2CAPChannel?, error e: Error?) {
        if let ch = ch, e == nil { onChannel(ch) }                     // dialer=true
        else { /* fall back to GATT data plane: setNotifyValue(true, TX_CHAR) + write RX_CHAR */ }
    }
    private func c_disconnect(_ p: CBPeripheral) { mgr.cancelPeripheralConnection(p); retained[p.identifier] = nil }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error e: Error?) {
        retained[p.identifier] = nil                                   // recovery: keep scanning; backoff per nonce
    }
    func centralManager(_ c: CBCentralManager, willRestoreState d: [String: Any]) { /* re-adopt restored peripherals */ }
}
```

**Dedup glue (shared by both planes).** `onChannel` for both `Peripheral` and `Central` wraps the
channel in a `Link` and, on its first `HELLO` frame, runs §3:

```swift
func adopt(_ ch: CBL2CAPChannel, dialer: Bool) {
    let link = Link(channel: ch, dialer: dialer, myNonce: myNonce,
        onFrame: { [weak self] l, p in self?.handle(l, p) },
        onClose: { [weak self] l in if let n = l.peerNonce { self?.linksByNonce[u64(n[0..<8])] = nil } })
    // peerNonce populated by HELLO; resolve dedup there
}
func handle(_ l: Link, _ p: [UInt8]) {
    guard let pn = l.peerNonce else { return }
    let peer = u64(pn[0..<8]), me = u64(myNonce[0..<8])
    if let existing = linksByNonce[peer], existing !== l {
        // keep the channel dialed by the higher-nonce node; close the other
        let keepIsDialer = me > peer            // if I'm higher, my dialed channel wins
        let loser = (l.dialer == keepIsDialer) ? existing : l
        loser.close(); if loser === existing { linksByNonce[peer] = l }
    } else { linksByNonce[peer] = l }
    // p[0]==0x02 PING -> reply PONG; verify monotonic seq; etc.
}
```

### 9b. Android, Kotlin

```kotlin
import android.bluetooth.*
import android.bluetooth.le.*
import android.os.ParcelUuid
import java.io.DataInputStream
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread

val SERVICE   = UUID.fromString("7D5E0001-9A0B-4C3D-8E2F-A1B2C3D4E5F6")
val PSM_CHAR  = UUID.fromString("7D5E0002-9A0B-4C3D-8E2F-A1B2C3D4E5F6")
val INFO_CHAR = UUID.fromString("7D5E0003-9A0B-4C3D-8E2F-A1B2C3D4E5F6")
val RX_CHAR   = UUID.fromString("7D5E0004-9A0B-4C3D-8E2F-A1B2C3D4E5F6")
val TX_CHAR   = UUID.fromString("7D5E0005-9A0B-4C3D-8E2F-A1B2C3D4E5F6")
const val MFG_ID = 0xFFFF

fun u64(b: ByteArray, off: Int = 0): Long {
    var v = 0L; for (i in 0 until 8) v = (v shl 8) or (b[off + i].toLong() and 0xff); return v
}

// ---- One channel over a BluetoothSocket (L2CAP CoC): framing + keepalive + liveness + HELLO --
class Link(
    val dialer: Boolean,
    private val socket: BluetoothSocket,
    private val myNonce: ByteArray,
    private val onFrame: (Link, ByteArray) -> Unit,
    private val onClose: (Link) -> Unit,
) {
    @Volatile var peerNonce: ByteArray? = null
    private val outbox = LinkedBlockingQueue<ByteArray>()
    @Volatile private var running = true
    @Volatile private var lastRx = System.currentTimeMillis()
    @Volatile private var gotHello = false
    private val born = System.currentTimeMillis()
    private val POISON = ByteArray(0)

    init {
        send(byteArrayOf(0x01) + myNonce + byteArrayOf(if (dialer) 1 else 0)) // HELLO first
        thread(name = "rx") { readLoop() }
        thread(name = "tx") { writeLoop() }
        thread(name = "ka") { kaLoop() }
    }
    fun send(b: ByteArray) { if (running) outbox.put(b) }
    fun close() {
        if (!running) return; running = false; outbox.put(POISON)
        runCatching { socket.close() }; onClose(this)
    }
    private fun readLoop() = try {
        val inp = DataInputStream(socket.inputStream)
        while (running) {
            val len = inp.readInt()                                  // big-endian frame length
            if (len < 0 || len > 4 * 1024 * 1024) throw IllegalStateException("bad len")
            lastRx = System.currentTimeMillis()
            if (len == 0) continue                                   // keepalive
            val buf = ByteArray(len); inp.readFully(buf)
            if (buf[0] == 0x01.toByte()) { peerNonce = buf.copyOfRange(1, 9); gotHello = true }
            onFrame(this, buf)
        }
    } catch (_: Throwable) {} finally { close() }
    private fun writeLoop() = try {
        val out = socket.outputStream
        while (running) {
            val p = outbox.take(); if (p === POISON || !running) break
            val n = p.size
            out.write(byteArrayOf((n ushr 24).toByte(),(n ushr 16).toByte(),(n ushr 8).toByte(), n.toByte()))
            if (n > 0) out.write(p); out.flush()
        }
    } catch (_: Throwable) {} finally { close() }
    private fun kaLoop() = try {
        while (running) {
            Thread.sleep(4000); if (!running) break
            val now = System.currentTimeMillis()
            if (!gotHello && now - born > 3500) { close(); break }    // half-open reap
            if (now - lastRx > 15000) { close(); break }              // liveness
            outbox.put(ByteArray(0))                                  // keepalive
        }
    } catch (_: Throwable) {}
}

// ---- Peripheral (accepting) plane: GATT server + L2CAP listener + advertiser ----------------
class Peripheral(
    private val adapter: BluetoothAdapter,
    private val mgr: BluetoothManager,
    private val ctx: android.content.Context,
    private val myNonce: ByteArray,
    private val onChannel: (BluetoothSocket) -> Unit,
) {
    private var psm = 0
    private lateinit var server: BluetoothGattServer
    fun start() {
        server = mgr.openGattServer(ctx, object : BluetoothGattServerCallback() {
            override fun onCharacteristicReadRequest(d: BluetoothDevice, id: Int, off: Int, c: BluetoothGattCharacteristic) {
                val v = when (c.uuid) {
                    PSM_CHAR  -> byteArrayOf((psm ushr 8).toByte(), psm.toByte())
                    INFO_CHAR -> myNonce
                    else      -> ByteArray(0)
                }
                server.sendResponse(d, id, BluetoothGatt.GATT_SUCCESS, 0, v)
            }
        })
        val svc = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        fun ch(u: UUID, props: Int, perms: Int) = BluetoothGattCharacteristic(u, props, perms)
        svc.addCharacteristic(ch(PSM_CHAR,  BluetoothGattCharacteristic.PROPERTY_READ,  BluetoothGattCharacteristic.PERMISSION_READ))
        svc.addCharacteristic(ch(INFO_CHAR, BluetoothGattCharacteristic.PROPERTY_READ,  BluetoothGattCharacteristic.PERMISSION_READ))
        svc.addCharacteristic(ch(RX_CHAR,   BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE, BluetoothGattCharacteristic.PERMISSION_WRITE))
        svc.addCharacteristic(ch(TX_CHAR,   BluetoothGattCharacteristic.PROPERTY_NOTIFY, BluetoothGattCharacteristic.PERMISSION_READ))
        server.addService(svc)

        val listener = adapter.listenUsingInsecureL2capChannel()      // INSECURE: secure fails cross-platform
        psm = listener.psm
        thread(name = "l2cap-accept") {
            while (true) { val s = runCatching { listener.accept() }.getOrNull() ?: break; onChannel(s) }
        }
        val adv = adapter.bluetoothLeAdvertiser
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true).build()
        val data = AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).setIncludeDeviceName(false).build()
        val scanResp = AdvertiseData.Builder().addManufacturerData(MFG_ID, myNonce).build()
        adv.startAdvertising(settings, data, scanResp, object : AdvertiseCallback() {})
    }
}

// ---- Central (dialing) plane: scan + tiebreak + GATT-first + L2CAP dial ----------------------
class Central(
    private val adapter: BluetoothAdapter,
    private val ctx: android.content.Context,
    private val myNonce: ByteArray,
    private val linksByNonce: MutableMap<Long, Link>,                 // shared dedup map
    private val onChannel: (BluetoothSocket, Boolean) -> Unit,        // socket, dialer=true
) {
    private val me = u64(myNonce)
    private val graceArmed = HashSet<Long>()
    fun start() {
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        adapter.bluetoothLeScanner.startScan(listOf(filter), settings, object : ScanCallback() {
            override fun onScanResult(type: Int, r: ScanResult) {
                val mfg = r.scanRecord?.getManufacturerSpecificData(MFG_ID) ?: return
                if (mfg.size < 8) return
                val peer = u64(mfg)
                if (linksByNonce.containsKey(peer)) return            // already linked
                when {
                    me > peer -> dial(r.device)                       // I'm initiator
                    graceArmed.add(peer) -> android.os.Handler(ctx.mainLooper).postDelayed({
                        graceArmed.remove(peer)
                        if (!linksByNonce.containsKey(peer)) dial(r.device)   // deadlock breaker
                    }, 1500L + (0..1000).random())
                }
            }
        })
    }
    private fun dial(device: BluetoothDevice) {
        device.connectGatt(ctx, false, object : BluetoothGattCallback() {     // autoConnect=false: fast direct
            override fun onConnectionStateChange(g: BluetoothGatt, st: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) g.requestMtu(517)
                else if (newState == BluetoothProfile.STATE_DISCONNECTED) g.close()
            }
            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, st: Int) {
                g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                g.discoverServices()                                  // GATT-first
            }
            override fun onServicesDiscovered(g: BluetoothGatt, st: Int) {
                g.readCharacteristic(g.getService(SERVICE).getCharacteristic(INFO_CHAR))
            }
            override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, st: Int) {
                when (c.uuid) {
                    INFO_CHAR -> {
                        val peer = u64(c.value)
                        if (linksByNonce.containsKey(peer)) { g.disconnect(); return }   // dedup
                        g.readCharacteristic(g.getService(SERVICE).getCharacteristic(PSM_CHAR))
                    }
                    PSM_CHAR -> {
                        val psm = ((c.value[0].toInt() and 0xff) shl 8) or (c.value[1].toInt() and 0xff)
                        thread(name = "l2cap-dial") {
                            val sock = g.device.createInsecureL2capChannel(psm)
                            try { sock.connect(); onChannel(sock, true) }                // L2CAP up
                            catch (e: Exception) { /* fall back to GATT data plane on `g` */ }
                        }
                    }
                }
            }
        }, BluetoothDevice.TRANSPORT_LE)
    }
}
```

The shared `onChannel` (both planes) wraps the socket in a `Link`, and on the first HELLO runs
the §3 dedup against `linksByNonce`, identical logic to the Swift `handle()` above:
keep the channel dialed by the higher-nonce node, close the loser, register the survivor.

---

## 10. Bring-up + reliability test procedure, and the metrics that prove it

### Rig
- Android phone over `adb` (logcat).
- macOS CoreBluetooth CLI (built like `apple/hopmac/build.sh`), the fast iteration loop, faithful
  to iOS (dual role, central, peripheral, GATT server, L2CAP). Optionally a physical iPhone.

### Bring-up (do same-platform first, then the real test)
1. **macOS ↔ macOS** (or two emulated nonces): launch two CLI instances. Expect both to advertise,
   both to scan, the tiebreaker to elect one dialer, and **exactly one** `CHANNEL UP` per side.
2. **Android ↔ Android**: install on two phones (or one phone + one `BluetoothServerSocket` test
   harness). Same expectation.
3. **Android ↔ Apple (THE BAR):** Android phone + macOS CLI. Confirm:
   - Android advertiser visible to macOS central; macOS dials; GATT-first read of INFO+PSM;
     `openL2CAPChannel` succeeds → `CHANNEL UP`. **If L2CAP errors, confirm the GATT-data fallback
     comes UP instead**, both count as success for "pipe proven."
   - Reverse direction where Apple is foreground: macOS advertiser visible to Android scanner.

### The proof: "established AND maintained over time" (not "connected once")
Each side, once UP, emits `PING(seq++)` every 1 s and replies `PONG`. Log/scrape and assert:

| Metric | How measured | Pass criterion |
|---|---|---|
| **Single channel** | count of live `Link`s per peer nonce | exactly **1** at all times (never 2) |
| **Both directions flow** | each side's received PING `seq` | strictly **monotonic, no gaps** |
| **Sustained** | run **≥ 30 min idle** | continuous PINGs, zero unплanned closes |
| **Liveness latency** | kill peer; time to local close | dead link detected **≤ 15 s** |
| **Re-establish after drop** | `adb shell cmd bluetooth_manager disable && … enable` | new `CHANNEL UP` **≤ ~15 s**, no dup |
| **Address rotation** | let MAC rotate (or force adapter cycle) | re-links by nonce; **no second channel** |
| **Meet/part loop** | walk in/out of range ×10 (or RF-shield) | every cycle re-converges to exactly 1 |
| **Half-open hygiene** | force an L2CAP open-fail | orphan reaped **≤ 3.5 s**; fallback engages |
| **Throughput sanity** | send a 64 KB framed payload both ways | arrives intact, ordered, at interactive latency |

Concrete log lines to grep: `CHANNEL UP nonce=… dialer=…`, `HELLO peer=…`, `DEDUP closed loser …`,
`PING seq=N`, `RX seq=N (gap=0)`, `LINK DEAD (liveness)`, `REAP half-open`, `BT state …`.
Android: `adb logcat -s HOPLOG`. macOS: stdout (build sets `setvbuf(_IONBF)` so logs flush under
`timeout`). A passing run shows two counters climbing in lockstep on both sides with `gap=0` for
the full duration, the channel count pinned at 1, and automatic recovery after every induced fault.

---

## 11. Riskiest assumption (and why the design already hedges it)

**The single riskiest assumption: that iOS/macOS `openL2CAPChannel` reliably opens against an
Android `listenUsingInsecureL2capChannel` peripheral once GATT-first sequencing is done.** This
repo holds *conflicting* evidence: `apple/hopmac/main.swift` and the BLE-bearer memory note say it
works **iff** you do GATT discovery + a characteristic read before opening (which this design
does), while `GattDataLink.kt` flatly states CoreBluetooth returns CBErrorDomain "Unknown error"
opening L2CAP to an Android peripheral and uses GATT as the real path. On some Android OEM stacks
the Apple→Android L2CAP CoC simply does not come up. That is exactly why the **GATT
write-no-response + notify data plane is a co-equal fallback, not an afterthought**, the same
framing, keepalive, liveness, HELLO, and dedup ride over it unchanged, so "pipe proven" holds
even if L2CAP never opens cross-platform on the target hardware.

Secondary risks, each already mitigated: a **backgrounded iOS advertiser is invisible to Android**
(mitigated by always keeping the iOS-central→Android-peripheral edge and never depending on
Android seeing iOS, §0); **iOS connection parameters aren't controllable** (mitigated by the 4 s
keepalive instead of fighting the API, §6/§8); **double-connect races** (mitigated by the
deterministic post-connect nonce dedup, not just the pre-connect tiebreaker, §3).
