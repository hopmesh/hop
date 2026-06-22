import SwiftUI
import BackgroundTasks

@main
struct HopDemoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // BGProcessingTask gets a longer window (runs when idle, best-effort on battery /
        // reliably when charging) — used to *drain a backlog* like a large image that
        // accumulates across short wakes. Registered here (must be before launch finishes);
        // the appRefresh handler below is registered by the SwiftUI .backgroundTask modifier.
        HopDemoApp.registerProcessing()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
