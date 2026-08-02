// LabRadio.swift: the dormant switch that makes HopBleLab a controllable coexistence fixture.
//
// Why this exists. HopBleLab is the ONLY thing in the fleet that reproduces the multi-app BLE
// defect: two hop-embedded apps on one iOS device publish the same service UUID
// (7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F) with different L2CAP PSMs, and a remote central reads
// whichever the GATT stack returns and dials the wrong one. Measured on hardware: HopDemo on
// psm=192, HopBleLab on psm=193, an Android read 193 while trying to reach HopDemo, and the
// channel died. Deleting this app would hide that defect rather than fix it, so it stays.
//
// But it could not be turned OFF either. CoreBluetooth state restoration relaunches an app with a
// restore ID whenever a BLE event arrives, so terminating it is futile: it was observed back within
// seconds, every time. That made the experiment that matters impossible to run, because you cannot
// create the "device publishes ONE hop service, then a SECOND appears" transition if the second app
// is always already there.
//
// So the switch is checked BEFORE any CBCentralManager or CBPeripheralManager is constructed. That
// is the load-bearing detail: iOS re-launches for BLE events because a manager was created with a
// restore identifier. Never create one and the relaunches stop, which is what makes the app stay
// down rather than merely be closed.
//
// The state is persisted, because the whole point is to survive the relaunch that defeated every
// other approach.

import Foundation

/// Whether HopBleLab should participate in BLE at all. Persisted, and read on every launch type
/// including a CoreBluetooth state-restoration relaunch.
enum LabRadio {
    private static let key = "sh.hopme.blelab.radioEnabled"

    /// Defaults to ON, so an existing install behaves exactly as it did before this switch existed.
    /// A fixture that quietly went dormant on upgrade would be worse than no fixture.
    static var isEnabled: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: key) == nil { return true }
            return d.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Parse `blelab://radio?enabled=true|false` into the requested state.
    ///
    /// `enabled` is parsed STRICTLY: only the exact strings "true" and "false". A permissive parse
    /// would read a typo as `false`, the fixture would silently go dormant, and a coexistence test
    /// would then "prove" a scenario it never actually set up. That failure mode has already been
    /// paid for once on the hop side of this automation, so it is closed here by construction.
    static func parse(url: URL) -> Bool? {
        guard url.scheme == "blelab", url.host == "radio" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "enabled" })?.value else { return nil }
        switch raw {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
