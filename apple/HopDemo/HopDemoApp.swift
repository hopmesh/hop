import SwiftUI
import BackgroundTasks
import UIKit
import HopDriver

extension HopBearer {
    /// The app's single shared Hop runtime — the dev `Config` (messages db in the document dir, the
    /// dev app secret "H"×32, the anycast cloud relay, full role). One instance shared by the app's
    /// background tasks and `ContentView`, so there's exactly one `HopNode` open on the db.
    static let shared: HopBearer = {
        let db = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hop.db").path
        return HopBearer(config: .init(
            dbPath: db,
            deviceSeed: IdentityStore.deviceSeed(),
            appSecret: HopBearer.appSecret,
            displayName: HopBearer.savedName(default: UIDevice.current.name),
            defaultRelay: nil,   // P2P-ONLY test mode: no backbone relay (BLE/LAN only). Was HopBearer.defaultRelay.
            role: .full))
    }()
}

@main
struct HopDemoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // BGProcessingTask gets a longer window (runs when idle, best-effort on battery /
        // reliably when charging) — used to *drain a backlog* like a large image that
        // accumulates across short wakes. Registered here (must be before launch finishes);
        // the appRefresh handler below is registered by the SwiftUI .backgroundTask modifier.
        HopDemoApp.registerProcessing()
        // TEST/AUTOMATION: cold-launch send driven by the HOP_AUTO launch env var (hands-off
        // harness testing on dev-owned devices, no UI tapping). See runAutomationEnv.
        HopDemoApp.runAutomationEnv()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // TEST/AUTOMATION: drive a send from `hopdemo://send?to=<base58>&text=<marker>`.
                .onOpenURL { url in HopDemoApp.handleAutomationURL(url) }
        }
        // Short, frequent-ish OS wake to tick + reconnect the relay + drain (best-effort,
        // OS-scheduled; more often for actively-used apps). See DESIGN.md §22/§28.
        .backgroundTask(.appRefresh(HopBearer.refreshTaskId)) {
            await MainActor.run { HopBearer.shared.backgroundTick() }
            HopDemoApp.scheduleRefresh()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                HopDemoApp.scheduleRefresh()
                HopDemoApp.scheduleProcessing()
            }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: HopBearer.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: HopBearer.processTaskId)
        request.requiresNetworkConnectivity = true // it pulls from the relay over the network
        request.requiresExternalPower = false      // allow on battery when idle (best-effort)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Register the processing handler: reconnect + pump in a loop for the window iOS grants,
    /// so a backlog (e.g. a large image) drains across the longer window. Re-arms the next one.
    static func registerProcessing() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: HopBearer.processTaskId, using: nil
        ) { task in
            HopDemoApp.scheduleProcessing() // chain the next occurrence
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let state = CompletionGuard(task)
            task.expirationHandler = { state.finish(false) } // iOS reclaiming the window
            // Drain on the main actor: reconnect-the-relay + pump every 2s, up to ~50s.
            var ticks = 0
            func loop() {
                DispatchQueue.main.async {
                    HopBearer.shared.backgroundTick()
                    ticks += 1
                    if ticks >= 25 {
                        state.finish(true)
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { loop() }
                }
            }
            loop()
        }
    }

    // MARK: - Automation control surface (TEST/AUTOMATION — headless harness, no UI tapping)

    /// Handle `hopdemo://send?to=<base58addr>&text=<marker>`: parse the address + marker text and
    /// drive a send through the bearer's `sendTo` automation hook. Authorized internal testing only.
    static func handleAutomationURL(_ url: URL) {
        guard url.scheme == "hopdemo", url.host == "send",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = comps.queryItems ?? []
        guard let to = items.first(where: { $0.name == "to" })?.value,
              let text = items.first(where: { $0.name == "text" })?.value else { return }
        HopBearer.shared.sendTo(addressBase58: to, text: text)
    }

    /// Cold-launch send driven by `HOP_AUTO=send|<base58addr>|<marker text>` (set via
    /// `xcrun devicectl ... --environment-variables`). The marker text may contain spaces (only the
    /// first two `|` are structural). Fires ~3s after launch so BLE links can form first.
    static func runAutomationEnv() {
        guard let spec = ProcessInfo.processInfo.environment["HOP_AUTO"] else { return }
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 3, parts[0] == "send" else { return }
        let to = parts[1]
        let text = parts[2...].joined(separator: "|")   // rejoin any stray pipes into the marker text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            HopBearer.shared.sendTo(addressBase58: to, text: text)
        }
    }
}

/// Ensures `setTaskCompleted` is called exactly once (the drain loop finishing or iOS's
/// expiration handler, whichever comes first).
private final class CompletionGuard {
    private let task: BGTask
    private let lock = NSLock()
    private var done = false
    init(_ task: BGTask) { self.task = task }
    func finish(_ ok: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        task.setTaskCompleted(success: ok)
    }
}
