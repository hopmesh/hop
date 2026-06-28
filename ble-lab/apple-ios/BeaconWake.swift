// BeaconWake.swift — iOS-only CoreLocation iBeacon region monitor (Layer C, the
// force-quit-proof relaunch). On region enter it pokes the BLE Node to (re)scan/connect.
import Foundation
import CoreLocation
import UIKit
import HopBearers   // log() now lives in the shared transport package

// Must byte-match the Android iBeacon proximity UUID (Ble.kt BEACON_UUID).
let BEACON_UUID = UUID(uuidString: "7ED7BEAC-3C2A-4F19-9B8E-1A2B3C4D5E6F")!
let BEACON_REGION_ID = "hoplab.beacon"

final class BeaconWake: NSObject, CLLocationManagerDelegate {
    private let lm = CLLocationManager()
    private let region: CLBeaconRegion
    private let onWake: (String) -> Void
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    init(onWake: @escaping (String) -> Void) {
        self.onWake = onWake
        self.region = CLBeaconRegion(uuid: BEACON_UUID, identifier: BEACON_REGION_ID)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        region.notifyEntryStateOnDisplay = true   // re-evaluate when the screen turns on
        super.init()
        lm.delegate = self
        lm.allowsBackgroundLocationUpdates = false // monitoring/ranging don't require true
    }

    /// Call from didFinishLaunchingWithOptions. Safe on cold background launch.
    func start() {
        switch lm.authorizationStatus {
        case .notDetermined:    lm.requestWhenInUseAuthorization()       // escalates to Always below
        case .authorizedWhenInUse: lm.requestAlwaysAuthorization()
        case .authorizedAlways: beginMonitoring()
        default: log("STATE", "location auth=\(lm.authorizationStatus.rawValue) — NO terminated wake")
        }
    }

    private func beginMonitoring() {
        lm.startMonitoring(for: region)
        lm.requestState(for: region)              // get initial inside/outside even if no boundary crossing
        log("STATE", "beacon monitoring started uuid=\(BEACON_UUID.uuidString)")
    }

    // MARK: CLLocationManagerDelegate
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse: m.requestAlwaysAuthorization()
        case .authorizedAlways:    beginMonitoring()
        default: log("STATE", "location auth changed=\(m.authorizationStatus.rawValue)")
        }
    }
    func locationManager(_ m: CLLocationManager, didEnterRegion r: CLRegion)  { wake("region-enter") }
    func locationManager(_ m: CLLocationManager, didDetermineState s: CLRegionState, for r: CLRegion) {
        if s == .inside { wake("region-inside") }
    }
    func locationManager(_ m: CLLocationManager, didExitRegion r: CLRegion)   { log("STATE", "region-exit") }
    func locationManager(_ m: CLLocationManager, monitoringDidFailFor r: CLRegion?, withError e: Error) {
        log("STATE", "monitoring-failed \(e.localizedDescription)")
    }

    /// Buy up to ~30 s beyond the ~10 s region window so scan→connect→L2CAP can finish.
    private func wake(_ reason: String) {
        log("STATE", "BEACON WAKE (\(reason))")
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "hop.beacon.wake") { [weak self] in
                guard let self else { return }
                UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid
            }
        }
        lm.startRangingBeacons(satisfying: CLBeaconIdentityConstraint(uuid: BEACON_UUID)) // keeps us scanning while in range
        onWake(reason)
    }
}
