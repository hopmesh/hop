# BACKGROUND.md: Suspended/Terminated iOS ⇄ Android BLE Re-link

**Scope.** We already have a proven, minimal, cross-platform dual-role BLE transport (insecure L2CAP CoC, Ditto-style: Android advertises a connectable service, iOS central connects, reads a PSM from one GATT char, opens L2CAP, bytes flow). Foreground works perfectly; a **backgrounded-but-alive** iOS app holds its L2CAP link fine (`UIBackgroundModes` `bluetooth-central`/`bluetooth-peripheral` + the 1 Hz PING keepalive). This document specifies the one remaining hard problem: a **SUSPENDED or TERMINATED (killed)** iOS app must **eventually** (re)connect to a nearby Android device, with **eventual latency acceptable but total failure not**.

The current code (verified in this repo):
- Android `sh.hopme.blelab`, `android/app/src/main/java/net/waldrip/blelab/{Ble.kt,BleService.kt,MainActivity.kt}`, `AndroidManifest.xml`. One connectable `AdvertisingSet` (service UUID `7ED70001…` + 6-byte mfg prefix), GATT one-char PSM read, insecure L2CAP listener, all inside a `connectedDevice` foreground service.
- iOS `sh.hopme.blelab`, shared core `apple/HopBleLab.swift` (the `Node`/`Central`/`Peripheral`/`Link`), app shell `apple-ios/{BleLabApp.swift,ContentView.swift}`, `apple-ios/project.yml` (XcodeGen, deployment target **iOS 16.0**), `apple-ios/HopBleLab-Info.plist`. The `Central` already opts into CoreBluetooth State Restoration via `CBCentralManagerOptionRestoreIdentifierKey: "hoplab.ble.central"`, but `willRestoreState` is a stub and there is **no CoreLocation**.

---

## 1. Decision: why this topology, in one paragraph

A **backgrounded iOS peripheral is invisible to Android**: iOS relocates the 128-bit service UUID into Apple's proprietary overflow area (mfg-data, company `0x004C`, hashed bitmask) that Android only reads with its screen on. So the only robust direction is **Android = always-discoverable connectable peripheral + iBeacon emitter; iOS = central, woken by the beacon**. Android already plays that role; we add the beacon. On iOS, **no single API both survives force-quit and completes a BLE handshake**, so we run **three independent wake layers** with different failure modes and let "eventual" win.

---

## 2. iOS wake architecture: three layers (priority order)

| Layer | Mechanism | Survives | Does NOT survive |
|---|---|---|---|
| **C (primary, force-quit-proof)** | **CoreLocation iBeacon region monitoring** (`CLLocationManager` + `CLBeaconRegion`) | user force-quit, system kill, reboot (after first unlock) | "While Using"-only auth, Background App Refresh OFF, already-inside-stationary (edge-triggered) |
| **B (complementary)** | **CoreBluetooth State Preservation & Restoration** (`CBCentralManagerOptionRestoreIdentifierKey` + no-timeout `connect()`) | system kill / jetsam, crash, reboot | **user force-quit**, BT toggle off→on, **iOS 26 terminated-relaunch (unless AccessorySetupKit adopted)** |
| **A (steady-state)** | **Background service-UUID scan** (`scanForPeripherals(withServices:[SERVICE_UUID])`) + no-timeout pending `connect()` | suspended-but-alive | full termination (a bare scan match does **not** relaunch a dead app) |

**The combination is load-bearing.** Layer C is the *only* thing that resurrects a force-quit app for a proximity event; Layer B is the *only* thing that lets an in-flight `connect()` complete across re-suspension; Layer A handles the cheap suspended-alive case. None alone gives "never total failure."

**Wake → link bridge (what happens on every wake):** region enter (C) or `willRestoreState`/discovery (B) brings the process up → the existing `Central` powers on its restore-ID `CBCentralManager` → `scanForPeripherals(withServices:[SERVICE_UUID])` (already auto-armed on `.poweredOn`) → `didDiscover` → `connect` → discover the one PSM char → read PSM → `openL2CAPChannel(psm)` → HELLO → `LINK UP` → 1 Hz PROOF. Within the ~10 s wake window we **also** re-issue no-timeout `connect()` to any system-connected peers (`retrieveConnectedPeripherals`) so the link can complete *after* the window via Layer B even if the scan is slow.

### iOS 26 reality (must surface in onboarding/tests)
Starting iOS 26, generic CoreBluetooth state-restoration **relaunch-from-terminated no longer fires unless the app adopts AccessorySetupKit** (TN3115 / Apple site update, Sep 2025). On iOS 26, Layer B's *terminated* relaunch is gone; **Layer C (CoreLocation) carries the terminated case** and still works. We do **not** adopt AccessorySetupKit in the lab (it forces one user tap per peer and is awkward for an Android *phone* peer); we note it as the future way to restore Layer B on 26+ for a blessed peer. Layer B continues to work fully on iOS ≤ 25 and still provides *suspended/system-kill* resumption.

---

## 3. iOS implementation: exact code-level changes (`sh.hopme.blelab`)

### 3.1 Info.plist / `project.yml` keys

XcodeGen generates the Info.plist from `project.yml` → edit **both** the `project.yml` `info.properties` block (source of truth) and the committed `HopBleLab-Info.plist` (so the checked-in file matches).

**`apple-ios/project.yml`**, under `targets.HopBleLab.info.properties`, change `UIBackgroundModes` and add the location keys:

```yaml
        UIBackgroundModes:
          - bluetooth-central
          - bluetooth-peripheral
          - location                       # enables ranging to extend the wake window (monitoring alone does not require it)
        NSBluetoothAlwaysUsageDescription: "BLE Lab tests Bluetooth LE connectivity between devices over L2CAP."
        NSBluetoothPeripheralUsageDescription: "BLE Lab advertises a BLE service and hosts an L2CAP channel for the proof-of-pipe test."
        NSLocationWhenInUseUsageDescription: "BLE Lab detects a nearby Hop device beacon to reconnect."
        NSLocationAlwaysAndWhenInUseUsageDescription: "BLE Lab monitors a Hop iBeacon region so it can relaunch in the background and reconnect to nearby devices even when the app is closed."
        UIRequiredDeviceCapabilities:      # optional; improves region-monitoring reliability after reboot
          - location-services
```

Add the same five string keys + the `location` background mode + (optionally) `UIRequiredDeviceCapabilities` to **`apple-ios/HopBleLab-Info.plist`**.

Also register the new source file under `targets.HopBleLab.sources`:

```yaml
    sources:
      - BleLabApp.swift
      - BeaconWake.swift          # NEW (see §3.3)
      - ContentView.swift
      - ../apple/HopBleLab.swift
```

**Hard dependencies (surface in UI):** `authorizedAlways` location, **Background App Refresh ON** (global + per-app), Bluetooth ON. Any one off ⇒ no terminated-app wake.

### 3.2 Shared core edits: `apple/HopBleLab.swift`

These compile unchanged for the macOS CLI too (all APIs exist on macOS). Two edits.

**(a) Flesh out `Central.willRestoreState`**: replace the stub (currently lines ~528 to 531):

```swift
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log("STATE", "central willRestoreState peripherals=\(restored.count)")
        for p in restored {
            retained[p.identifier] = p        // re-retain BEFORE anything else (SPEC §3.2.3)
            p.delegate = self                 // the system does NOT keep our delegate wiring
            if p.state == .connected {
                p.discoverServices(nil)       // resume the PSM-read handshake
            } else {
                c.connect(p, options: nil)    // re-arm the no-timeout pending connect (Layer B)
            }
        }
        // scan re-arms in centralManagerDidUpdateState(.poweredOn), which fires next.
    }
```

**(b) Add a public `wake(_:)` to `Central`** (the wake→scan/connect bridge), e.g. just after `centralManagerDidUpdateState`:

```swift
    /// Background-wake hook (CoreLocation region enter, or app relaunch). Idempotent.
    /// Re-arms the service-filtered scan and pins a no-timeout connect to any peer the
    /// system still considers connected for our service, so the link can complete via
    /// state restoration even if the ~10 s scan window closes first.
    func wake(_ reason: String) {
        guard let cm = cm else { return }
        log("STATE", "WAKE(\(reason)) state=\(stateName(cm.state)) scanning=\(cm.isScanning)")
        guard cm.state == .poweredOn else { return }   // scan auto-starts on .poweredOn
        if !cm.isScanning {
            cm.scanForPeripherals(withServices: [SERVICE_UUID],
                                  options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            log("STATE", "WAKE re-armed scan")
        }
        for p in cm.retrieveConnectedPeripherals(withServices: [SERVICE_UUID]) where retained[p.identifier] == nil {
            log("STATE", "WAKE re-adopt connected id=\(p.identifier.uuidString.prefix(8))")
            dial(cm, p, advPrefixById[p.identifier])
        }
    }
```

**(c) Expose it on `Node`** (add one method to `final class Node`):

```swift
    /// Called from the iOS AppDelegate on a CoreLocation region wake.
    func wake(_ reason: String) { central?.wake(reason) }
```

(`central` is `private var central: Central!`; the method is inside `Node`, so it has access. No other change to `Node`.)

### 3.3 New file: `apple-ios/BeaconWake.swift` (CLLocationManager + Always flow)

```swift
// BeaconWake.swift, iOS-only CoreLocation iBeacon region monitor (Layer C, the
// force-quit-proof relaunch). On region enter it pokes the BLE Node to (re)scan/connect.
import Foundation
import CoreLocation
import UIKit

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
        default: log("STATE", "location auth=\(lm.authorizationStatus.rawValue), NO terminated wake")
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
```

### 3.4 Rewire the app shell: `apple-ios/BleLabApp.swift`

Move all bootstrap into a `UIApplicationDelegate` so it runs on **cold background launch** (location/CB) and can read `launchOptions`. The delegate owns the `Node` and the `BeaconWake`. Replace the file's `@main struct` section (keep `BLEIOThread` and `redirectLogsToFile()` as-is):

```swift
import SwiftUI
import CoreBluetooth
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var node: Node?
    private var beacon: BeaconWake?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        redirectLogsToFile()
        // §8.1: dedicated CB queue + I/O run loop BEFORE Node() (main queue silently drops CB callbacks on iOS 18+).
        bleQueue   = DispatchQueue(label: "hop.ble.cb", qos: .userInitiated)
        bleRunLoop = BLEIOThread.shared.runLoop

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
        WindowGroup { ContentView() }
            .onChange(of: scenePhase) { phase in bleAppInBackground = (phase == .background) }
    }
}
```

**Why an AppDelegate:** SwiftUI's `App.init` ordering vs. delegate launch is unspecified; `application(_:didFinishLaunchingWithOptions:)` is the one place guaranteed to run first on every launch type (foreground, location relaunch, CB relaunch) and the only place `launchOptions` is delivered. Re-creating `Node()` here re-instantiates the `CBCentralManager` with the same `RESTORE_ID_CENTRAL`, which is what makes iOS hand back the restored peripherals to `willRestoreState`.

---

## 4. Android implementation: exact code-level changes (`sh.hopme.blelab`)

### 4.1 iBeacon over-the-air byte layout (legacy ≤31-byte PDU)

```
02 01 06                         Flags (LE General Discoverable, BR/EDR not supported); stack adds this
1A FF 4C 00                      len=0x1A(26), type=0xFF (mfg data), company=0x004C little-endian (4C 00), stack adds 1A FF 4C 00
02 15                            iBeacon subtype (0x02) + remaining length (0x15 = 21)
<16 bytes>                       Proximity UUID  (== BEACON_UUID, big-endian / network order)
<2 bytes big-endian>             Major
<2 bytes big-endian>             Minor
<1 byte signed>                  Measured TX power @1m (0xC5 = -59 dBm)
```

In Android you pass **only the 23-byte body** `[02 15][uuid16][major2][minor2][power1]` to `addManufacturerData(0x004C, payload)`; the stack prepends `1A FF 4C 00`. A 25-byte iBeacon + a 16-byte 128-bit service UUID do **not** co-fit in one 31-byte packet, which is why this is a **second** advertising set.

### 4.2 `Ble.kt`: add the iBeacon `AdvertisingSet` to `Peripheral`

Add constants near the top (next to `SERVICE_UUID`):

```kotlin
val BEACON_UUID: UUID = UUID.fromString("7ED7BEAC-3C2A-4F19-9B8E-1A2B3C4D5E6F") // == iOS BEACON_UUID
const val APPLE_COMPANY_ID = 0x004C
const val BEACON_CYCLE_MS = 300_000L   // ~5 min: floor for CoreLocation relaunch rate-limit
const val BEACON_EXIT_GAP_MS = 35_000L // > iOS ~30 s exit-debounce, so stop→start makes a clean enter

fun iBeaconPayload(uuid: UUID, major: Int, minor: Int, measuredPowerDbm: Int): ByteArray {
    val b = java.nio.ByteBuffer.allocate(23)          // ByteBuffer is big-endian by default
    b.put(0x02).put(0x15)                             // subtype + length(0x15=21)
    b.putLong(uuid.mostSignificantBits)              // UUID high 8 bytes (network order)
    b.putLong(uuid.leastSignificantBits)             // UUID low 8 bytes
    b.putShort(major.toShort())                      // major BE
    b.putShort(minor.toShort())                      // minor BE
    b.put(measuredPowerDbm.toByte())                 // -59 -> 0xC5
    return b.array()
}
```

Inside `class Peripheral`, add the beacon set + callback + a cycler, and stop them in `stop()`:

```kotlin
    private var beaconSet: AdvertisingSet? = null
    private val beaconSched = Executors.newSingleThreadScheduledExecutor()
    private val beaconCb = object : AdvertisingSetCallback() {
        override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
            beaconSet = set; Log.i(TAG, "BEACON started status=$status txPower=$txPower")
        }
        override fun onAdvertisingSetStopped(set: AdvertisingSet?) {
            beaconSet = null; Log.i(TAG, "BEACON stopped")
        }
    }

    fun startBeacon() {
        if (beaconSet != null) return
        val adv = adapter.bluetoothLeAdvertiser ?: return
        if (!adapter.isMultipleAdvertisementSupported) {     // controller can't run 2 sets at once
            Log.w(TAG, "multi-advertisement UNSUPPORTED, iBeacon skipped (time-slice fallback not implemented)")
            return
        }
        val params = AdvertisingSetParameters.Builder()
            .setLegacyMode(true)        // REQUIRED: iOS CoreLocation only detects legacy-PDU iBeacons
            .setConnectable(false).setScannable(false)
            .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_MEDIUM).build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false).setIncludeTxPowerLevel(false)
            .addManufacturerData(APPLE_COMPANY_ID, iBeaconPayload(BEACON_UUID, 1, 1, -59)).build()
        adv.startAdvertisingSet(params, data, null, null, null, beaconCb)
    }

    // Manufacture iOS region exit→enter so a force-quit iOS app that is sitting adjacent gets relaunched.
    fun startBeaconCycler() {
        beaconSched.scheduleAtFixedRate({
            try {
                Log.i(TAG, "BEACON cycle: stop (force iOS region exit)")
                adapter.bluetoothLeAdvertiser?.stopAdvertisingSet(beaconCb); beaconSet = null
                beaconSched.schedule({ startBeacon() }, BEACON_EXIT_GAP_MS, TimeUnit.MILLISECONDS)
            } catch (_: Exception) {}
        }, BEACON_CYCLE_MS, BEACON_CYCLE_MS, TimeUnit.MILLISECONDS)
    }
```

In `Peripheral.start()`, after `startGattServer()` add:

```kotlin
        startBeacon()
        startBeaconCycler()
```

In `Peripheral.stop()` add (alongside the existing advertiser stop):

```kotlin
        try { beaconSet?.let { adapter.bluetoothLeAdvertiser?.stopAdvertisingSet(beaconCb) } } catch (_: Exception) {}
        beaconSet = null
```

> The connectable service set (`startAdvertise()`) is unchanged: it already puts `SERVICE_UUID` in the **primary** packet, which is exactly what iOS passive background scan needs. The beacon set is purely the iOS *relaunch* signal.

### 4.3 `BleService.kt`: typed `startForeground` + reboot restart

Android 14+ requires the typed `startForeground`. Replace the 2-arg call in `onCreate`:

```kotlin
import android.content.pm.ServiceInfo
import android.os.Build
// ...
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
    startForeground(NOTIF_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
} else {
    startForeground(NOTIF_ID, buildNotification())
}
```

New file **`android/app/src/main/java/net/waldrip/blelab/BootReceiver.kt`** (restart the FGS after reboot, `connectedDevice` is allowed to start from `BOOT_COMPLETED` on Android 14):

```kotlin
package sh.hopme.blelab
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) BleService.start(context)
    }
}
```

### 4.4 `AndroidManifest.xml`: add boot + battery-exemption perms and the receiver

```xml
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
```

Inside `<application>`:

```xml
<receiver android:name=".BootReceiver" android:exported="true">
    <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED" />
    </intent-filter>
</receiver>
```

### 4.5 `MainActivity.kt`: prompt for battery-optimization exemption (recommended)

After permissions are granted and before/after `BleService.start(this)`, prompt the user once (aggressive OEMs reap non-exempt FGSs):

```kotlin
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
// ...
private fun requestBatteryExemption() {
    val pm = getSystemService(PowerManager::class.java)
    if (!pm.isIgnoringBatteryOptimizations(packageName)) {
        startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:$packageName")))
    }
}
```

> CompanionDeviceManager `startObservingDevicePresence` (+ `REQUEST_COMPANION_START_FOREGROUND_SERVICES_FROM_BACKGROUND`) is the "device reappeared, wake me from background" blessed path and the next hardening step if FGS reaping is observed in the field, not required for the lab proof.

---

## 5. Shared constant contract

Both sides must agree byte-for-byte:

| Thing | iOS | Android |
|---|---|---|
| Service UUID (connectable/L2CAP) | `SERVICE_UUID 7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F` | `SERVICE_UUID 7ED70001-…` |
| GATT PSM char | `ENDPOINT_CHAR 7ED70002-…` | `ENDPOINT_CHAR 7ED70002-…` |
| iBeacon proximity UUID | `BEACON_UUID 7ED7BEAC-3C2A-4F19-9B8E-1A2B3C4D5E6F` | `BEACON_UUID 7ED7BEAC-…` |
| Major / Minor | region matches on UUID only (major/minor ignored) | `1 / 1` |
| CB restore ID (central) | `hoplab.ble.central` | n/a |

---

## 6. Device test procedure: the killed-iOS-app wake

**Pre-flight (one-time on the iPhone):** install the app, open it once, grant Bluetooth, grant location and **escalate to "Always"** (the prompt appears after the When-In-Use grant or later in Settings → BLE Lab → Location → **Always**), and confirm Settings → General → **Background App Refresh = ON** (global and for BLE Lab). On the Android phone: grant the three BT runtime perms + notifications and **accept the battery-optimization exemption** prompt.

### Step 1: build & install
```bash
# Android
cd /Users/jwaldrip/dev/src/github.com/jwaldrip/hop/ble-lab/android && ./gradlew installDebug
adb shell am start -n sh.hopme.blelab/.MainActivity

# iOS (XcodeGen project)
cd /Users/jwaldrip/dev/src/github.com/jwaldrip/hop/ble-lab/apple-ios && xcodegen generate
# then build+install+launch onto the USB device via Xcode (Run), or:
xcrun devicectl list devices                       # grab the iPhone's identifier
xcrun devicectl device install app --device <UDID> <path-to-HopBleLab.app>
xcrun devicectl device process launch --device <UDID> sh.hopme.blelab
```

### Step 2: confirm a foreground baseline link
- Android: `adb logcat -s HOPLOG | grep -E "BEACON|ADVERTISING|LINK UP|PROOF"` → expect `ADVERTISING started`, `BEACON started`, `LINK UP`, repeating `PROOF`.
- iOS: the app redirects stdout to `Documents/blelab.log`. Watch the on-screen log or pull it (Step 4). Expect `beacon monitoring started`, `LINK UP`, repeating `PROOF`.

### Step 3, FORCE-QUIT the iOS app (the strict worst case)
1. On the iPhone, swipe up from the bottom edge and pause to open the **App Switcher**.
2. **Swipe the BLE Lab card up and off the top.** The app is now *user-terminated* (the case CB restoration cannot recover, only CoreLocation can).
3. Keep the two phones next to each other (≈1 m). Do **not** reopen the app.

### Step 4: verify relaunch-into-background + re-link
- The Android `BeaconCycler` stops the beacon, waits 35 s (iOS registers a region **exit**), then restarts it (iOS registers a region **enter**), at most once per `BEACON_CYCLE_MS` (~5 min). On that enter, **iOS relaunches BLE Lab into the background** (no UI; the app does not come to foreground).
- After 1 to 5 min, pull the iOS log:
```bash
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier sh.hopme.blelab \
  --source Documents/blelab.log --destination ./ios-blelab.log
# (or Xcode → Devices and Simulators → BLE Lab → ⚙︎ → Download Container → show package → AppData/Documents/blelab.log)
```
- **Ground truth = a NEW block in `ios-blelab.log` timestamped AFTER the force-quit**, containing:
  - `COLD LAUNCH background=true location=true` ← proves it relaunched, in the **background**, via the **location** key (not a manual open),
  - then `central scan-started` → `discovered …` → `DIALING …` → `LINK UP` → `PROOF peer=… rx=… tx=…`.
- Cross-check on Android: `adb logcat -s HOPLOG` shows a fresh `ACCEPTED inbound L2CAP` → `LINK UP` → `PROOF` at the same wall-clock time.

The presence of fresh `PROOF` lines while the app was never manually reopened **is** the proof of eventual background re-link from a killed iOS app.

### Step 5: additional cases to exercise
- **Separate-and-return:** force-quit iOS, carry it >~30 m away (out of BLE range) for a minute, return. The natural region exit→enter relaunches it without waiting for a beacon cycle; confirms the non-stationary path is faster.
- **System kill / suspend (Layer B):** with iOS *suspended* (Home button, app still in switcher), bring devices together; expect re-link via background scan/restoration within tens of seconds, `willRestoreState peripherals=N` then `LINK UP` in the log (no `COLD LAUNCH location=true` needed).
- **Reboot:** reboot the iPhone, unlock once, leave the app closed; on the next beacon enter it relaunches (monitored regions survive reboot). Reboot the Android: `BootReceiver` restarts the FGS, `adb logcat` shows `NODE START` + `BEACON started` with no manual launch.

### How to read logs (summary)
- **Android:** `adb logcat -s HOPLOG` (tag `HOPLOG`); key lines `BEACON …`, `ADVERTISING …`, `ACCEPTED inbound L2CAP`, `LINK UP`, `PROOF`.
- **iOS:** `Documents/blelab.log` (tag `HOPLAB`), pulled via `xcrun devicectl device copy from …` or Xcode Download Container; key lines `COLD LAUNCH …`, `BEACON WAKE …`, `WAKE re-armed scan`, `central willRestoreState …`, `LINK UP`, `PROOF`. (Prints go to the file, not os_log, so Console.app won't show them; the file is the artifact.)

---

## 7. Honest capabilities / limits matrix

Android here = always-on `connectedDevice` foreground service running the connectable service set **and** the cycling iBeacon. *Without that FGS, Android stops advertising ~10 to 15 min after backgrounding and every row fails.* Latencies assume the two devices are within BLE range.

| iOS app state | Wake path that fires | Re-links? | Typical latency |
|---|---|---|---|
| **Foreground** | direct scan→connect→L2CAP | Yes | ~1 to 3 s |
| **Background, alive** (keepalive holding) | existing link stays up; new link via slowed bg scan | Yes | seconds to tens of seconds |
| **Suspended** (in memory) | Layer A bg-scan discovery + Layer B pending connect | Yes | tens of seconds to ~2 to 3 min |
| **System-killed** (jetsam/memory, iOS ≤ 25) | Layer B restoration on discovery/connection (+ Layer C) | Yes | ~1 to 3 min |
| **System-killed, iOS 26** | Layer C only (Layer B terminated-relaunch disabled without AccessorySetupKit) | Yes (via beacon) | dominated by beacon enter; single-digit min |
| **User force-quit**, Always-location ON, a boundary crossing occurs (incl. Android beacon cycle) | **Layer C only** | Yes | next region enter; ≤ ~5 min per cycle (the `BEACON_CYCLE_MS` floor + CoreLocation's ~3 to 5 min relaunch rate-limit) |
| **User force-quit, already adjacent & both stationary** | Layer C **only via Android beacon cycling** (that is exactly what `startBeaconCycler()` is for) | Yes, eventually | ≤ ~5 min (one cycle); **without the cycler this is a hard fail** |
| **Reboot**, app left closed, Always-location ON | Layer C (regions survive reboot, after first unlock) | Yes | ~3 min post-unlock, then per beacon enter |

### Hard failures (no workaround, surface them in onboarding)
1. **iOS location not "Always"** (When-In-Use, or denied): force-quit/terminated wake is **impossible**. This is the single worst case for a privacy-minded user who picks "While Using." Detect it and tell the user force-quit recovery is unavailable; offer a one-tap "Open to reconnect" local notification as the only recovery.
2. **Background App Refresh OFF** (global or per-app): kills the CoreLocation relaunch path entirely; the app gets *no* region events even in foreground. Hard dependency, common silent failure.
3. **iOS 26 + terminated + no beacon crossing + no AccessorySetupKit:** Layer B is gone and Layer C needs an enter event; mitigated by the Android beacon cycler, but if the cycler is disabled and devices are stationary/adjacent, recovery waits for the user to move or open the app.
4. **Android with no foreground service / FGS reaped by an OEM battery killer:** nothing to discover. Mitigated by `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` + `BootReceiver`; some OEMs (Samsung/Xiaomi/Oppo/OnePlus) still need a manual "don't optimize / allow autostart" toggle (see dontkillmyapp.com).
5. **iOS Bluetooth toggled off→on while terminated:** invalidates CB restoration for that peer; only a later region crossing (Layer C) or manual launch recovers.

### Net behavior
BLE advertising and the iBeacon ride the Android controller through Doze (controller-driven, CPU-independent), so Android is reliably discoverable. On iOS, the beacon guarantees relaunch from *any* state including force-quit (given Always + BAR), CB restoration cheaply resumes after a system kill on ≤ 25, and the bg scan covers suspended-alive. Latency is "eventual" (slowed background scan, edge-triggered region coalescing, ~5 min beacon-cycle floor) but, within the listed hard-failure caveats, **total failure is designed out**.

---

## 8. Change checklist

**iOS (`sh.hopme.blelab`)**
- [ ] `project.yml` + `HopBleLab-Info.plist`: add `location` background mode, `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, (optional) `UIRequiredDeviceCapabilities: location-services`; register `BeaconWake.swift` source.
- [ ] `apple/HopBleLab.swift`: implement `Central.willRestoreState` (re-adopt peripherals), add `Central.wake(_:)`, add `Node.wake(_:)`.
- [ ] New `apple-ios/BeaconWake.swift` (CLLocationManager monitor + Always flow + background-task extension).
- [ ] `apple-ios/BleLabApp.swift`: introduce `AppDelegate` via `@UIApplicationDelegateAdaptor`; move bootstrap + `Node()` + `BeaconWake` into `didFinishLaunchingWithOptions`; log `COLD LAUNCH`.

**Android (`sh.hopme.blelab`)**
- [ ] `Ble.kt`: add `BEACON_UUID`/constants + `iBeaconPayload`; add `startBeacon()`, `beaconCb`, `startBeaconCycler()`, beacon teardown in `stop()`; call `startBeacon()` + `startBeaconCycler()` from `Peripheral.start()`.
- [ ] `BleService.kt`: typed 3-arg `startForeground(..., FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)`.
- [ ] New `BootReceiver.kt`; manifest: `RECEIVE_BOOT_COMPLETED`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, `<receiver>` for boot.
- [ ] `MainActivity.kt`: battery-optimization exemption prompt.
