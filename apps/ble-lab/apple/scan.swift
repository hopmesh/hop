// Standalone macOS BLE scanner — diagnostic only. No advertising, no dual role.
// Scans UNFILTERED and prints any device advertising our lab service UUID or our 0xFFFF mfg id,
// with full advert contents. Isolates "can macOS discover the Android peer?" from everything else.
import Foundation
import CoreBluetooth

let SVC = "7ED70001"
final class S: NSObject, CBCentralManagerDelegate {
    var cm: CBCentralManager!
    var seen = Set<UUID>()
    var allSeen = Set<UUID>()
    override init() {
        super.init(); cm = CBCentralManager(delegate: self, queue: .main)
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            print("… total unique BLE devices seen so far = \(self?.allSeen.count ?? 0)")
        }
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            print("SCAN starting (unfiltered, allowDuplicates)")
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        default:
            print("STATE rawValue=\(c.state.rawValue) (need poweredOn=5 + Bluetooth TCC)")
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi: NSNumber) {
        let uuids = (d[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        let overflow = (d[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        let name = (d[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let mfg = (d[CBAdvertisementDataManufacturerDataKey] as? Data)?.map { String(format: "%02x", $0) }.joined() ?? ""
        allSeen.insert(p.identifier)
        let matchSvc = uuids.contains { $0.uppercased().contains(SVC) } || overflow.contains { $0.uppercased().contains(SVC) }
        let matchMfg = mfg.hasPrefix("ffff")
        guard matchSvc || matchMfg else { return }
        let key = p.identifier
        let first = seen.insert(key).inserted
        if first {
            print("FOUND id=\(p.identifier) rssi=\(rssi) name=\"\(name)\" connectable=\((d[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false)")
            print("   svcUUIDs=\(uuids) overflow=\(overflow) mfg=\(mfg)")
        }
    }
}
setbuf(stdout, nil)
let s = S()
RunLoop.main.run()
