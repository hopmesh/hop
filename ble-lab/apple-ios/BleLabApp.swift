// BleLabApp.swift — iOS app entry point for HopBleLab (ble-lab/SPEC.md §8.1).
//
// SPEC §8.1 threading adaptation:
//   bleQueue   = dedicated serial DispatchQueue (CB delegate callbacks off the UI main thread)
//   bleRunLoop = dedicated I/O thread's RunLoop (L2CAP streams + PING/watchdog timers)
//
// HopBleLab.swift's two didOpen handlers now wrap Link(...) in bleRunLoop.perform{} so that
// Stream.schedule(in:bleRunLoop) and the Timer additions run on the thread that owns the
// run loop (required for reliable event delivery). This is the §8.1 fix described in SPEC.
//
// Note: bleQueue = DispatchQueue.main did NOT fire CB state callbacks on iOS 18 in testing
// (both peripheralManagerDidUpdateState and centralManagerDidUpdateState were silently
// skipped). The dedicated-queue approach correctly triggers callbacks.
//
// stdout + stderr are redirected to Documents/blelab.log BEFORE Node() is created.

import SwiftUI
import CoreBluetooth
import UIKit

// MARK: - §8.1 Dedicated I/O thread (owns bleRunLoop) -------------------------------------------

/// Long-lived background thread with its own RunLoop — services L2CAP streams and timers.
/// Kept alive by a Port source. Thread-safe singleton.
final class BLEIOThread {
    static let shared = BLEIOThread()
    private(set) var runLoop: RunLoop!
    private let ready = DispatchSemaphore(value: 0)

    private init() {
        let t = Thread { [weak self] in
            guard let self else { return }
            self.runLoop = RunLoop.current
            self.ready.signal()
            RunLoop.current.add(Port(), forMode: .common)   // keep alive
            RunLoop.current.run()
        }
        t.name = "hop.ble.io"
        t.start()
        ready.wait()
    }
}

// MARK: - Stdout/stderr capture -------------------------------------------------------------------

private func redirectLogsToFile() {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let logPath = docs.appendingPathComponent("blelab.log").path
    freopen(logPath, "w", stdout)
    freopen(logPath, "a", stderr)
    setbuf(stdout, nil)
}

// MARK: - App lifecycle ---------------------------------------------------------------------------
//
// All bootstrap lives in the AppDelegate so it runs on EVERY launch type — foreground, a
// CoreLocation region relaunch, and a CoreBluetooth state-restoration relaunch — and so it can
// read launchOptions (the only place iOS delivers them). Re-creating Node() here re-instantiates
// the CBCentralManager with the same RESTORE_ID_CENTRAL, which is what makes iOS hand back the
// restored peripherals to willRestoreState (Layer B).

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var node: Node?
    private var beacon: BeaconWake?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Capture logs before anything else.
        redirectLogsToFile()

        // §8.1: dedicated CB queue + I/O run loop BEFORE Node() (main queue silently drops CB
        // callbacks on iOS 18+). bleQueue / bleRunLoop are mutable globals declared in HopBleLab.swift.
        bleQueue   = DispatchQueue(label: "hop.ble.cb", qos: .userInitiated, attributes: [])
        bleRunLoop = BLEIOThread.shared.runLoop   // blocks until I/O thread is ready

        let bg  = application.applicationState == .background
        let loc = launchOptions?[.location] != nil
        let cbc = launchOptions?[.bluetoothCentrals] != nil
        log("STATE", "COLD LAUNCH background=\(bg) location=\(loc) bluetoothCentrals=\(cbc)")

        let node = Node()                       // re-creates CB managers with the SAME restore IDs (Layer B)
        AppDelegate.node = node
        beacon = BeaconWake { reason in node.wake(reason) }   // Layer C
        beacon?.start()
        return true
    }
}

@main
struct BleLabApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { phase in
            // SPEC R7: widen the liveness deadline when iOS sends the app to background.
            bleAppInBackground = (phase == .background)
        }
    }
}
