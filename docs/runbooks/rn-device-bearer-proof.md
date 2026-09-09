# React Native physical bearer proof

This runbook proves that the Android half of `@hop-mesh/react-native` consumes the native Hop SDK and moves an acknowledged message over one physical bearer. A pass needs all three records for the same unique nonce:

1. The sender logs the queued nonce with every other bearer disabled.
2. The receiver's device log contains `RNPROOF receipt ... accepted=true` with a timestamp.
3. The sender logs `RNMAC ack ... delivered=true` or the iOS automation mirror reports the nonce as delivered.

A physical link log without the nonce is not delivery proof.

## Device inventory

The inventory for this run came from these commands:

```sh
adb devices -l
xcrun devicectl list devices
xcrun devicectl device info lockState --device 0280AC9F-551E-55DA-A969-62D4242A003C
xcrun devicectl device process launch --device 0280AC9F-551E-55DA-A969-62D4242A003C sh.hopme.demo
xcrun devicectl device info lockState --device 802500FE-27D7-502F-9D2C-9486D5CA74B2
xcrun devicectl device info details --device 802500FE-27D7-502F-9D2C-9486D5CA74B2
```

Relevant output:

```text
34241FDH2004KR  device  product:panther model:Pixel_7 device:panther
BushidoPhone  0280AC9F-551E-55DA-A969-62D4242A003C  available (paired)  iPhone 17 Pro
Current device lock state (BushidoPhone):
passcodeRequired: true
unlockedSinceBoot: true
ERROR: ... CoreDeviceError error 12040 ... kAMDMobileImageMounterDeviceLocked: The device is locked.

Test iPhone  802500FE-27D7-502F-9D2C-9486D5CA74B2  available (paired)  iPhone XR
Current device lock state (Test iPhone XR):
passcodeRequired: false
unlockedSinceBoot: true
developerModeStatus: enabled
ddiServicesAvailable: true
```

BushidoPhone remains passcode-locked and refuses DDI mounting and process launch with `CoreDeviceError 12040`. Test iPhone XR is unlocked, paired over wired USB, and has developer mode enabled. Test iPhone XR is the unlocked handset used for the Apple-side hardware bearer evaluation.
## Build the native consumer

From the repository root:

```sh
sdk/android/build-aar-dev.sh --repository sdk/react-native/android/.hop-maven
cd apps/react-native/HopDemo
npm ci
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export PATH="$JAVA_HOME/bin:$HOME/.cargo/bin:$PATH"
export HOP_MAVEN_REPOSITORY="$(cd ../../.. && pwd)/sdk/react-native/android/.hop-maven"
./android/gradlew -p android :app:assembleDebug --stacktrace --no-daemon
sha256sum android/app/build/outputs/apk/debug/app-debug.apk
adb -s 34241FDH2004KR install -r android/app/build/outputs/apk/debug/app-debug.apk
```

The successful run produced:

```text
build-aar-dev: verified all 3 required artifacts (sh.hop:hop, bearer-ble, bearer-lan)
> Task :hop-mesh_react-native:compileDebugKotlin
> Task :app:processDebugMainManifest
> Task :app:assembleDebug
BUILD SUCCESSFUL
c425580202753bd437ebe35f7a2d09ced91d8bbecee11a1c7d5b0fd3ffb0d0c0  android/app/build/outputs/apk/debug/app-debug.apk
Performing Streamed Install
Success
package:/data/app/.../com.hopdemo-.../base.apk
versionCode=1 minSdk=29 targetSdk=36
```

`testkit/rn-device-bearer-preflight.sh <run-id>` records this inventory, build, hash, and install as JSON, written into a results directory it creates under `testkit` at run time. It stops before claiming hardware delivery unless a later stage supplies a unique nonce, sender ACK, and receiver log.

## Build the Mac-side peer

The published Apple v0.0.3 artifact is absent, so local hardware proof uses the source-built framework and the repository's local manifest wrapper:

```sh
HOP_SQLCIPHER=0 sdk/apple/build-xcframework.sh
HOP_SQLCIPHER=0 tools/build-xcframework.sh
sdk/apple/with-local-framework.sh swift build --package-path ../../testkit/rn-mac-peer -c debug
```

`tools/build-xcframework.sh` dirties tracked generated files under `drivers/apple/HopDriver/Frameworks/`, `drivers/apple/HopDriver/.build-staging/`, and `drivers/apple/HopDriver/Sources/HopFFIBindings/`. Restore those generated files after the peer is linked. The compiled `testkit/rn-mac-peer/.build/debug/RnMacPeer` binary contains the exact-snapshot core.
## Build and install the Apple consumer

The native Apple consumer (`HopDemo.app`) is built from source using XcodeGen and Xcode:

```sh
cd apps/apple/HopDemo
xcodegen
xcodebuild -project HopDemo.xcodeproj -scheme HopDemo \
  -destination "id=802500FE-27D7-502F-9D2C-9486D5CA74B2" build
```

The build resolves local package dependencies (`HopDriver`, `HopDemoKit`, `HopBearerBle`, `HopBearerLan`, `HopBearerMultipeer`, `HopBearerRelay`, `HopBearerMeshtastic`, `sdk/apple`), links the local `libhop.a` static archive, and signs the bundle automatically:

```text
Signing Identity:     "Apple Development: Jason Waldrip (LY77W79566)"
Provisioning Profile: "iOS Team Provisioning Profile: sh.hopme.demo"
                      (6cfc04ec-7b7e-4522-9841-8c0ed41645de)
** BUILD SUCCEEDED **
```

Install and launch the application onto the connected iPhone XR:

```sh
xcrun devicectl device install app --device 802500FE-27D7-502F-9D2C-9486D5CA74B2 \
  ~/Library/Developer/Xcode/DerivedData/HopDemo-*/Build/Products/Debug-iphoneos/HopDemo.app
xcrun devicectl device process launch --device 802500FE-27D7-502F-9D2C-9486D5CA74B2 \
  --console --activate --terminate-existing sh.hopme.demo
```

Application installation succeeds (`bundleID: sh.hopme.demo`), and the process starts on the device.

## Apple physical bearer evaluation

Both physical bearers were exercised on the installed `sh.hopme.demo` on Test iPhone XR.

### Apple BLE evaluation

When `HopDemo` launches on Test iPhone XR, `BleBearer` initializes CoreBluetooth `CBPeripheralManager` and `CBCentralManager`:

```text
2026-09-09 09:41:22.327 HopDemo[8433:375481] HOPLAB 0.035 STATE peripheral state=unauthorized
2026-09-09 09:41:22.332 HopDemo[8433:375481] HOPLAB 0.039 STATE central state=unauthorized
```

System log inspection confirms the TCC access request:

```text
Sep 9 09:35:26.537069 HopDemo(TCC)[8331] <Info>: SEND: 0/7 synchronous to com.apple.tccd: request: msgID=8331.1, function=TCCAccessRequest, service=kTCCServiceBluetoothAlways
```

When `state == .unauthorized`, CoreBluetooth suppresses advertising and cancels scanning. Physical radio delivery is blocked by iOS TCC privacy gating.

In addition, coexisting app `HopBleLab` (`sh.hopme.blelab`) was running on the device, which contends for BLE L2CAP PSM publication. The dormant switch was asserted to prevent contention:

```sh
xcrun devicectl device process launch --device 802500FE-27D7-502F-9D2C-9486D5CA74B2 \
  --activate --payload-url "blelab://radio?enabled=false" sh.hopme.blelab
```

Verdict: blocked on Test iPhone XR due to pending TCC permission.
Missing prerequisite: an operator must tap Allow on the physical iPhone XR screen for the system BLE prompt, or enable BLE for `Hop Debug` in Settings -> Privacy & Security.

### Apple LAN evaluation

On launch, `LanBearer` starts its Bonjour listener and browser:

```text
2026-09-09 09:41:22.296 HopDemo[8433:375441] HOPLAB 0.004 STATE lan node-start myId=29c6b4f4 service=_hoplan._tcp
2026-09-09 09:41:22.299 HopDemo[8433:375484] HOPLAB 0.007 STATE lan listening name=29c6b4f4
2026-09-09 09:41:22.298 HopDemo[8433:375471] HOPLOG p2p start: cdf18b4a60618305db7fd3a867d72018 advertising=true
```

Querying bearer states via `hopdemo://bearerstates` confirms all transports active:

```text
HOPLAB HOPAUTO bearerstates states=["P2P": true, "LoRa": true, "LAN": true, "Relay": true, "BT": true] active=["Relay": 1]
```

Network inspection reveals the interface binding:

```text
nw_listener_reconcile_advertised_endpoints [L1] Reconciling advertised endpoints (null) for path satisfied (Path is satisfied), interface: en0[802.11], ipv4, dns, uses wifi
```

The Mac has a direct USB ethernet link to Test iPhone XR on interface `en27` (`169.254.61.24` to `169.254.52.86`), with ICMP ping round-trip times averaging 1.3 ms. However, Bonjour mDNS (`_hoplan._tcp`) advertises on Wi-Fi interface `en0`. Per `testkit/devices.sh`, Test iPhone XR is intentionally kept as a BLE-only handset and is not joined to the local Wi-Fi subnet (10.4.1.0 prefix) where the Pixel 7 (`10.4.1.203`) and Mac (`10.4.1.221`) reside.

Verdict: blocked on Test iPhone XR due to network segregation.
Missing prerequisite: Test iPhone XR must be joined to the same Wi-Fi LAN (10.4.1.0 subnet) as the Mac and Pixel 7 for Bonjour mDNS multicast to cross between endpoints.

## Run the React Native receiver

The Pixel was passcode-locked, so UI automation was not admissible. The testkit Metro entry runs inside the installed `com.hopdemo` APK, creates one native `HopNode`, disables the unwanted bearer before starting the pump, and emits timestamped evidence through `ReactNativeJS`.

Start Metro for one bearer:

```sh
cd apps/react-native/HopDemo
RN_PROOF_BEARER=ble node node_modules/react-native/cli.js start \
  --config ../../../testkit/metro.rn-device-proof.config.js --port 8081 --reset-cache
```

In another shell:

```sh
adb -s 34241FDH2004KR reverse tcp:8081 tcp:8081
adb -s 34241FDH2004KR shell pm grant com.hopdemo android.permission.BLUETOOTH_SCAN
adb -s 34241FDH2004KR shell pm grant com.hopdemo android.permission.BLUETOOTH_ADVERTISE
adb -s 34241FDH2004KR shell pm grant com.hopdemo android.permission.BLUETOOTH_CONNECT
adb -s 34241FDH2004KR shell pm grant com.hopdemo android.permission.ACCESS_LOCAL_NETWORK
adb -s 34241FDH2004KR shell dumpsys deviceidle whitelist +com.hopdemo
adb -s 34241FDH2004KR shell am set-standby-bucket com.hopdemo active
adb -s 34241FDH2004KR shell am force-stop com.hopdemo
adb -s 34241FDH2004KR shell run-as com.hopdemo rm -f \
  files/rn-device-bearer-proof.db files/rn-device-bearer-proof.db-wal files/rn-device-bearer-proof.db-shm
adb -s 34241FDH2004KR logcat -c
adb -s 34241FDH2004KR shell monkey -p com.hopdemo -c android.intent.category.LAUNCHER 1
adb -s 34241FDH2004KR logcat -v threadtime
```

For LAN, restart Metro with `RN_PROOF_BEARER=lan` and repeat the clean receiver launch. Readiness must name the selected bearer and show the other disabled:

```text
2026-09-09T06:39:31.284Z RNPROOF ready bearer=ble self=FDed... states={"ble":"enabled","lan":"disabled","relay":"disabled"}
2026-09-09T06:45:12.714Z RNPROOF ready bearer=lan self=4fFc... states={"ble":"disabled","lan":"enabled","relay":"disabled"}
```

## BLE-only result

The sender command used the full address from the BLE readiness line and a new nonce:

```sh
testkit/rn-mac-peer/.build/debug/RnMacPeer \
  ble FDedJYSHprUZekBFAX7ECRtJLbhAykeadSBUN73mo1pB rn_ble_20260909T064235Z_b2
```

The three proof records were:

```text
2026-09-09T06:43:21Z RNMAC send bearer=ble nonce=rn_ble_20260909T064235Z_b2 ... result=queued states=["BT": true, "P2P": false] active=[:]
09-09 00:43:33.116 ... ReactNativeJS: 2026-09-09T06:43:33.114Z RNPROOF receipt bearer=ble nonce=rn_ble_20260909T064235Z_b2 from=4VhPH9DLKWEZzTShCV7sAtmvDENtJ4FptyQkKuipoB8f accepted=true
2026-09-09T06:43:45Z RNMAC ack bearer=ble nonce=rn_ble_20260909T064235Z_b2 delivered=true deliveryMs=32895 hops=1
```

Verdict: exercised on the physical Pixel 7 and the Mac BLE radio. LAN, P2P, relay, and LoRa were unavailable or disabled on both ends before the send.

## LAN-only result

LAN isolation itself was established on every attempted endpoint. The RN receiver reported BLE and relay disabled. The Mac sender reported only LAN enabled:

```text
RNMAC send bearer=lan ... states=["LAN": true, "LoRa": false, "P2P": false, "BT": false] active=[:]
HOPLAB HOPAUTO bearerstates states=["LoRa": false, "LAN": true, "Relay": false, "BT": false, "P2P": false] active=[:]
```

Physical LAN delivery succeeded in both dialer directions once the Android standby firewall restriction was identified and exempted.

### Rejected hypotheses

Two earlier hypotheses were tested and rejected:

1. macOS Local Network privacy denial: Unified logs confirmed that RnMacPeer Network.framework paths were satisfied with listener inboxes active on `en0` and no privacy denials. A probe from the Pixel shell UID (UID 2000) to the Mac listener succeeded (rc=0), proving the Mac listener and the physical Wi-Fi path were unblocked.
2. Missing Android runtime permission: `NEARBY_WIFI_DEVICES` was added to the manifest, granted, and confirmed as `allow` in appops. Native dials still timed out after 5000 ms because Wi-Fi discovery permissions do not alter kernel IP firewall rules.

### Diagnostic sequence and root cause

The per-UID discrimination was isolated by testing outbound TCP to an external IP (`1.1.1.1:80`):

```sh
adb -s 34241FDH2004KR shell "nc -w 2 1.1.1.1 80; echo rc=\$?"
# rc=0 (shell UID 2000 reaches the internet)

adb -s 34241FDH2004KR shell "run-as com.hopdemo nc -w 2 1.1.1.1 80; echo rc=\$?"
# nc: Timeout, rc=1 (app UID 10636 cannot send any TCP packet)
```

This proved the block was not local-subnet-specific or Wi-Fi-specific: all IP traffic from UID 10636 was being dropped by the OS.

Inspecting Android network policy revealed the exact blocking layer:

```sh
adb -s 34241FDH2004KR shell dumpsys netpolicy | grep -E "UID=10636"
# UID=10636 state=null blocked_state={blocked=APP_STANDBY|APP_BACKGROUND,allowed=NONE,effective=APP_STANDBY|APP_BACKGROUND}

adb -s 34241FDH2004KR shell dumpsys network_management | grep 10636
# UID firewall standby rule: [ ... 10636:2 ... ] (2 = FIREWALL_RULE_DENY)
```

Because the test runs headlessly on a passcode-locked device with screen sleeping, ActivityManager keeps the app in `PROCESS_STATE_TOP_SLEEPING`. Without power-save allowlisting, `NetworkPolicyManagerService` marks the app `effective=APP_STANDBY|APP_BACKGROUND` and installs a netd eBPF drop rule in the `fw_standby` chain. Outbound SYN packets are dropped before leaving `wlan0`, and inbound SYN packets are dropped before reaching `ServerSocket.accept()`. Shell UID 2000 succeeded because system UIDs have `never_apply_rules_to_core_uids: true`. BLE succeeded because L2CAP channels use HCI through `bluetoothd` rather than the Linux IP packet filter.

Exempting the package from battery restrictions removes the drop rule:

```sh
adb -s 34241FDH2004KR shell dumpsys deviceidle whitelist +com.hopdemo
adb -s 34241FDH2004KR shell am set-standby-bucket com.hopdemo active
adb -s 34241FDH2004KR shell dumpsys netpolicy | grep -E "UID=10636"
# UID=10636 state=null blocked_state={blocked=APP_BACKGROUND,allowed=POWER_SAVE_ALLOWLIST|POWER_SAVE_EXCEPT_IDLE_ALLOWLIST,effective=NONE}
```

With `effective=NONE`, probes connected immediately:

```text
Pixel app UID to 1.1.1.1:80: rc=0
Pixel app UID to Mac 10.4.1.221:60555: Accepted connection from ('10.4.1.203', 44778), rc=0
Mac to Pixel app listener 10.4.1.203:60556: Connection to 10.4.1.203 port 60556 [tcp/*] succeeded!
```

### Verified physical LAN delivery

With the power-save allowlist in place, physical LAN delivery was exercised in both dialer directions:

1. Pixel as dialer (Mac node ID `53c27e6e` < Pixel node ID `5a910768`):

```text
Mac send:
2026-09-09T09:15:54Z RNMAC send bearer=lan nonce=rn_lan_20260909T091554Z_macdial to=DHwvAiWiuyVPJwkK1e27Zn2hr18WBj7uoE44VhT5ugB4 result=queued states=["BT": false, "P2P": false, "LoRa": false, "LAN": true] active=[:]
HOPLAB 1.149 STATE lan inbound-connection (acceptor)
HOPLAB 1.157 STATE lan channel-ready isDialer=false
HOPLAB 1.169 STATE lan hello-recv peer=5a910768
2026-09-09T09:15:56Z RNMAC ack bearer=lan nonce=rn_lan_20260909T091554Z_macdial delivered=true deliveryMs=57148 hops=1

Pixel receiver:
09-09 03:15:57.372 13091 13159 I ReactNativeJS: 2026-09-09T09:15:57.368Z RNPROOF receipt bearer=lan nonce=rn_lan_20260909T091554Z_macdial from=7z9NYW5Wd3Cq43TaaeeHgmFksKPs4xqxhuyeztfNSa2F accepted=true
```

2. Mac as dialer (Mac node ID `d72fdd8e` > Pixel node ID `75afd046`):

```text
Mac send:
HOPLAB 0.007 STATE lan discovered peer=75afd046 -> DIAL
HOPLAB 0.104 STATE lan channel-ready isDialer=true
HOPLAB 0.133 STATE lan hello-recv peer=75afd046
2026-09-09T09:13:17Z RNMAC send bearer=lan nonce=rn_lan_20260909T091316Z_round2 to=8c6KdNjhkZS9cn1FdgiA23nDgYSaJpaMd8DpHwEa828N result=queued states=["LoRa": false, "P2P": false, "BT": false, "LAN": true] active=["LAN": 1]
2026-09-09T09:13:17Z RNMAC ack bearer=lan nonce=rn_lan_20260909T091316Z_round2 delivered=true deliveryMs=18355 hops=1

Pixel receiver:
09-09 03:13:18.551 12305 12406 I ReactNativeJS: 2026-09-09T09:13:18.548Z RNPROOF receipt bearer=lan nonce=rn_lan_20260909T091316Z_round2 from=4JaaJ5BdU9YmsA8PuHpidBJWxYuUtvjJwSjKNji1kHqo accepted=true
```

Verdict: exercised on the physical Pixel 7 and the Mac Wi-Fi radio with unique nonces, receipts, and ACKs in both dialer directions.
## Failure modes found by this run

The first full app assembly exposed three consumer constraints that module compilation had not:

1. An exact `includeGroup "sh.hop"` filter excluded `sh.hop.bearers` and produced `Could not find sh.hop.bearers:bearer-ble:0.0.3` plus the LAN equivalent.
2. The module emitted Kotlin 2.4.0 metadata while the app compiler expected 2.2.0: `Module was compiled with an incompatible version of Kotlin. The binary version of its metadata is 2.4.0, expected version is 2.2.0.`
3. The demo declared `minSdk 24`, but BLE uses `listenUsingInsecureL2capChannel()` and `createInsecureL2capChannel()`, which first appear in API 29. Manifest merge failed with `uses-sdk:minSdkVersion 24 cannot be smaller than version 29 declared in library [sh.hop.bearers:bearer-ble:0.0.3]`.

The documented Apple build also changed ten tracked generated files. Restore them before committing. The initial Mac binary then trapped on `UniFFI API checksum mismatch`; rebuilding both the framework and generated bindings from the same snapshot fixed it.

The Apple device evaluation exposed four additional operational constraints:

4. Passcode lock prevents CoreDevice DDI mounting and process control: BushidoPhone remains locked, returning `CoreDeviceError error 12040: kAMDMobileImageMounterDeviceLocked: The device is locked.` This blocks developer disk image mounting, process listing, app installation, and launching.
5. CoreBluetooth TCC privacy gating: on physical iOS hardware, `CBCentralManager` and `CBPeripheralManager` report `.unauthorized` until a physical human operator taps Allow on the system BLE permission alert, or grants BLE access under Settings -> Privacy & Security. Headless automation cannot grant this permission.
6. BLE coexistence radio contention: `HopBleLab` (`sh.hopme.blelab`) was running on the handset, contending for the BLE L2CAP PSM. The dormant switch was asserted via `blelab://radio?enabled=false` to persist dormancy across relaunches.
7. Subnet isolation on USB link-local ethernet: Test iPhone XR is connected to the Mac via USB ethernet on interface `en27` (`169.254.52.86`), which answers ICMP ping. However, `NWListener` and `NWBrowser` advertise Bonjour `_hoplan._tcp` on Wi-Fi interface `en0[802.11]`. Because Test iPhone XR is kept off the local Wi-Fi LAN (10.4.1.0 subnet) where the Pixel 7 and Mac reside, mDNS discovery cannot cross between endpoints.
