// HopBleLab: SHARED CORE for the canonical dual-role BLE "proof of pipe" (ble-lab/SPEC.md §8).
//
// This file contains ALL BLE logic and NO platform-specific bootstrap. It is meant to be compiled
// UNCHANGED into either:
//   • the macOS CLI target (main.swift sets nothing; the defaults below run everything on .main), or
//   • a future minimal iOS app target (the app overrides `bleQueue` / `bleRunLoop` / `bleAppInBackground`
//     per SPEC §8.1 BEFORE constructing `Node()`, no edits to this file required).
//
// Every device runs the symmetric dual role: it is simultaneously a BLE peripheral (advertises the
// service, runs a GATT server with one READ characteristic returning [2B PSM][16B nodeId], hosts an
// insecure L2CAP CoC listener) AND a BLE central (one service-filtered scan, GATT client, L2CAP
// dialer). ALL data flows over L2CAP; GATT is only the PSM/nodeId read. Convergence to exactly one
// channel is driven by a random 16-byte nodeId (greater nodeId dials), with post-HELLO dedup as the
// universal backstop. Reliability is a 1 Hz PING that IS the proof counter, plus an adaptive liveness
// watchdog and a 3 s half-open reaper.
//
// Fresh UUID/bundle scheme (does NOT collide with apple/hopmac's F09… service): SERVICE 7ED70001…,
// CHAR 7ED70002…, restore ids "hoplab.ble.*", bundle sh.hopme.blelab.

import Foundation
import CoreBluetooth
import Security

// MARK: - Fresh service scheme (SPEC §1.1) -------------------------------------------------------

let SERVICE_UUID  = CBUUID(string: "7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F")   // advertised + GATT service
let ENDPOINT_CHAR = CBUUID(string: "7ED70002-3C2A-4F19-9B8E-1A2B3C4D5E6F")   // GATT READ -> [2B PSM BE][16B nodeId]
let MFG_COMPANY_ID: UInt16 = 0xFFFF                                          // "reserved for testing" company id

let RESTORE_ID_PERIPHERAL = "hoplab.ble.peripheral"
let RESTORE_ID_CENTRAL    = "hoplab.ble.central"

// SPEC §5 timing.
let PING_S: Double  = 1.0     // 1 Hz PING == the proof counter
let DEAD_FG_S: Double = 5.0   // foreground liveness deadline
let DEAD_BG_S: Double = 15.0  // background liveness deadline (iOS relaxes conn interval in bg)
let REAP_S: Double  = 3.0     // half-open (no-HELLO) reaper
let WAIT_BASE_S: Double = 4.0 // wait-timeout safety net (SPEC §2.2)
let DIAL_TIMEOUT_S: Double = 12.0
let MAX_FRAME = 4 * 1024 * 1024
let STABLE_UP_MS: UInt64 = 30_000
let LOST_S: Double = 30.0

// MARK: - Platform config (SPEC §8 / §8.1). Overridable by the iOS app BEFORE Node() ------------
//
// CLI default: everything on .main (no UI contends, SPEC R8). The iOS app target instead points
// bleQueue at a dedicated serial queue and bleRunLoop at a dedicated I/O thread's RunLoop, and sets
// bleAppInBackground from scenePhase. Because these are plain mutable globals, the iOS app reassigns
// them without touching this file.
var bleQueue: DispatchQueue = .main
var bleRunLoop: RunLoop = .main
var bleAppInBackground = false

// MARK: - Small helpers -------------------------------------------------------------------------

private let processStart = Date()
/// Grep-able structured log. Every line begins with `HOPLAB`. Categories: STATE, PROOF, DEDUP, STATUS, WARN.
func log(_ category: String, _ message: String) {
    let t = Date().timeIntervalSince(processStart)
    print("HOPLAB \(String(format: "%9.3f", t)) \(category) \(message)")   // stdout (macOS CLI capture)
    NSLog("HOPLAB %9.3f %@ %@", t, category, message)   // unified log too → iOS device log capturable (idb/Console) for diagnosis
}

func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
func nowS()  -> Double { Date().timeIntervalSince1970 }
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func shortHex(_ d: Data?) -> String { d.map { hex($0.prefix(4)) } ?? "????????" }

/// Unsigned big-endian compare: a > b (byte 0 most significant). SPEC §1.2 tiebreaker primitive.
func gt(_ a: Data, _ b: Data) -> Bool {
    for i in 0..<min(a.count, b.count) where a[i] != b[i] { return a[i] > b[i] }
    return a.count > b.count
}

private func randomNodeId() -> Data {
    var d = Data(count: 16)
    let rc = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
    if rc != errSecSuccess {                       // defensive fallback; SystemRandom is CSPRNG-grade on Apple
        d = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }
    return d
}

// MARK: - Link: one L2CAP channel, 4-byte BE framing, 1 Hz PING (proof), adaptive watchdog -------
// SPEC §4 framing, §3.3 HELLO, §5 keepalive/liveness.

final class Link: NSObject, StreamDelegate {
    let isDialer: Bool
    let myId: Data
    private(set) var peerId: Data?                 // learned from HELLO; the dedup/tiebreak key
    private(set) var up = false

    // CRITICAL: retain the CBL2CAPChannel for the link's whole life. inputStream/outputStream are
    // just views onto the channel's socket fd; if the channel deallocs, that fd is closed and the
    // streams immediately fail with POSIX EBADF (Bad file descriptor) right after openCompleted.
    // (Android's Link stores the BluetoothSocket for the same reason.)
    private let channel: CBL2CAPChannel
    private let input: InputStream
    private let output: OutputStream
    private var inBuf = [UInt8]()
    private var outBuf = [UInt8]()

    private var lastRxMs = nowMs()
    private let openedMs = nowMs()
    private var becameUpMs: UInt64?
    private var ewmaGapMs = 1000.0                  // inbound inter-arrival EWMA (SPEC R7)
    private var txSeq: UInt64 = 0
    private var rxSeq: UInt64 = 0
    private var lastRttMs: UInt64 = 0

    private var ping: Timer?
    private var watchdog: Timer?
    private let onUp: (Link) -> Void
    private let onClose: (Link) -> Void
    private var closed = false
    // CRITICAL: a Link is only inserted into Node.linksByPeerId in onUp, i.e. AFTER the peer's HELLO
    // arrives. Before that, nothing else holds a strong ref (stream delegates are weak; the ping/
    // watchdog timer blocks are [weak self]), so ARC would free the Link milliseconds after didOpen
    // creates it, tearing down the L2CAP streams before HELLO ever completes (the peer sees EOF). So
    // the Link OWNS ITSELF from creation until close(); the reaper guarantees close() within REAP_S.
    private var selfRetain: Link?

    // Read-only views for STATUS / dedup (SPEC §2.3, §6).
    var rx: UInt64 { rxSeq }
    var tx: UInt64 { txSeq }
    var rttMs: UInt64 { lastRttMs }
    var peerShort: String { shortHex(peerId) }
    /// SPEC §6: a link that stayed UP >= 30 s resets backoff.
    var stableUp: Bool { guard let b = becameUpMs else { return false }; return nowMs() - b >= STABLE_UP_MS }

    init(channel: CBL2CAPChannel, isDialer: Bool, myId: Data,
         onUp: @escaping (Link) -> Void, onClose: @escaping (Link) -> Void) {
        self.isDialer = isDialer
        self.myId = myId
        self.onUp = onUp
        self.onClose = onClose
        self.channel = channel                 // retain the channel (keeps the socket fd alive)
        self.input = channel.inputStream
        self.output = channel.outputStream
        super.init()

        log("STATE", "channel-open isDialer=\(isDialer), scheduling streams")
        for s in [input, output] {
            s.delegate = self
            s.schedule(in: bleRunLoop, forMode: .common)
            s.open()
        }
        // HELLO first (SPEC §3.3): [0x01][16B nodeId][1B role][1B flags]
        var hello = Data([0x01]); hello.append(myId); hello.append(isDialer ? 1 : 0); hello.append(0)
        sendFrame(hello)
        log("STATE", "hello-sent isDialer=\(isDialer)")

        let p = Timer(timeInterval: PING_S, repeats: true) { [weak self] _ in self?.sendPing() }
        let w = Timer(timeInterval: 1.0,    repeats: true) { [weak self] _ in self?.tick() }
        bleRunLoop.add(p, forMode: .common)
        bleRunLoop.add(w, forMode: .common)
        ping = p; watchdog = w
        selfRetain = self          // own our lifecycle until close() (see selfRetain decl)
    }

    private func deadLimitS() -> Double {          // SPEC R7: adaptive deadline
        max(bleAppInBackground ? DEAD_BG_S : DEAD_FG_S, 3.0 * ewmaGapMs / 1000.0)
    }

    private func tick() {
        if !up && Double(nowMs() - openedMs) / 1000 > REAP_S { close("no-HELLO reap"); return }
        if up && Double(nowMs() - lastRxMs) / 1000 > deadLimitS() { close("liveness DEAD") }
    }

    private func sendPing() {
        guard !closed else { return }
        txSeq += 1
        var b = Data([0x02]); appU64(&b, txSeq); appU64(&b, nowMs())   // PING [seq][t_send_ms]
        sendFrame(b)
    }

    private func sendFrame(_ body: Data) {
        guard !closed else { return }
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { outBuf.append(contentsOf: $0) }
        outBuf.append(contentsOf: body)
        drain()
    }

    func close(_ why: String) {
        guard !closed else { return }
        closed = true
        ping?.invalidate(); watchdog?.invalidate()
        for s in [input, output] { s.close(); s.remove(from: bleRunLoop, forMode: .common) }
        log("STATE", "LINK CLOSED (\(why)) peer=\(peerShort) isDialer=\(isDialer)")
        onClose(self)
        selfRetain = nil           // release self, safe to dealloc now (see selfRetain decl)
    }

    func stream(_ s: Stream, handle e: Stream.Event) {
        let which = (s === input) ? "input" : "output"
        switch e {
        case .openCompleted: log("STATE", "stream \(which) openCompleted")        // DIAG
        case .hasBytesAvailable: read()
        case .hasSpaceAvailable: drain()
        case .endEncountered: close("stream \(which) .endEncountered")            // DIAG
        case .errorOccurred: close("stream \(which) .errorOccurred err=\(s.streamError.map { String(describing: $0) } ?? "nil")")  // DIAG
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
        let gap = Double(nowMs() - lastRxMs)
        ewmaGapMs = 0.8 * ewmaGapMs + 0.2 * gap
        lastRxMs = nowMs()
        deframe()
    }

    private func deframe() {
        while inBuf.count >= 4 {
            let len = Int(UInt32(inBuf[0]) << 24 | UInt32(inBuf[1]) << 16 | UInt32(inBuf[2]) << 8 | UInt32(inBuf[3]))
            guard len >= 1, len <= MAX_FRAME else { close("bad len \(len)"); return }
            let total = 4 + len
            guard inBuf.count >= total else { break }
            handle(Array(inBuf[4..<total]))
            inBuf.removeFirst(total)
        }
    }

    private func handle(_ b: [UInt8]) {
        guard let type = b.first else { return }
        switch type {
        case 0x01:                                 // HELLO -> [16B nodeId][1B role][1B flags]
            if b.count >= 17 {
                peerId = Data(b[1..<17])
                if !up {
                    up = true
                    becameUpMs = nowMs()
                    log("STATE", "hello-recv peer=\(peerShort) role=\(b.count > 17 ? Int(b[17]) : -1)")
                    log("STATE", "LINK UP peer=\(peerShort) isDialer=\(isDialer)")
                    onUp(self)
                }
            }
        case 0x02:                                 // PING -> reply PONG; PING.seq IS the proof counter
            guard b.count >= 9 else { return }
            let seq = u64(b, 1)
            if rxSeq != 0 && seq != rxSeq + 1 { log("WARN", "counter gap \(rxSeq) -> \(seq) peer=\(peerShort)") }
            rxSeq = seq
            var pong = Data([0x03]); pong.append(contentsOf: b[1..<min(17, b.count)])
            sendFrame(pong)
            // Proof of pipe: log once per second, when the peer's counter advances. Shows BOTH
            // directions on one line (rx = peer's counter, tx = our counter, rtt = last round-trip).
            log("PROOF", "peer=\(peerShort) rx=\(rxSeq) tx=\(txSeq) rtt=\(lastRttMs)ms isDialer=\(isDialer)")
        case 0x03:                                 // PONG echoes our PING -> RTT (reverse direction live)
            if b.count >= 17 { let tSend = u64(b, 9); let now = nowMs(); if now >= tSend { lastRttMs = now - tSend } }
        default: break                             // 0x10 DATA -> upper layer (not used in the proof)
        }
    }

    private func appU64(_ d: inout Data, _ v: UInt64) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
    }
    private func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(b[o + i]) }
        return v
    }
}

// MARK: - ACCEPTOR (peripheral): listener (session-stable PSM) + GATT char + advertiser ----------
// SPEC §3.1.

final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    private var pm: CBPeripheralManager!
    private var psm: CBL2CAPPSM = 0
    private var published = false
    private let myId: Data
    private let onLink: (Link) -> Void
    private let onClose: (Link) -> Void
    private let onPowerOff: () -> Void

    init(myId: Data, onLink: @escaping (Link) -> Void, onClose: @escaping (Link) -> Void, onPowerOff: @escaping () -> Void) {
        self.myId = myId; self.onLink = onLink; self.onClose = onClose; self.onPowerOff = onPowerOff
        super.init()
        pm = CBPeripheralManager(delegate: self, queue: bleQueue,
                                 options: [CBPeripheralManagerOptionRestoreIdentifierKey: RESTORE_ID_PERIPHERAL])
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        log("STATE", "peripheral state=\(stateName(p.state))")
        if p.state == .poweredOff { onPowerOff(); published = false; return }   // SPEC R11
        guard p.state == .poweredOn else { return }
        let ch = CBMutableCharacteristic(type: ENDPOINT_CHAR, properties: .read, value: nil, permissions: .readable)
        let svc = CBMutableService(type: SERVICE_UUID, primary: true)
        svc.characteristics = [ch]
        p.add(svc)
        log("STATE", "peripheral gatt-service-added")
        p.publishL2CAPChannel(withEncryption: false)                            // INSECURE CoC (SPEC §1.1)
    }

    func peripheralManager(_ p: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error { log("STATE", "peripheral l2cap-publish-FAILED \(error.localizedDescription)"); return }
        psm = PSM
        published = true
        log("STATE", "peripheral l2cap-published psm=\(psm)")
        if ProcessInfo.processInfo.environment["HOPLAB_NO_ADV"] != nil {        // DIAG: central-only (suppress advertising)
            log("STATE", "peripheral advertising-SUPPRESSED (HOPLAB_NO_ADV), central-only diagnostic")
            return
        }
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID]])  // UUID only on Apple (SPEC §1.3)
        log("STATE", "peripheral advertising-started service=\(SERVICE_UUID.uuidString)")
    }

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        if let error { log("STATE", "peripheral advertising-FAILED \(error.localizedDescription)") }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead req: CBATTRequest) {
        var v = Data([UInt8(psm >> 8), UInt8(psm & 0xff)])                       // [2B PSM BE]
        v.append(myId)                                                          // [16B nodeId]
        req.value = v
        p.respond(to: req, withResult: .success)
        log("STATE", "peripheral read-request -> psm=\(psm) id=\(shortHex(myId))")
    }

    func peripheralManager(_ p: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error { log("STATE", "peripheral inbound-l2cap-FAILED \(error.localizedDescription)"); return }
        guard let channel else { return }
        log("STATE", "peripheral inbound-l2cap-open (acceptor)")
        // SPEC §8.1 iOS adaptation: hand the channel to the I/O thread so that
        // Stream.schedule(in: bleRunLoop) and Timer additions run on the thread that
        // owns bleRunLoop (safe per CFRunLoop thread-affinity rules). No-op when
        // bleRunLoop == .main (the macOS CLI default), since perform fires inline.
        let myId = self.myId, onLink = self.onLink, onClose = self.onClose
        bleRunLoop.perform {
            _ = Link(channel: channel, isDialer: false, myId: myId, onUp: onLink, onClose: onClose)
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // SPEC R10: re-add the GATT service BEFORE re-advertising, then re-publish L2CAP if needed.
        log("STATE", "peripheral willRestoreState")
    }
}

// MARK: - DIALER (central): scan -> connect -> read PSM/id -> openL2CAPChannel --------------------
// SPEC §3.2.

final class Central: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var cm: CBCentralManager!
    private let myId: Data

    private var retained = [UUID: CBPeripheral]()      // strong ref while dialing/linked (SPEC §3.2.3)
    private var dialTimers = [UUID: DispatchWorkItem]()  // SPEC R6: 12 s dial-timeout per peer
    private var pendingWaits = Set<UUID>()             // SPEC R4: one outstanding wait per peer
    private var advPrefixById = [UUID: Data]()         // backoff-key source (prefix once known)
    private var backoff = [String: Double]()           // SPEC R2: key = 6B-prefix hex (stable), else identifier

    private let onLink: (Link) -> Void
    private let onClose: (Link) -> Void
    private let onPowerOff: () -> Void
    private let haveLinkTo: (Data) -> Bool
    private let haveLinkToPrefix: (Data) -> Bool

    init(myId: Data,
         onLink: @escaping (Link) -> Void, onClose: @escaping (Link) -> Void, onPowerOff: @escaping () -> Void,
         haveLinkTo: @escaping (Data) -> Bool, haveLinkToPrefix: @escaping (Data) -> Bool) {
        self.myId = myId; self.onLink = onLink; self.onClose = onClose; self.onPowerOff = onPowerOff
        self.haveLinkTo = haveLinkTo; self.haveLinkToPrefix = haveLinkToPrefix
        super.init()
        cm = CBCentralManager(delegate: self, queue: bleQueue,
                              options: [CBCentralManagerOptionRestoreIdentifierKey: RESTORE_ID_CENTRAL])
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("STATE", "central state=\(stateName(c.state))")
        if c.state == .poweredOff { onPowerOff(); return }                      // SPEC R11
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: [SERVICE_UUID],                      // filter REQUIRED for bg scan
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log("STATE", "central scan-started service=\(SERVICE_UUID.uuidString)")
    }

    /// Background-wake hook (CoreLocation region enter, or app relaunch). Idempotent.
    /// Re-arms the service-filtered scan and pins a no-timeout connect to any peer the
    /// system still considers connected for our service, so the link can complete via
    /// state restoration even if the ~10 s scan window closes first.
    func wake(_ reason: String) {
        guard let cm = cm else { return }
        log("STATE", "WAKE(\(reason)) state=\(stateName(cm.state)) scanning=\(cm.isScanning)")
        guard cm.state == .poweredOn else { return }   // scan auto-starts on .poweredOn
        if !cm.isScanning {
            cm.scanForPeripherals(withServices: [SERVICE_UUID],
                                  options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            log("STATE", "WAKE re-armed scan")
        }
        for p in cm.retrieveConnectedPeripherals(withServices: [SERVICE_UUID]) where retained[p.identifier] == nil {
            log("STATE", "WAKE re-adopt connected id=\(p.identifier.uuidString.prefix(8))")
            dial(cm, p, advPrefixById[p.identifier])
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi: NSNumber) {
        var advPrefix: Data? = nil
        if let mfg = d[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 8,
           mfg[0] == 0xFF, mfg[1] == 0xFF { advPrefix = mfg.subdata(in: 2..<8) } // 6-byte nodeId prefix
        let bkey = advPrefix.map(hex) ?? p.identifier.uuidString
        if let until = backoff[bkey], nowS() < until { return }                 // SPEC R2: rate-limited
        if let pre = advPrefix, haveLinkToPrefix(pre) { return }                 // SPEC R4: already linked
        guard retained[p.identifier] == nil else { return }                     // already dialing
        let dialNow = advPrefix.map { gt(myId.prefix(6), $0) } ?? true          // SPEC §2.1 (no prefix => dial)
        log("STATE", "discovered id=\(p.identifier.uuidString.prefix(8)) prefix=\(advPrefix.map(hex) ?? "none") rssi=\(rssi) decision=\(dialNow ? "DIAL" : "WAIT")")
        if dialNow {
            dial(c, p, advPrefix)
        } else if pendingWaits.insert(p.identifier).inserted {                  // SPEC R4: one wait per peer
            bleQueue.asyncAfter(deadline: .now() + WAIT_BASE_S + Double.random(in: 0...1)) { [weak self] in
                guard let self else { return }
                self.pendingWaits.remove(p.identifier)
                if let pre = advPrefix, self.haveLinkToPrefix(pre) { return }    // SPEC R4: gate on link map
                if self.retained[p.identifier] != nil { return }
                log("STATE", "wait-timeout fired -> dialing id=\(p.identifier.uuidString.prefix(8))")
                self.dial(c, p, advPrefix)
            }
        }
    }

    private func dial(_ c: CBCentralManager, _ p: CBPeripheral, _ advPrefix: Data?) {
        retained[p.identifier] = p
        advPrefixById[p.identifier] = advPrefix
        p.delegate = self
        c.connect(p, options: nil)
        log("STATE", "DIALING id=\(p.identifier.uuidString.prefix(8))")
        let t = DispatchWorkItem { [weak self] in self?.dialTimedOut(p) }       // SPEC R6
        dialTimers[p.identifier] = t
        bleQueue.asyncAfter(deadline: .now() + DIAL_TIMEOUT_S, execute: t)
    }

    private func dialTimedOut(_ p: CBPeripheral) {
        guard retained[p.identifier] != nil else { return }
        log("STATE", "dial-timeout id=\(p.identifier.uuidString.prefix(8))")
        cm.cancelPeripheralConnection(p)                                        // SPEC R6: abort indefinite connect
        reconnect(p)
    }

    private func clearDialTimer(_ p: CBPeripheral) {
        dialTimers[p.identifier]?.cancel(); dialTimers[p.identifier] = nil
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("STATE", "connected id=\(p.identifier.uuidString.prefix(8)), discoverServices(nil)")
        p.discoverServices(nil)                                                 // SPEC: nil, not [SERVICE_UUID]
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("STATE", "didFailToConnect id=\(p.identifier.uuidString.prefix(8)) \(error?.localizedDescription ?? "")")
        reconnect(p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("STATE", "didDisconnect id=\(p.identifier.uuidString.prefix(8)) \(error?.localizedDescription ?? "")")
        reconnect(p)
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidated: [CBService]) {
        log("STATE", "didModifyServices id=\(p.identifier.uuidString.prefix(8)), re-discover (defeat stale cache)")
        p.discoverServices(nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        log("STATE", "services-discovered id=\(p.identifier.uuidString.prefix(8))")
        for s in p.services ?? [] where s.uuid == SERVICE_UUID {
            p.discoverCharacteristics([ENDPOINT_CHAR], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == ENDPOINT_CHAR {
            log("STATE", "char-discovered -> readValue id=\(p.identifier.uuidString.prefix(8))")
            p.readValue(for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value, v.count >= 18 else {
            log("STATE", "read-FAILED id=\(p.identifier.uuidString.prefix(8)) \(error?.localizedDescription ?? "short value")")
            return
        }
        let peerId = v.subdata(in: 2..<18)
        let psm = CBL2CAPPSM(UInt16(v[0]) << 8 | UInt16(v[1]))
        log("STATE", "read psm=\(psm) peer=\(shortHex(peerId)) id=\(p.identifier.uuidString.prefix(8))")
        if haveLinkTo(peerId) {                                                 // SPEC R4: already linked -> no redundant CoC
            log("STATE", "already-linked -> cancel id=\(p.identifier.uuidString.prefix(8))")
            clearDialTimer(p); cm.cancelPeripheralConnection(p); retained[p.identifier] = nil; return
        }
        advPrefixById[p.identifier] = peerId.prefix(6)                          // SPEC R2: promote to stable nodeId prefix
        log("STATE", "openL2CAPChannel psm=\(psm) id=\(p.identifier.uuidString.prefix(8))")
        p.openL2CAPChannel(psm)
    }

    func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if error != nil {
            log("STATE", "l2cap-open-error -> re-read id=\(p.identifier.uuidString.prefix(8)) \(error!.localizedDescription)")
            p.discoverServices(nil)                                            // stale PSM -> re-read (SPEC §7.4)
            return
        }
        guard let channel else { return }
        clearDialTimer(p)                                                      // SPEC R6: dial succeeded
        backoff[advPrefixById[p.identifier].map(hex) ?? p.identifier.uuidString] = nil
        log("STATE", "l2cap-open success (dialer) id=\(p.identifier.uuidString.prefix(8))")
        // SPEC §8.1 iOS adaptation: same as Peripheral.didOpen, construct Link on the
        // I/O thread so streams and timers are bound to the thread owning bleRunLoop.
        let myId = self.myId, onLink = self.onLink, onClose = self.onClose
        let onCloseChain: (Link) -> Void = { [weak self] l in self?.dialerLinkClosed(p, l); onClose(l) }
        bleRunLoop.perform {
            _ = Link(channel: channel, isDialer: true, myId: myId, onUp: onLink, onClose: onCloseChain)
        }
    }

    private func dialerLinkClosed(_ p: CBPeripheral, _ l: Link) {
        let key = advPrefixById[p.identifier].map(hex) ?? p.identifier.uuidString
        if l.stableUp { backoff[key] = nil }                                   // SPEC §6: reset after long-lived link
        if retained[p.identifier] != nil { cm.cancelPeripheralConnection(p) }  // -> didDisconnect -> reconnect
    }

    func reconnect(_ p: CBPeripheral) {
        clearDialTimer(p); retained[p.identifier] = nil
        let key = advPrefixById[p.identifier].map(hex) ?? p.identifier.uuidString
        let base = backoff[key].map { max($0 - nowS(), 0.5) } ?? 0.5
        let next = min(base * 2, 30) + Double.random(in: 0...1)                 // SPEC §6 schedule
        backoff[key] = nowS() + next
        log("STATE", "COOLDOWN id=\(p.identifier.uuidString.prefix(8)) backoff=\(String(format: "%.1f", next))s")
        evictBackoff()                                                         // SPEC R2: TTL bound
    }

    private func evictBackoff() {
        let cut = nowS() - LOST_S
        backoff = backoff.filter { $0.value > cut }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log("STATE", "central willRestoreState peripherals=\(restored.count)")
        for p in restored {
            retained[p.identifier] = p        // re-retain BEFORE anything else (SPEC §3.2.3)
            p.delegate = self                 // the system does NOT keep our delegate wiring
            if p.state == .connected {
                p.discoverServices(nil)       // resume the PSM-read handshake
            } else {
                c.connect(p, options: nil)    // re-arm the no-timeout pending connect (Layer B)
            }
        }
        // scan re-arms in centralManagerDidUpdateState(.poweredOn), which fires next.
    }
}

// MARK: - Node: owns myId, both planes, the dedup map (SPEC §2.3) --------------------------------

final class Node {
    let myId = randomNodeId()                       // SPEC R11: stable for the whole process lifetime
    private var peripheral: Peripheral!
    private var central: Central!
    private var linksByPeerId = [Data: Link]()
    private var status: Timer?

    init() {
        log("STATE", "node-start myId=\(hex(myId)) (greater-nodeId dials)")
        peripheral = Peripheral(myId: myId,
            onLink:     { [weak self] in self?.onUp($0) },
            onClose:    { [weak self] in self?.onClose($0) },
            onPowerOff: { [weak self] in self?.closeAllLinks() })
        central = Central(myId: myId,
            onLink:     { [weak self] in self?.onUp($0) },
            onClose:    { [weak self] in self?.onClose($0) },
            onPowerOff: { [weak self] in self?.closeAllLinks() },
            haveLinkTo:       { [weak self] in self?.linksByPeerId[$0] != nil },
            haveLinkToPrefix: { [weak self] pre in self?.linksByPeerId.keys.contains { $0.prefix(6) == pre } ?? false })

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.printStatus() }
        bleRunLoop.add(t, forMode: .common)
        status = t
    }

    private func printStatus() {
        if linksByPeerId.isEmpty {
            log("STATUS", "links=0")
            return
        }
        let detail = linksByPeerId.values
            .map { "peer=\($0.peerShort)/rx=\($0.rx)/tx=\($0.tx)/rtt=\($0.rttMs)ms/\($0.isDialer ? "dialer" : "acceptor")" }
            .joined(separator: " ")
        log("STATUS", "links=\(linksByPeerId.count) \(detail)")
    }

    private func onUp(_ link: Link) {               // SPEC §2.3 dedup
        guard let peer = link.peerId else { return }
        guard let existing = linksByPeerId[peer], existing !== link else {
            linksByPeerId[peer] = link
            return
        }
        let keepDialed = gt(myId, peer)             // keep MY dialed channel iff I'm the greater id
        let keep = [existing, link].first { $0.isDialer == keepDialed } ?? link
        let drop = (keep === link) ? existing : link
        linksByPeerId[peer] = keep                  // SPEC R3: set survivor BEFORE closing the dropped channel
        drop.close("dedup")
        log("DEDUP", "kept isDialer=\(keep.isDialer) peer=\(shortHex(peer))")
    }

    private func onClose(_ link: Link) {            // SPEC R3: identity-checked removal
        guard let peer = link.peerId else { return }
        if linksByPeerId[peer] === link { linksByPeerId.removeValue(forKey: peer) }
    }

    private func closeAllLinks() {                  // SPEC R11: drop all local links on power-off
        for l in linksByPeerId.values { l.close("power-off") }
    }

    /// Called from the iOS AppDelegate on a CoreLocation region wake.
    func wake(_ reason: String) { central?.wake(reason) }
}

// MARK: - misc ----------------------------------------------------------------------------------

func stateName(_ s: CBManagerState) -> String {
    switch s {
    case .poweredOn: return "poweredOn"
    case .poweredOff: return "poweredOff"
    case .resetting: return "resetting"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unsupported"
    case .unknown: return "unknown"
    @unknown default: return "?"
    }
}
