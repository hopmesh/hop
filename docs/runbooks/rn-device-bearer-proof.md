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
```

Relevant output:

```text
34241FDH2004KR  device  product:panther model:Pixel_7 device:panther
BushidoPhone  0280AC9F-551E-55DA-A969-62D4242A003C  available (paired)  iPhone 17 Pro
Current device lock state:
passcodeRequired: true
unlockedSinceBoot: true
ERROR: ... CoreDeviceError error 12040 ... kAMDMobileImageMounterDeviceLocked: The device is locked.
```

BushidoPhone could not be launched or controlled, so the BLE pass used the Pixel 7 and a Mac-side node. The unlocked Test iPhone XR was also inspected for LAN, but it is the fleet's BLE-only handset and did not advertise a LAN service to the Pixel. No Pixel to BushidoPhone claim is made.

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

Delivery remained blocked. Two Mac-to-Pixel attempts discovered the Pixel through mDNS, then every native TCP dial timed out. A third attempt selected a lower Mac transport ID so the Pixel became the tiebreak dialer; the Pixel discovered the Mac and its native dial also timed out. The representative evidence is:

```text
2026-09-09 00:48:17.337 ... HOPLAB 0.009 STATE lan discovered peer=5a4f0430 -> DIAL
2026-09-09 00:48:25.338 ... HOPLAB 8.010 STATE lan link-down (connect timeout) peer=???????? isDialer=true
09-09 00:55:25.557 ... HOPLOG: lan discovered peer=40cc9c1b -> DIAL
09-09 00:55:30.602 HOPLOG: lan dial failed peer=40cc9c1b: failed to connect to /10.4.1.221 (port 60523) from /10.4.1.203 ... after 5000ms
2026-09-09T06:49:47Z RNMAC timeout bearer=lan nonce=rn_lan_20260909T064810Z_c2 sent=true states=["BT": false, "P2P": false, "LAN": true, "LoRa": false] active=[:]
```

The two hosts were on the same 10.4.1.0/24 subnet and passed ICMP both ways. macOS Local Network privacy was not the cause: unified logs showed the RnMacPeer path as satisfied and its listener inbox active on `en0`, with no privacy denial. A direct probe to that exact listener discriminated by Android UID:

```text
RnMacPeer 98118 ... TCP *:60524 (LISTEN)
mac-loopback: connected, rc=0
Pixel shell UID to 10.4.1.221:60524: rc=0
Pixel com.hopdemo UID to 10.4.1.221:60524: nc: Timeout, rc=1
```

`NEARBY_WIFI_DEVICES` was then declared in the merged manifest, the rebuilt APK was installed, `pm grant` succeeded, and appops reported `NEARBY_WIFI_DEVICES: allow`. The same native LAN attempt still failed:

```text
09-09 01:27:16.676 ... HOPLOG: lan discovered peer=4fbcb79e -> DIAL
09-09 01:27:21.722 ... HOPLOG: lan dial failed peer=4fbcb79e: failed to connect to /10.4.1.221 (port 60525) from /10.4.1.203 (port 34896) after 5000ms
2026-09-09T07:28:44Z RNMAC timeout bearer=lan nonce=rn_lan_20260909T072700Z_d1 sent=true states=["BT": false, "P2P": false, "LoRa": false, "LAN": true] active=[:]
```

That rerun falsified the missing-permission hypothesis, so the temporary permission declaration was not retained. Both native listeners bind, mDNS resolves, and the Mac Network.framework path is satisfied, but the React Native app path never completes TCP. No receiver line or sender ACK exists for any LAN nonce, so LAN remains blocked on a Hop app-path defect and is not reported as exercised.

## Failure modes found by this run

The first full app assembly exposed three consumer constraints that module compilation had not:

1. An exact `includeGroup "sh.hop"` filter excluded `sh.hop.bearers` and produced `Could not find sh.hop.bearers:bearer-ble:0.0.3` plus the LAN equivalent.
2. The module emitted Kotlin 2.4.0 metadata while the app compiler expected 2.2.0: `Module was compiled with an incompatible version of Kotlin. The binary version of its metadata is 2.4.0, expected version is 2.2.0.`
3. The demo declared `minSdk 24`, but BLE uses `listenUsingInsecureL2capChannel()` and `createInsecureL2capChannel()`, which first appear in API 29. Manifest merge failed with `uses-sdk:minSdkVersion 24 cannot be smaller than version 29 declared in library [sh.hop.bearers:bearer-ble:0.0.3]`.

The documented Apple build also changed ten tracked generated files. Restore them before committing. The initial Mac binary then trapped on `UniFFI API checksum mismatch`; rebuilding both the framework and generated bindings from the same snapshot fixed it.
