// Central-ONLY diagnostic: NO CBPeripheralManager at all. Scan → connect → discoverServices(nil)
// → discover char → read [PSM|id] → openL2CAPChannel → send HELLO+PING, print bytes.
// Tests the hypothesis that a concurrent CBPeripheralManager (dual role) is what wedges GATT
// service discovery on macOS. If THIS completes discovery + L2CAP, the dual-role coexistence is the bug.
import Foundation
import CoreBluetooth

let SERVICE_UUID  = CBUUID(string: "7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F")
let ENDPOINT_CHAR = CBUUID(string: "7ED70002-3C2A-4F19-9B8E-1A2B3C4D5E6F")
func ts() -> String { String(format: "%8.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100000)) }
func log(_ s: String) { print("DIAL \(ts()) \(s)") }

final class C: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, StreamDelegate {
    var cm: CBCentralManager!
    var target: CBPeripheral?
    var input: InputStream?, output: OutputStream?
    var inBuf = [UInt8](), outBuf = [UInt8]()
    var rxSeq: UInt64 = 0
    override init() { super.init(); cm = CBCentralManager(delegate: self, queue: .main) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else { log("state=\(c.state.rawValue)"); return }
        log("scan-started (central-only, NO peripheral manager)")
        c.scanForPeripherals(withServices: [SERVICE_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi: NSNumber) {
        guard target == nil else { return }
        target = p; p.delegate = self
        log("discovered \(p.identifier) rssi=\(rssi), connecting")
        c.stopScan()
        c.connect(p, options: nil)
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("connected, discoverServices(nil)")
        p.discoverServices(nil)
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { log("connect FAILED \(error?.localizedDescription ?? "?")") }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("disconnected \(error?.localizedDescription ?? "clean"), rescanning")
        target = nil; input = nil; output = nil; inBuf = []; outBuf = []; rxSeq = 0
        c.scanForPeripherals(withServices: [SERVICE_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        log("✅ didDiscoverServices err=\(error?.localizedDescription ?? "nil") services=\((p.services ?? []).map{$0.uuid.uuidString})")
        for s in p.services ?? [] where s.uuid == SERVICE_UUID { p.discoverCharacteristics([ENDPOINT_CHAR], for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        log("✅ didDiscoverChars err=\(error?.localizedDescription ?? "nil") chars=\((s.characteristics ?? []).map{$0.uuid.uuidString})")
        for ch in s.characteristics ?? [] where ch.uuid == ENDPOINT_CHAR { p.readValue(for: ch) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value, v.count >= 18 else { log("read short/err \(error?.localizedDescription ?? "?")"); return }
        let psm = CBL2CAPPSM(UInt16(v[0]) << 8 | UInt16(v[1]))
        log("✅ read PSM=\(psm) peerId=\(v.subdata(in: 2..<18).map{String(format:"%02x",$0)}.joined().prefix(8)), openL2CAPChannel")
        p.openL2CAPChannel(psm)
    }
    func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error { log("❌ openL2CAP FAILED \(error.localizedDescription)"); return }
        guard let channel else { return }
        log("✅✅ L2CAP OPEN, wiring streams, sending HELLO")
        input = channel.inputStream; output = channel.outputStream
        for s in [input!, output!] { s.delegate = self; s.schedule(in: .main, forMode: .common); s.open() }
        var hello = Data([0x01]); hello.append(Data(repeating: 0xAB, count: 16)); hello.append(1); hello.append(0)
        sendFrame(hello)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            var b = Data([0x02]); var be = UInt64(99).bigEndian; withUnsafeBytes(of:&be){b.append(contentsOf:$0)}; be = 0; withUnsafeBytes(of:&be){b.append(contentsOf:$0)}; self?.sendFrame(b)
        }
    }
    func sendFrame(_ body: Data) {
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { outBuf.append(contentsOf: $0) }; outBuf.append(contentsOf: body); drain()
    }
    func drain() { while !outBuf.isEmpty, let o = output, o.hasSpaceAvailable { let n = o.write(outBuf, maxLength: outBuf.count); if n>0 { outBuf.removeFirst(n) } else { break } } }
    func stream(_ s: Stream, handle e: Stream.Event) {
        switch e {
        case .hasBytesAvailable:
            guard let inp = input else { return }
            var tmp = [UInt8](repeating: 0, count: 4096)
            while inp.hasBytesAvailable { let n = inp.read(&tmp, maxLength: tmp.count); if n>0 { inBuf.append(contentsOf: tmp[0..<n]) } else { break } }
            deframe()
        case .hasSpaceAvailable: drain()
        case .endEncountered, .errorOccurred: log("stream end/error")
        default: break
        }
    }
    func deframe() {
        while inBuf.count >= 4 {
            let len = Int(UInt32(inBuf[0])<<24 | UInt32(inBuf[1])<<16 | UInt32(inBuf[2])<<8 | UInt32(inBuf[3]))
            guard inBuf.count >= 4+len else { break }
            let body = Array(inBuf[4..<4+len]); inBuf.removeFirst(4+len)
            if body.first == 0x02 { log("📥 RX peer PING (bytes flowing both ways!), PROOF") }
            else if body.first == 0x01 { log("📥 RX peer HELLO") }
        }
    }
}
setbuf(stdout, nil)
let c = C()
RunLoop.main.run()
