import SwiftUI
import BackgroundTasks

@main
struct HopDemoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Periodic background wake to tick the node (retransmit, prune, re-advertise,
        // drain) — best-effort, scheduled by the OS. See DESIGN.md §22.
        .backgroundTask(.appRefresh(HopBearer.refreshTaskId)) {
            await MainActor.run { HopBearer.shared.backgroundTick() }
            HopDemoApp.scheduleRefresh()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { HopDemoApp.scheduleRefresh() }
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: HopBearer.refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
