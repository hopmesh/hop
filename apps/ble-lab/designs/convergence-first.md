# Convergence-First BLE Transport: Design + Reference Source

**Goal:** two symmetric dual-role devices (Android Kotlin, Apple Swift/CoreBluetooth)
deterministically converge on **exactly one** reliable, bidirectional L2CAP byte channel
between them (no duplicates, no livelock) and keep it healthy across drops, BLE address
rotation, and rapid meet/part cycles, indefinitely. Cross-platform (Android↔Apple) is the bar.

Primary lens: **CONVERGENCE.** Every tradeoff below is chosen to make "two dual-role peers
land on one channel, fast, every time" obviously correct. The tiebreaker and the dedup key
are the crux, so they come first.

---

## 0. Platform reality that forces the design (researched)

These are not opinions; they constrain the architecture:

1. **iOS background advertising is opaque to Android.** When an iOS app is backgrounded,
   CoreBluetooth drops the local name and moves all service UUIDs into a proprietary 128-bit
   hashed "overflow area" that only Apple devices scanning for that exact UUID can decode.
   Android cannot reliably interpret it. (davidgyoungtech overflow-area reverse engineering;
   Apple "Core Bluetooth Background Processing" docs.) → **We cannot put the tiebreaker in the
   advertisement and read it cross-platform.** The advertisement carries only the service UUID
   as a discovery anchor; the tiebreaker/identity is exchanged **in-band over a one-shot GATT
   read/write** after connect.

2. **Only *insecure* L2CAP CoC is cross-platform.** Developers consistently report iOS↔Android
   works for *insecure* L2CAP channels but *secure* ones trigger Android pairing and fail with
   opaque iOS errors. (Apple Dev Forums #675960; JuulLabs/kable #588.) → iOS publishes with
   `withEncryption: false`; Android uses `listenUsingInsecureL2capChannel()` /
   `createInsecureL2capChannel()`. **No OS pairing/bonding, no user interaction**, exactly what
   an upper crypto layer needs.

3. **OS disconnect detection is slow and asymmetric.** iOS supervision timeout ≈ 750 ms; Android
   historically ≈ 20 s, and a peripheral cannot force connection parameters (central may ignore).
   (Punch Through; Argenox.) → We **cannot** rely on the OS to tell us a link died. We run an
   **app-level keepalive + liveness timer over the L2CAP stream** (≈3 s detection), independent of
   the controller.

4. **Android throttles scanning:** max 5 `startScan` calls per 30 s per app; exceeding it silently
   no-ops. (Android `ScanSettings` docs; Punch Through.) → We keep **one persistent scan** for the
   whole node lifetime; never stop/restart it on connect.

5. **L2CAP CoC requires a real GATT/ACL connection first.** (Prior hopmac finding: advert-only /
   zero-GATT L2CAP is not accepted by Android; an over-built GATT service stalls the PSM read.)
   → Minimal GATT: **one service, one characteristic.** GATT carries only the nonce handshake +
   PSM. All data goes over L2CAP.

Sources: davidgyoungtech.com/2020/05/07/hacking-the-overflow-area; developer.apple.com Core
Bluetooth Background Processing; developer.apple.com/forums/thread/675960;
github.com/JuulLabs/kable/discussions/588; learn.microsoft.com Android.Bluetooth L2CAP refs;
developer.apple.com CBPeripheralManager.publishL2CAPChannel / CBL2CAPChannel;
punchthrough.com/manage-ble-connection; argenox.com/blog/understanding-ble-disconnections;
developer.android.com/reference/android/bluetooth/le/ScanSettings.

---

## 1. Identifiers (pick fresh, assume nothing)

```
Service UUID  HOP_SVC : 7B11A000-9C3E-4D2A-B6F1-0A11CE5500A1   (advertised + GATT service)
Char UUID     HOP_RV  : 7B11A001-9C3E-4D2A-B6F1-0A11CE5500A1   (Rendezvous: READ + WRITE)
```

One characteristic, two operations:

- **READ HOP_RV** returns the *peripheral's* rendezvous record (so the central learns it).
- **WRITE HOP_RV** lets the *central* hand the peripheral the central's nonce (the peripheral
  cannot read the central, so the central must push it).

**Rendezvous record (20 bytes, big-endian fields):**

```
offset size field
0      1    version        = 0x01
1      16   nonce          = 128-bit random session nonce (see §2)
17     2    psm            = this device's published L2CAP PSM (peripheral side; 0 in WRITE)
19     1    flags          = bit0 reserved/extensible
```

On WRITE the central sends `version|nonce|0x0000|flags` (psm field ignored). On READ the
peripheral returns `version|nonce|psm|flags`.

---

## 2. The in-band identity: the session nonce (tiebreaker AND dedup key)

Each node generates **16 cryptographically-random bytes = `myNonce`** at start. Re-rolled on:
BT adapter cycle, app (process) restart, or explicit reset. It is **not** derived from any MAC,
platform, or stable hardware id, so it satisfies "unbiased, in-band, address-independent."

The nonce does double duty:

- **Tiebreaker** (who initiates): compare `myNonce` vs `peerNonce` lexicographically (unsigned,
  byte 0 most significant). **Greater nonce = INITIATOR.**
- **Dedup key** (which logical peer): all per-peer state is keyed by `peerNonce`, NOT by address.
  Because the nonce is stable across BLE address rotation, a peer that rotates its address is
  still recognized as the same logical peer → no duplicate channel. This is the entire answer to
  "do not use MAC as identity/dedup."

128 bits makes collision (a tie) astronomically unlikely; we still handle it (§3, tie rule).

---

## 3. Convergence algorithm (the crux)

### 3.1 Invariant we converge to

> The single channel is always **INITIATOR (central, greater nonce) → ACCEPTOR (peripheral,
> lesser nonce)'s PSM.** L2CAP is opened by the central onto the peripheral's published PSM.
> The acceptor **never** opens an L2CAP channel toward the initiator.

This binds the abstract "who wins" to BLE's concrete asymmetry (central opens, peripheral
accepts), which is what eliminates duplicates and livelock.

### 3.2 Both roles always on

Every node runs, for its entire lifetime and simultaneously:

- **Peripheral:** advertising `HOP_SVC` (connectable), a GATT server with `HOP_RV`, and a
  **published L2CAP PSM** ready to accept.
- **Central:** one persistent scan filtered to `HOP_SVC`.

Advertising and scanning are **never stopped** on connect (Android scan-throttle + dual-role +
fast recovery all demand this).

### 3.3 Per-link decision (symmetric, identical code both platforms)

A "link" = one GATT/ACL connection. Both peers may connect out at once (transient double-connect);
we resolve to one. `chanByNonce: Map<Nonce, ChannelState{CONNECTING,OPENING,ESTABLISHED}>`.

**When I am the CENTRAL on a link (I dialed out):**
1. Discover services → find `HOP_RV`.
2. **WRITE** `myNonce` to peer `HOP_RV` (peripheral learns my nonce).
3. **READ** peer `HOP_RV` → `peerNonce`, `peerPsm`.
4. **Dedup:** if `chanByNonce[peerNonce]` is OPENING/ESTABLISHED → **disconnect this link** (it's a
   duplicate, e.g. simultaneous discovery or post-rotation re-meet). Done.
5. `amInitiator = myNonce > peerNonce`:
   - **Initiator:** mark `chanByNonce[peerNonce]=OPENING`; **open L2CAP to `peerPsm` on this link.**
     This link is the keeper.
   - **Acceptor (I dialed but I should be accepting, wrong direction):** **disconnect this link.**
     The initiator will reach me via its own scan→connect to my advert (I'm always advertising +
     PSM published). No gap, because my peripheral side is always up.

**When I am the PERIPHERAL on a link (peer dialed me):**
1. On the central's **WRITE**, I learn `peerNonce`.
2. `amInitiator = myNonce > peerNonce`:
   - **Acceptor (peer is initiator):** this is the keeper. Wait for the central's `openL2CAPChannel`
     → my `didOpen`/accepted socket on the published PSM. Mark ESTABLISHED on L2CAP up.
   - **Initiator (peer dialed me but I should dial, wrong direction):** do nothing here; my own
     scanner will find this peer's advert and I'll dial out (→ central path, initiator). The peer
     tears down its wrong-direction link per the acceptor rule above.

**Tie (`myNonce == peerNonce`):** re-roll `myNonce`, re-set the advertisement/GATT record, drop the
link, rediscover. Deterministic termination (probability ~2⁻¹²⁸ per meet).

### 3.4 Why this converges with zero duplicates / zero livelock

- **Simultaneous mutual discovery:** both dial out → two ACL links. The acceptor's outbound is
  torn down (wrong-direction rule); the initiator's outbound becomes the keeper. If the initiator
  *also* got an inbound link from the acceptor first, step-4 dedup by `peerNonce` drops the extra.
  Net: exactly one L2CAP, initiator→acceptor.
- **Only one side discovered the other:** if only the acceptor discovered the initiator, the
  acceptor's link is wrong-direction and is dropped; the initiator's always-on scanner then finds
  the acceptor and dials → keeper. If only the initiator discovered, it's the keeper immediately.
- **No livelock:** the decision is a pure function of the two fixed nonces; both sides compute the
  same winner. There is no "both back off" or "both retry" oscillation: exactly one side ends up
  in OPENING.
- **Address rotation:** identity is the nonce, not the address. A rotated re-meet hits dedup
  (ESTABLISHED to that nonce) and is dropped. An established connection survives the *advertiser*
  rotating (rotation only affects new discovery, not a live ACL).

### 3.5 Per-peer connect backoff (anti-thrash, not anti-livelock)

On a *failed* dial/handshake to a given `peerNonce` (or address pre-nonce), apply backoff
250 ms → 500 ms → 1 s (cap) before re-dialing that peer, reset on success. This only smooths
hardware retry; the convergence decision itself never oscillates.

---

## 4. The EXACT channel-open handshake (every call, in order)

Roles below are after the §3 decision: **INITIATOR** = greater nonce = central/dialer;
**ACCEPTOR** = lesser nonce = peripheral.

### 4.1 ACCEPTOR setup (peripheral), done once at startup, both platforms

**Apple:**
```
1. CBPeripheralManager(delegate:queue:)                       // powers on
2. (didUpdateState .poweredOn)
3. let svc = CBMutableService(type: HOP_SVC, primary: true)
4. let rv  = CBMutableCharacteristic(type: HOP_RV,
                 properties: [.read, .write],
                 value: nil, permissions: [.readable, .writeable])
5. svc.characteristics = [rv]; pm.add(svc)
6. pm.publishL2CAPChannel(withEncryption: false)             // -> didPublishL2CAPChannel(psm)
7. pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [HOP_SVC],
                        CBAdvertisementDataLocalNameKey: "hop"]) // name only helps in fg
```
**Android:**
```
1. serverSocket = adapter.listenUsingInsecureL2capChannel()  // LE CoC, no bonding
2. psm = serverSocket.psm; spawn thread: loop { serverSocket.accept() -> BluetoothSocket }
3. gattServer = btMgr.openGattServer(ctx, gattServerCallback)
4. svc = BluetoothGattService(HOP_SVC, SERVICE_TYPE_PRIMARY)
5. rv  = BluetoothGattCharacteristic(HOP_RV,
             PROPERTY_READ | PROPERTY_WRITE,
             PERMISSION_READ | PERMISSION_WRITE)
6. svc.addCharacteristic(rv); gattServer.addService(svc)
7. advertiser.startAdvertising(settings, AdvertiseData{ serviceUuid HOP_SVC }, advCallback)
```

### 4.2 INITIATOR dial + open (central), Apple

```
1. central.scanForPeripherals(withServices: [HOP_SVC],
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
2. (didDiscover peripheral) -> central.connect(peripheral, options: nil)
3. (didConnect) -> peripheral.delegate = self; peripheral.discoverServices([HOP_SVC])
4. (didDiscoverServices) -> peripheral.discoverCharacteristics([HOP_RV], for: svc)
5. (didDiscoverCharacteristicsFor) ->
       peripheral.writeValue(myRecord, for: rv, type: .withResponse)   // push my nonce
6. (didWriteValueFor rv) -> peripheral.readValue(for: rv)              // pull peer nonce+psm
7. (didUpdateValueFor rv) -> parse peerNonce, peerPsm
       dedup(peerNonce); amInitiator = myNonce > peerNonce
       if amInitiator: peripheral.openL2CAPChannel(peerPsm)
       else: central.cancelPeripheralConnection(peripheral)   // wrong-direction, drop
8. (didOpen channel:) -> bind streams (see §6); state = ESTABLISHED
```

### 4.3 INITIATOR dial + open (central), Android

```
1. scanner.startScan([ScanFilter serviceUuid HOP_SVC],
        ScanSettings{ SCAN_MODE_LOW_LATENCY, CALLBACK_TYPE_ALL_MATCHES,
                      MATCH_MODE_AGGRESSIVE }, scanCallback)
2. (onScanResult) -> result.device.connectGatt(ctx, false, gattCb, TRANSPORT_LE)
3. (onConnectionStateChange CONNECTED) -> gatt.requestMtu(247) [optional] -> gatt.discoverServices()
4. (onServicesDiscovered) -> rv = gatt.getService(HOP_SVC).getCharacteristic(HOP_RV)
       rv.value = myRecord; gatt.writeCharacteristic(rv)               // push my nonce
5. (onCharacteristicWrite OK) -> gatt.readCharacteristic(rv)           // pull peer nonce+psm
6. (onCharacteristicRead OK) -> parse peerNonce, peerPsm
       dedup(peerNonce); amInitiator = myNonce > peerNonce
       if amInitiator:
           sock = result.device.createInsecureL2capChannel(peerPsm)
           thread { sock.connect(); bindStreams(sock) }               // -> ESTABLISHED
       else: gatt.disconnect(); gatt.close()                          // wrong-direction, drop
```

### 4.4 ACCEPTOR accept (peripheral), both platforms

```
Apple:   (peripheralManager didReceiveWrite reqs) -> parse central nonce from rv write;
                pm.respond(to: req, withResult: .success)
         (peripheralManager didReceiveRead req)   -> req.value = myRecord; pm.respond(.success)
         (peripheralManager didOpen channel:)     -> bind streams; state = ESTABLISHED   // CENTRAL opened L2CAP to my PSM
Android: (gattServerCallback onCharacteristicWriteRequest) -> parse central nonce;
                gattServer.sendResponse(device, reqId, GATT_SUCCESS, 0, null)
         (gattServerCallback onCharacteristicReadRequest)  -> gattServer.sendResponse(
                device, reqId, GATT_SUCCESS, offset, myRecord)
         (accept thread) serverSocket.accept() returns BluetoothSocket -> bindStreams  // ESTABLISHED
```

The order is identical in spirit on both platforms: **central WRITEs its nonce → READs peer
nonce+PSM → decides → (initiator) opens L2CAP; peripheral just answers GATT then accepts L2CAP.**

---

## 5. Data framing (pure byte mover)

Length-prefixed binary frames over the L2CAP byte stream:

```
[ u32 length BE ][ u8 type ][ payload[length-1] ]      length covers type+payload, max 65536
type 0x01 DATA      payload = arbitrary bytes (upper layer pushes handshake/messages here)
type 0x02 COUNTER   payload = u64 BE monotonic counter   (proof-of-pipe + doubles as keepalive)
type 0x03 KEEPALIVE payload = empty                      (sent only if no DATA/COUNTER due)
```

L2CAP delivers a **stream**, not messages: readers MUST accumulate bytes until a full frame is
present, then dispatch; handle multiple frames per read and a frame split across reads. Writers
must handle partial writes (Android `OutputStream.write` blocks/flushes; iOS `OutputStream` only
writes when `.hasSpaceAvailable`).

---

## 6. Keepalive + liveness (fast, OS-independent)

- **Send:** every node emits a frame **every 1000 ms** on each established channel, a COUNTER
  (incrementing) if it has nothing else to send, else any DATA frame resets the timer (a DATA
  frame counts as liveness too). This is the spec's "increasing counter / ping each second."
- **Receive/liveness:** maintain `lastRxMonotonic`. If **no inbound frame of any type for 3000 ms**
  (3 missed beats) → declare the link **dead** → tear down (close L2CAP + cancel ACL), purge
  `chanByNonce[peerNonce]`, return to discovery. 3 s detection regardless of OS supervision timeout
  (vital: Android's ~20 s is unacceptable).
- **Health metric:** track the peer's COUNTER. Healthy = strictly increasing with no gaps. A gap or
  stall is logged (proves "maintained," not just "connected once").

---

## 7. Recovery state machine (per peer, keyed by nonce)

```
        startup: ADV + SCAN + GATT-server + PSM-published  (always on, never stopped)
                              |
        discover peer advert  v
   [DIALING]--connect-->[DISCOVER]--write/read RV-->[DECIDE]
        |                                              |
        | wrong-direction or dedup hit                 | initiator: openL2CAP
        v                                              v
     (drop link)                                 [OPENING]--didOpen/accept-->[ESTABLISHED]
                                                                                  |
   keepalive every 1s; liveness 3s; track counter <----------------------------- |
                                                                                  |
   on liveness-fail OR ACL disconnect OR stream error:                           v
        TEARDOWN: close L2CAP+ACL, purge chanByNonce[peerNonce], backoff, --> back to discovery
```

- **Drop recovery:** teardown purges state; the always-on scan/advert immediately re-discovers the
  peer; nonce dedup prevents a double channel during the race.
- **Address rotation:** same nonce on the new advert → dedup recognizes it; if a live channel
  exists, the new link is dropped; if not, it becomes the new keeper.
- **Rapid meet/part:** because advert+scan never stop and state is nonce-keyed, each cycle is just
  another discover→decide→establish; backoff (§3.5) prevents hardware thrash. Indefinite.

---

## 8. Reference source: Android (Kotlin), critical paths

```kotlin
// HOP convergence-first BLE transport, critical paths only. API 29+ (insecure L2CAP CoC).
// Manifest: BLUETOOTH_ADVERTISE, BLUETOOTH_CONNECT, BLUETOOTH_SCAN (neverForLocation),
//           ACCESS_FINE_LOCATION on <=30. Requires adapter.isLe2MPhySupported not required.

val HOP_SVC: UUID = UUID.fromString("7B11A000-9C3E-4D2A-B6F1-0A11CE5500A1")
val HOP_RV:  UUID = UUID.fromString("7B11A001-9C3E-4D2A-B6F1-0A11CE5500A1")

val myNonce = ByteArray(16).also { SecureRandom().nextBytes(it) }   // §2 in-band identity
@Volatile var myPsm = 0
val chanByNonce = ConcurrentHashMap<String, String>()               // nonceHex -> state

fun record(psm: Int) = ByteArray(20).apply {
    this[0] = 1
    System.arraycopy(myNonce, 0, this, 1, 16)
    this[17] = (psm ushr 8).toByte(); this[18] = psm.toByte()
    this[19] = 0
}
fun cmpGreater(a: ByteArray, b: ByteArray): Boolean {              // a > b unsigned
    for (i in 0 until 16) { val x=a[i].toInt() and 0xff; val y=b[i].toInt() and 0xff
        if (x!=y) return x>y }; return false
}

// --- ACCEPTOR setup (peripheral) ---
val serverSocket = adapter.listenUsingInsecureL2capChannel()       // LE CoC, NO bonding (§0.2)
myPsm = serverSocket.psm
thread {                                                            // accept loop (acceptor keeper)
    while (true) { val s = serverSocket.accept(); bindStreams(s.inputStream, s.outputStream, s) }
}
val gattServer = btMgr.openGattServer(ctx, object : BluetoothGattServerCallback() {
    override fun onCharacteristicReadRequest(d: BluetoothDevice, id: Int, off: Int,
            c: BluetoothGattCharacteristic) {                      // central pulls my nonce+psm
        gattServer.sendResponse(d, id, BluetoothGatt.GATT_SUCCESS, off,
            record(myPsm).copyOfRange(off, 20))
    }
    override fun onCharacteristicWriteRequest(d: BluetoothDevice, id: Int,
            c: BluetoothGattCharacteristic, prep: Boolean, rsp: Boolean, off: Int, v: ByteArray) {
        val peerNonce = v.copyOfRange(1, 17)                       // central pushed its nonce
        if (rsp) gattServer.sendResponse(d, id, BluetoothGatt.GATT_SUCCESS, 0, null)
        // peripheral side: if I'm acceptor (peer greater) wait for L2CAP accept(); else my scan dials.
    }
})
gattServer.addService(BluetoothGattService(HOP_SVC, BluetoothGattService.SERVICE_TYPE_PRIMARY)
    .apply { addCharacteristic(BluetoothGattCharacteristic(HOP_RV,
        PROPERTY_READ or PROPERTY_WRITE, PERMISSION_READ or PERMISSION_WRITE)) })

advertiser.startAdvertising(
    AdvertiseSettings.Builder().setAdvertiseMode(ADVERTISE_MODE_LOW_LATENCY)
        .setConnectable(true).setTimeout(0)
        .setTxPowerLevel(ADVERTISE_TX_POWER_MEDIUM).build(),
    AdvertiseData.Builder().setIncludeDeviceName(false)            // name overflows 31B; omit
        .addServiceUuid(ParcelUuid(HOP_SVC)).build(),             // only anchor (§0.1)
    object : AdvertiseCallback() {})

// --- INITIATOR/central: one persistent scan (never restart; §0.4) ---
scanner.startScan(
    listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(HOP_SVC)).build()),
    ScanSettings.Builder().setScanMode(SCAN_MODE_LOW_LATENCY)
        .setCallbackType(CALLBACK_TYPE_ALL_MATCHES)
        .setMatchMode(MATCH_MODE_AGGRESSIVE).build(),
    object : ScanCallback() {
        override fun onScanResult(t: Int, r: ScanResult) {
            r.device.connectGatt(ctx, false, gattCb, BluetoothDevice.TRANSPORT_LE)
        }
    })

val gattCb = object : BluetoothGattCallback() {
    override fun onConnectionStateChange(g: BluetoothGatt, st: Int, ns: Int) {
        if (ns == BluetoothProfile.STATE_CONNECTED) g.discoverServices()
        else { g.close() /* teardown -> rediscover */ }
    }
    override fun onServicesDiscovered(g: BluetoothGatt, st: Int) {
        val rv = g.getService(HOP_SVC).getCharacteristic(HOP_RV)
        rv.value = record(0)                                       // push my nonce (psm=0)
        rv.writeType = WRITE_TYPE_DEFAULT; g.writeCharacteristic(rv)
    }
    override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, st: Int) {
        g.readCharacteristic(c)                                    // pull peer nonce+psm
    }
    override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, st: Int) {
        val v = c.value
        val peerNonce = v.copyOfRange(1,17); val nHex = peerNonce.toHex()
        val peerPsm = ((v[17].toInt() and 0xff) shl 8) or (v[18].toInt() and 0xff)
        if (chanByNonce.putIfAbsent(nHex, "OPENING") != null) { g.disconnect(); g.close(); return } // dedup
        if (cmpGreater(myNonce, peerNonce)) {                      // INITIATOR -> open L2CAP
            thread {
                val s = g.device.createInsecureL2capChannel(peerPsm)
                s.connect(); bindStreams(s.inputStream, s.outputStream, s)
            }
        } else { chanByNonce.remove(nHex); g.disconnect(); g.close() } // wrong-direction acceptor drop
    }
}
```

`bindStreams(...)` runs the §5 framer + §6 keepalive(1s)/liveness(3s) on a worker thread; on
liveness fail or IOException it closes the socket, `chanByNonce.remove(nHex)`, and returns to scan.

## 9. Reference source: Apple (Swift / CoreBluetooth), critical paths

```swift
// HOP convergence-first BLE transport, critical paths. macOS CLI build first (swiftc + CoreBluetooth),
// same code as iOS. Info.plist (iOS): NSBluetoothAlwaysUsageDescription; UIBackgroundModes:
// bluetooth-central, bluetooth-peripheral.

let HOP_SVC = CBUUID(string: "7B11A000-9C3E-4D2A-B6F1-0A11CE5500A1")
let HOP_RV  = CBUUID(string: "7B11A001-9C3E-4D2A-B6F1-0A11CE5500A1")

var myNonce = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
var myPsm: UInt16 = 0
var chanByNonce = [Data: String]()                                 // nonce -> state

func record(_ psm: UInt16) -> Data {
    var d = Data([1]); d.append(contentsOf: myNonce)
    d.append(UInt8(psm >> 8)); d.append(UInt8(psm & 0xff)); d.append(0); return d   // 20 bytes
}
func greater(_ a: [UInt8], _ b: Data) -> Bool {                    // a > b unsigned
    for i in 0..<16 { if a[i] != b[i+1] { return a[i] > b[i+1] } }; return false
}

// --- ACCEPTOR setup (peripheral) ---  CBPeripheralManagerDelegate
func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
    guard pm.state == .poweredOn else { return }
    let rv = CBMutableCharacteristic(type: HOP_RV, properties: [.read, .write],
                                     value: nil, permissions: [.readable, .writeable])
    let svc = CBMutableService(type: HOP_SVC, primary: true); svc.characteristics = [rv]
    pm.add(svc)
    pm.publishL2CAPChannel(withEncryption: false)                  // -> didPublishL2CAPChannel (§0.2)
    pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [HOP_SVC],
                         CBAdvertisementDataLocalNameKey: "hop"])  // name only used in foreground
}
func peripheralManager(_ pm: CBPeripheralManager, didPublishL2CAPChannel psm: CBL2CAPPSM,
                       error: Error?) { myPsm = UInt16(psm) }
func peripheralManager(_ pm: CBPeripheralManager, didReceiveRead req: CBATTRequest) {
    req.value = record(myPsm).subdata(in: req.offset..<20); pm.respond(to: req, withResult: .success)
}
func peripheralManager(_ pm: CBPeripheralManager, didReceiveWrite reqs: [CBATTRequest]) {
    for r in reqs { if let v = r.value, v.count >= 17 { _ = v.subdata(in: 1..<17) /* peerNonce */ } }
    pm.respond(to: reqs[0], withResult: .success)
}
func peripheralManager(_ pm: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
    if let ch = channel { bind(ch) }                              // acceptor keeper: central opened to my PSM
}

// --- INITIATOR (central) ---  CBCentralManagerDelegate / CBPeripheralDelegate
func centralManagerDidUpdateState(_ c: CBCentralManager) {
    if c.state == .poweredOn {
        c.scanForPeripherals(withServices: [HOP_SVC],            // service-filtered (works in bg)
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
}
func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                    advertisementData: [String: Any], rssi: NSNumber) {
    p.delegate = self; conns[p.identifier] = p; c.connect(p, options: nil)   // retain p!
}
func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([HOP_SVC]) }
func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    if let s = p.services?.first { p.discoverCharacteristics([HOP_RV], for: s) }
}
func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
    if let rv = s.characteristics?.first { p.writeValue(record(0), for: rv, type: .withResponse) }
}
func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
    p.readValue(for: c)                                          // pull peer nonce+psm
}
func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
    guard let v = c.value, v.count >= 19 else { return }
    let peerNonce = v.subdata(in: 1..<17)
    let peerPsm = UInt16(v[17]) << 8 | UInt16(v[18])
    if chanByNonce[peerNonce] != nil { central.cancelPeripheralConnection(p); return }  // dedup
    if greater(myNonce, peerNonce) {                            // INITIATOR -> open L2CAP
        chanByNonce[peerNonce] = "OPENING"; p.openL2CAPChannel(CBL2CAPPSM(peerPsm))
    } else { central.cancelPeripheralConnection(p) }            // wrong-direction acceptor drop
}
func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
    if let ch = channel { bind(ch) }                            // initiator keeper -> ESTABLISHED
}
```

`bind(_ ch: CBL2CAPChannel)` opens `ch.inputStream`/`ch.outputStream`, schedules them on a
RunLoop, and runs the §5 framer + §6 keepalive(1s)/liveness(3s). On `.errorOccurred`/`.endEncountered`
or liveness fail it closes streams, removes the nonce entry, and discovery resumes (scan never stopped).
Note: you MUST retain discovered `CBPeripheral`s (`conns[p.identifier]=p`) or CoreBluetooth drops them.

---

## 10. Bring-up + reliability TEST procedure (the rig)

**Build/run (fast loop = macOS CLI ↔ Android over adb):**
- Apple: model on `apple/hopmac/build.sh`, `swiftc -O ... -framework CoreBluetooth ...` →
  run the binary from Terminal (so logs hit stdout; grant Bluetooth permission once).
- Android: model on `android/HopDemo` gradlew/SDK config; install, `adb logcat -s HOPBLE`.
  Cycle the stack with `adb shell cmd bluetooth_manager disable` / `enable`.

**Stage A, same-platform (table stakes):** mac↔mac, then Android↔Android. Confirm exactly one
channel and counters advancing.

**Stage B, cross-platform (the real test):** macOS CLI ↔ Android. Then iOS device ↔ Android.

**Stage C, convergence stress:**
1. Cold meet: start both; assert each logs **exactly one** `ESTABLISHED` and identical
   `peerNonce`/initiator decision (one INITIATOR, one ACCEPTOR). No second channel within 30 s.
2. Simultaneous start: launch both within <200 ms (script both). Assert still exactly one channel
   (one side logs "wrong-direction drop" and/or "dedup drop").
3. Drop/recover: `adb ... bluetooth_manager disable` then `enable`; assert re-`ESTABLISHED`
   < ~5 s, counters resume increasing, never two channels.
4. Address rotation: leave running > 15 min (or force re-advertise). Assert no duplicate channel
   appears; nonce dedup logs the rotated re-meet as the same peer.
5. Meet/part loop: walk out of range / kill+restart advertiser 20× in a row. Assert every cycle
   re-converges to one channel; no leaked/duplicate channels; no livelock (never two sides stuck
   dialing).

**EXACT signals that prove "established AND maintained" (not just "connected once"):**
- `state=ESTABLISHED peerNonce=<hex> role=INIT|ACCEPTOR psm=<n>`, exactly one per peer per device.
- `rx_counter` strictly increasing, no gaps, for ≥ 5 minutes continuous (the core proof).
- `keepalive ok` heartbeat and **zero** `liveness_timeout` events while in range.
- On induced failure: `liveness_timeout` (≤3 s after stall) **then** a fresh single `ESTABLISHED`
  with resumed counters, proving deterministic recovery.
- Channel-count invariant: a `channels_open` gauge that is **always exactly 1** between the two
  devices whenever both are in range (the convergence guarantee, instrumented).

---

## 11. Justification of key API choices (one line each)

- **Service UUID as the only advertised payload**, only thing discoverable cross-platform incl.
  iOS background (overflow area decodes the UUID for an iOS scanner; Android scans the UUID
  directly when iOS is foreground). Tiebreaker can't ride the advert cross-platform (§0.1).
- **16-byte random nonce over GATT, not address**, unbiased, platform-neutral, survives MAC
  rotation; serves as both tiebreaker and dedup key (§2), the whole convergence hinges on it.
- **One GATT characteristic, write-then-read**, peripheral can't read the central, so central
  pushes its nonce (write) and pulls the peripheral's record (read); single char avoids the
  PSM-read stall seen with over-built services (§0.5).
- **Insecure L2CAP CoC** (`listenUsingInsecureL2capChannel`/`createInsecureL2capChannel`,
  `publishL2CAPChannel(withEncryption:false)`/`openL2CAPChannel`), only variant that works
  iOS↔Android with no bonding/user interaction; matches "transport is a pure byte mover" (§0.2).
- **Greater-nonce = central/initiator**, binds the abstract winner to BLE's central-opens
  asymmetry, so the keeper link is unambiguous and the loser's link is provably redundant (§3).
- **App-level 1 s keepalive / 3 s liveness**, OS supervision timeout is 750 ms (iOS) vs ~20 s
  (Android) and a peripheral can't force params; app-level liveness gives uniform ~3 s detection
  (§0.3, §6).
- **Single persistent scan, never restarted**, Android's 5-scans/30 s throttle would silently
  break recovery otherwise (§0.4).
```
