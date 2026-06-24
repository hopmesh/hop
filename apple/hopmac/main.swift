// HopMac — a headless macOS Hop node with a BLE-central bearer, for testing cross-platform BLE.
//
// It runs the REAL hop-core (via hop-ffi) and connects to Android Hop peripherals over an L2CAP
// channel exactly like the iOS app's central path: scan for the Hop service, read the PSM from the
// advert, open L2CAP, frame packets, and drive node.connected/received/drainOutgoing. Once the Noise
// handshake completes (the peer shows secured), it sends a test message and prints anything received.
//
// This lets us verify cross-platform BLE end-to-end from a controllable Mac instead of debugging iPhones.
import Foundation
import CoreBluetooth

let HOP_SVC = CBUUID(string: "F0900000-0000-4000-8000-000000000000")
let PSM_CHAR = CBUUID(string: "F0900001-0000-4000-8000-000000000000")
let APP_SECRET = Data(repeating: 0x48, count: 32)   // matches HopDemo dev build ("H"×32)

func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
func hex(_ d: Data) -> String { d.prefix(6).map { String(format: "%02x", $0) }.joined() }
func log(_ s: String) { print("[\(String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100000)))] \(s)") }

/// One L2CAP link, 4-byte big-endian length framing (matches HopLink on iOS/Android).
final class L2Link: NSObject, StreamDelegate {
    let id: UInt64
    private let channel: CBL2CAPChannel
    private let input: InputStream, output: OutputStream
    private let onBytes: (UInt64, Data) -> Void
    private let onClose: (UInt64) -> Void
    private var inBuf = [UInt8](), outBuf = [UInt8]()
    private var lastRead = Date(); private var ka: Timer?; private var wd: Timer?; private var closed = false

    init(id: UInt64, channel: CBL2CAPChannel, onBytes: @escaping (UInt64, Data) -> Void, onClose: @escaping (UInt64) -> Void) {
        self.id = id; self.channel = channel
        self.input = channel.inputStream; self.output = channel.outputStream
        self.onBytes = onBytes; self.onClose = onClose
        super.init()
        for s in [input, output] { s.delegate = self; s.schedule(in: .main, forMode: .common); s.open() }
        ka = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.send(Data()) }
        wd = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastRead) > 15 { self.close() }
        }
    }
    func send(_ bytes: Data) {
        guard !closed else { return }
        var len = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &len) { outBuf.append(contentsOf: $0) }; outBuf.append(contentsOf: bytes); drain()
    }
    func close() {
        guard !closed else { return }; closed = true
        ka?.invalidate(); wd?.invalidate()
        for s in [input, output] { s.close(); s.remove(from: .main, forMode: .common) }
        onClose(id)
    }
    func stream(_ s: Stream, handle e: Stream.Event) {
        switch e {
        case .hasBytesAvailable: read()
        case .hasSpaceAvailable: drain()
        case .endEncountered, .errorOccurred: close()
        default: break
        }
    }
    private func drain() { while !outBuf.isEmpty && output.hasSpaceAvailable { let n = output.write(outBuf, maxLength: outBuf.count); if n > 0 { outBuf.removeFirst(n) } else { break } } }
    private func read() {
        var tmp = [UInt8](repeating: 0, count: 8192)
        while input.hasBytesAvailable { let n = input.read(&tmp, maxLength: tmp.count); if n > 0 { inBuf.append(contentsOf: tmp[0..<n]) } else { break } }
        lastRead = Date(); deframe()
    }
    private func deframe() {
        while inBuf.count >= 4 {
            let len = UInt32(inBuf[0]) << 24 | UInt32(inBuf[1]) << 16 | UInt32(inBuf[2]) << 8 | UInt32(inBuf[3])
            let total = 4 + Int(len); guard inBuf.count >= total else { break }
            if len > 0 { onBytes(id, Data(inBuf[4..<total])) }
            inBuf.removeFirst(total)
        }
    }
}

final class HopMac: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let node: HopNode
    var central: CBCentralManager!
    var links = [UInt64: L2Link]()
    var nextLinkId: UInt64 = 1
    var retained = [UUID: CBPeripheral]()
    var connecting = Set<UUID>()
    var psmByPeer = [UUID: CBL2CAPPSM]()
    var opened = Set<UUID>()
    var sentTo = Set<[UInt8]>()
    var ticks = 0

    override init() {
        let db = NSTemporaryDirectory() + "hopmac-\(UUID().uuidString).db"
        let seed = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        node = HopNode.open(dbPath: db, secret: seed, appSecret: APP_SECRET)
        super.init()
        node.setName(name: "MacHopTest")
        node.tick(nowMs: nowMs())
        log("our address: \(hex(node.address())) (MacHopTest)")
        node.subscribe(topic: "presence")
        _ = try? node.publishPrekey()
        publishPresence()
        central = CBCentralManager(delegate: self, queue: .main)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func publishPresence() {
        _ = try? node.publishService(service: "presence", title: "MacHopTest", summary: "fg|mac|HopMacTest", tags: [], ttlMs: 600_000)
    }

    func tick() {
        node.tick(nowMs: nowMs()); ticks += 1
        if ticks % 20 == 0 { publishPresence() }
        if ticks % 120 == 0 { _ = try? node.publishPrekey() }
        pump()
        if ticks % 5 == 0 {
            let pls = node.peerLinks()
            log("status: \(links.count) L2CAP link(s); peerLinks=\(pls.count): " +
                pls.map { "\(hex($0.address))@\($0.link)\(node.isSecured(address: $0.address) ? "🔒" : "")" }.joined(separator: ", "))
        }
    }

    func pump() {
        for pkt in node.drainOutgoing() { links[pkt.link]?.send(pkt.bytes) }
        // Message each linked peer once. We don't gate on isSecured: sendMessage defers content until
        // a forward-secret session is ready (require-ratchet), so this exercises the full path —
        // Noise link → prekey exchange → ratchet → delivery.
        for pl in node.peerLinks() where pl.link != 0 {
            if !sentTo.contains([UInt8](pl.address)) {
                sentTo.insert([UInt8](pl.address))
                let body = "hello from MacHopTest over BLE".data(using: .utf8)!
                if let id = try? node.sendMessage(dst: pl.address, contentType: "text/plain", body: body, requestAck: true) {
                    log("➡️  peer \(hex(pl.address)) linked @\(pl.link) secured=\(node.isSecured(address: pl.address)) — sent msg id=\(hex(id))")
                }
            }
        }
        for m in node.takeInbox() {
            let txt = String(data: m.body, encoding: .utf8) ?? "<\(m.body.count) bytes>"
            log("📥 RX from \(hex(m.from)) [\(m.contentType)] hops=\(m.hops): \(txt)")
        }
    }

    // MARK: central
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { log("BT state \(c.state.rawValue) — need Bluetooth ON + Terminal BT permission"); return }
        log("scanning for Hop service \(HOP_SVC.uuidString)…")
        c.scanForPeripherals(withServices: [HOP_SVC], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi: NSNumber) {
        // Only OUR manufacturer data (company 0xFFFF, little-endian ff ff) carries the PSM. iPhones
        // add Apple mfg data (company 0x004c) which must NOT be parsed as a PSM — those read via GATT.
        if let mfg = d[CBAdvertisementDataManufacturerDataKey] as? Data {
            let b = [UInt8](mfg)
            if b.count >= 4, b[0] == 0xFF, b[1] == 0xFF {
                let psm = CBL2CAPPSM(UInt16(b[2]) << 8 | UInt16(b[3])); if psm != 0 { psmByPeer[p.identifier] = psm }
            }
        }
        guard !connecting.contains(p.identifier) else { return }
        // ANDROID-ONLY test mode: only dial peers advertising our 0xFFFF mfg PSM (Android). iPhones
        // (Apple mfg / no PSM) are skipped so the radio isn't juggling many connections at once,
        // isolating the Mac↔Android L2CAP path. Set HOPMAC_ALL=1 to dial everything.
        let androidOnly = ProcessInfo.processInfo.environment["HOPMAC_ALL"] == nil
        if androidOnly && psmByPeer[p.identifier] == nil { return }
        connecting.insert(p.identifier); retained[p.identifier] = p; p.delegate = self
        let nm = (d[CBAdvertisementDataLocalNameKey] as? String) ?? "‹none›"
        log("found \(p.identifier) name=\(nm) rssi=\(rssi) psm=\(psmByPeer[p.identifier].map(String.init) ?? "?") — connecting")
        c.connect(p)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        if let psm = psmByPeer[p.identifier], !opened.contains(p.identifier) {
            opened.insert(p.identifier); log("connected — opening L2CAP psm=\(psm)"); p.openL2CAPChannel(psm)
        } else { log("connected — reading PSM via GATT"); p.discoverServices([HOP_SVC]) }
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("connect failed: \(error?.localizedDescription ?? "?")"); reconnect(p)
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        opened.remove(p.identifier); log("disconnected \(p.identifier): \(error?.localizedDescription ?? "clean")"); reconnect(p)
    }
    func reconnect(_ p: CBPeripheral) {
        connecting.remove(p.identifier)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let pp = self.retained[p.identifier] else { return }
            self.connecting.insert(pp.identifier); self.central.connect(pp)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == HOP_SVC { p.discoverCharacteristics([PSM_CHAR], for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == PSM_CHAR { p.readValue(for: ch) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value, v.count >= 2 else { return }
        let psm = CBL2CAPPSM(UInt16(v[0]) << 8 | UInt16(v[1])); psmByPeer[p.identifier] = psm
        if !opened.contains(p.identifier) { opened.insert(p.identifier); log("read PSM=\(psm) — opening L2CAP"); p.openL2CAPChannel(psm) }
    }
    func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error {
            log("openL2CAP failed: \(error.localizedDescription) — falling back to GATT PSM read")
            opened.remove(p.identifier); psmByPeer[p.identifier] = nil
            p.discoverServices([HOP_SVC]); return
        }
        guard let channel else { return }
        let id = nextLinkId; nextLinkId += 1
        log("✅ L2CAP open — link \(id) up to \(p.identifier); driving Noise…")
        let link = L2Link(id: id, channel: channel,
            onBytes: { [weak self] lid, data in self?.node.received(link: lid, bytes: data); self?.pump() },
            onClose: { [weak self] lid in self?.links[lid] = nil; self?.node.disconnected(link: lid) })
        links[id] = link
        node.connected(link: id, initiator: true)   // we dialed → Noise initiator
        pump()
    }
}

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered so logs flush immediately (even under `timeout`)
let app = HopMac()
log("HopMac started — Ctrl-C to quit")
RunLoop.main.run()
