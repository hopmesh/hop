// BleLabApp.swift: iOS app entry point for HopBleLab (ble-lab/SPEC.md §8.1).
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
import HopContract    // BearerManager + the contract
import HopBearerBle     // BleBearer + the bleQueue/bleRunLoop/bleAppInBackground host hooks
   // shared clean-room consumer: ProofSink (same one blepeer uses)

// MARK: - §8.1 Dedicated I/O thread (owns bleRunLoop) -------------------------------------------

/// Long-lived background thread with its own RunLoop; services L2CAP streams and timers.
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
// All bootstrap lives in the AppDelegate so it runs on EVERY launch type (foreground, a
// CoreLocation region relaunch, and a CoreBluetooth state-restoration relaunch) and so it can
// read launchOptions (the only place iOS delivers them). Re-creating Node() here re-instantiates
// the CBCentralManager with the same RESTORE_ID_CENTRAL, which is what makes iOS hand back the
// restored peripherals to willRestoreState (Layer B).

final class AppDelegate: NSObject, UIApplicationDelegate {
    // Retained for the process lifetime. The manager is the uniform transport façade; the bearer is
    // what the beacon wake pokes; the sink is the proof consumer (kept alive, the manager holds it weakly).
    static var manager: BearerManager?
    static var bearer: BleBearer?
    // Static so the URL hook can tear these down and rebuild them without a relaunch.
    static var sink: ProofSink?
    static var beacon: BeaconWake?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Capture logs before anything else.
        redirectLogsToFile()

        // §8.1: dedicated CB queue + I/O run loop BEFORE the bearer starts (the main queue silently
        // drops CB callbacks on iOS 18+). bleQueue / bleRunLoop are public host hooks in HopBearers.
        bleQueue   = DispatchQueue(label: "hop.ble.cb", qos: .userInitiated, attributes: [])
        bleRunLoop = BLEIOThread.shared.runLoop   // blocks until I/O thread is ready

        let bg  = application.applicationState == .background
        let loc = launchOptions?[.location] != nil
        let cbc = launchOptions?[.bluetoothCentrals] != nil
        log("STATE", "COLD LAUNCH background=\(bg) location=\(loc) bluetoothCentrals=\(cbc)")

        // The dormant gate, checked BEFORE any CB manager is constructed. iOS relaunches this app on
        // BLE events precisely BECAUSE a manager was created with a restore identifier, so returning
        // here is what makes it STAY down rather than merely be closed. Terminating it never worked:
        // it was observed back within seconds every time, which is what made the one-hop-service to
        // two-hop-services transition impossible to stage on hardware. See LabRadio.swift.
        guard LabRadio.isEnabled else {
            log("STATE", "DORMANT radio=off: no CB manager, no beacon. Wake: blelab://radio?enabled=true")
            return true
        }

        AppDelegate.startRadios()
        return true
    }

    /// Bring the bearer up. Split out of the launch path so the URL hook can wake a dormant app
    /// without a relaunch, and idempotent so waking an already-live app is a no-op rather than a
    /// second CBCentralManager on the same restore identifier.
    static func startRadios() {
        guard manager == nil else {
            log("STATE", "radio=on already, ignoring duplicate start")
            return
        }
        // Same bootstrap shape as the macOS CLI (blepeer): manager <- register(bearer); proof consumer
        // wired; start(). start() re-creates the CB managers with the SAME restore IDs (Layer B).
        let manager = BearerManager()
        let bearer = BleBearer(myId: BleBearer.randomNodeId())
        manager.register(bearer)
        let sink = ProofSink()
        sink.bearer = manager
        manager.sink = sink
        manager.start()
        AppDelegate.manager = manager
        AppDelegate.bearer = bearer
        AppDelegate.sink = sink

        let beacon = BeaconWake { reason in bearer.wake(reason) }   // Layer C
        beacon.start()
        AppDelegate.beacon = beacon
        log("STATE", "radio=on: bearer started")
    }

    /// Drop the bearer and release the radio NOW, not at the next launch. The persisted flag is what
    /// keeps it down across the state-restoration relaunch that follows any stray BLE event.
    static func stopRadios() {
        guard let m = manager else {
            log("STATE", "radio=off already, nothing to stop")
            return
        }
        m.stop()
        manager = nil
        bearer = nil
        sink = nil
        beacon = nil
        log("STATE", "radio=off: bearer stopped and released")
    }

    /// `blelab://radio?enabled=true|false`. Persists FIRST so a relaunch triggered by the very BLE
    /// event we are shutting down still comes back in the requested state.
    static func handleRadioURL(_ url: URL) {
        guard let want = LabRadio.parse(url: url) else {
            log("STATE", "HOPAUTO blelab radio: unparsable url \(url), ignored")
            return
        }
        LabRadio.isEnabled = want
        if want { startRadios() } else { stopRadios() }
        log("STATE", "HOPAUTO blelab radio=\(want ? "on" : "off") persisted=\(LabRadio.isEnabled)")
    }
}

@main
struct BleLabApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                // The dormant switch: blelab://radio?enabled=true|false. This app is the coexistence
                // fixture for the multi-app BLE defect, so it must be parkable on demand rather than
                // uninstalled, which would hide the defect instead of fixing it.
                .onOpenURL { url in AppDelegate.handleRadioURL(url) }
        }
        .onChange(of: scenePhase) { phase in
            // SPEC R7: widen the liveness deadline when iOS sends the app to background.
            bleAppInBackground = (phase == .background)
        }
    }
}
