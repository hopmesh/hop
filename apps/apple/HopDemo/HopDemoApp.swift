import SwiftUI
import BackgroundTasks
import UIKit
import HopDriver
import HopDemoKit

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
            defaultRelay: HopBearer.defaultRelay,   // cloud relay re-enabled (wss://relay.hopme.sh)
            role: .full))
    }()
}

/// Boots the Hop runtime on EVERY launch type — most importantly a cold BACKGROUND / force-quit
/// relaunch triggered by a CoreLocation iBeacon region event, where there is no window and thus
/// `ContentView.onAppear` never runs (BACKGROUND.md §3.4 Layer C). `application(_:didFinishLaunching…)`
/// is the one entry point guaranteed to run first on all launch types and to carry `launchOptions`.
/// `HopBearer.start(name:)` is idempotent, so the UI's later `onAppear` is harmless.
final class HopAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        installCrashLogger()  // D-crash: local uncaught-exception log (launch-gate diagnostics)
        let bg = application.applicationState == .background
        let loc = launchOptions?[.location] != nil
        NSLog("HOPLOG COLD LAUNCH background=\(bg) location=\(loc)")
        // Construct + start the shared runtime now → CoreLocation re-arms region monitoring and the
        // BLE bearer (state restoration + the wake bridge) reconnects even with no UI on screen.
        HopBearer.shared.start(name: HopBearer.savedName(default: UIDevice.current.name))
        return true
    }

    /// D-crash: write uncaught Obj-C/NSException crashes (name, reason, call stack) to a file in the
    /// Documents dir so a `devicectl` pull surfaces the last crash — the pre-distribution stand-in for
    /// crash reporting. (Swift `fatalError`/signals need a signal handler + MetricKit; that's the
    /// launch-gate follow-on. This catches the common NSException class.)
    private func installCrashLogger() {
        NSSetUncaughtExceptionHandler { exc in
            let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("hop-crash.log")
            let text = "UNCAUGHT \(exc.name.rawValue): \(exc.reason ?? "")\n"
                + exc.callStackSymbols.joined(separator: "\n") + "\n"
            try? text.data(using: .utf8)?.write(to: path)
            NSLog("HOPLOG CRASH \(exc.name.rawValue): \(exc.reason ?? "")")
        }
    }
}

@main
struct HopDemoApp: App {
    @UIApplicationDelegateAdaptor(HopAppDelegate.self) var appDelegate
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
                // apple-r3-01: force any debounced UI-history mirror write to disk NOW, before iOS can
                // suspend/kill us in the ≤1s save-debounce window, so a message drained from the node
                // inbox on a background wake can't vanish from chat history on relaunch.
                HopBearer.shared.flushPendingSaves()
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
    ///
    /// apple-05: this is a silent send-as-user primitive. In a RELEASE build any co-installed app could
    /// open the URL and cause our identity to message an arbitrary address (spam / deanonymization canary)
    /// with zero user consent. So the handler compiles to a no-op outside DEBUG; the harness (which runs
    /// DEBUG builds) keeps its automation, and shipped builds ignore the scheme entirely.
    static func handleAutomationURL(_ url: URL) {
        #if DEBUG
        // The scheme/host/query parsing lives in HopDemoKit (unit-tested); the send stays here.
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = (comps?.queryItems ?? []).map { (name: $0.name, value: $0.value) }
        guard let parsed = DemoFormat.parseAutomationURL(scheme: url.scheme, host: url.host,
                                                         queryItems: items) else { return }
        HopBearer.shared.sendTo(addressBase58: parsed.to, text: parsed.text)
        #else
        _ = url   // release: ignore the automation scheme (apple-05)
        #endif
    }

    /// Cold-launch send driven by `HOP_AUTO=send|<base58addr>|<marker text>` (set via
    /// `xcrun devicectl ... --environment-variables`). The marker text may contain spaces (only the
    /// first two `|` are structural). Fires ~3s after launch so BLE links can form first.
    static func runAutomationEnv() {
        let spec = ProcessInfo.processInfo.environment["HOP_AUTO"] ?? ""
        HopBearer.autoEnvSeen = spec   // breadcrumb: prove the env reached the app even if the send is a no-op
        // apple-r3-02: HOP_AUTO=send|addr|text is a silent send-as-user primitive, the launch-env twin of
        // the hopdemo://send deep link (apple-05). The deep link was DEBUG-gated but this one wasn't, so a
        // RELEASE build launched with an attacker-injected env (USB/devicectl) could send as the user's
        // identity and (via automationMirrorEnabled) drop a plaintext mirror, defeating SQLCipher-at-rest.
        // Compile the send out of shipped builds; the harness runs DEBUG builds and keeps its automation.
        #if DEBUG
        // The "send|addr|text" parse (incl. rejoining stray pipes into the marker) lives in
        // HopDemoKit and is unit-tested; the retry/send loop stays here.
        guard let parsed = DemoFormat.parseAutomationEnv(spec) else { return }
        let to = parsed.to
        let text = parsed.text
        // Stage C moved node-open off the main thread, so the node isn't guaranteed ready at a fixed
        // delay after cold launch. Retry the send on a backoff until it's accepted (self-address known)
        // instead of a single fire-and-forget that can land before the node exists.
        func attempt(_ n: Int) {
            guard n < 12 else { return }
            if HopBearer.shared.isReady {
                HopBearer.shared.sendTo(addressBase58: to, text: text)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { attempt(n + 1) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { attempt(0) }
        #endif
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
