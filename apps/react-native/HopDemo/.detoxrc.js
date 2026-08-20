// Detox configuration for the React Native HopDemo.
//
// The Android paths here are the ones actually produced on this machine: `./gradlew :app:assembleDebug`
// writes android/app/build/outputs/apk/debug/app-debug.apk, a 140 MB APK carrying libhop.so and
// libjnidispatch.so for all four ABIs. That build is verified.
//
// The iOS simulator configuration is kept because Detox can only drive a SIMULATOR on iOS: its device
// types are android.apk, android.attached, android.emulator, android.genycloud, ios.app and ios.simulator,
// with no physical-iOS type at all. Physical iPhone coverage therefore lives in e2e/two-device.sh, which
// reads the app's own console output instead. The older note here claimed the iOS build was blocked by
// HopMesh.podspec's `spm_dependency` guard silently skipping under CocoaPods 1.17; that is fixed. The
// Apple SDK now ships as three pods (CHop, HopContract, HopSDK) and device builds of both Debug and
// Release succeed.

/** @type {Detox.DetoxConfig} */
module.exports = {
  testRunner: {
    args: {
      $0: 'cucumber-js',
      config: 'cucumber.js',
    },
    jest: null,
  },
  apps: {
    'android.debug': {
      type: 'android.apk',
      binaryPath: 'android/app/build/outputs/apk/debug/app-debug.apk',
      // assembleAndroidTest is not optional: Detox runs inside the app as an instrumentation test, so
      // without the androidTest APK `detox test` fails before it reaches a scenario.
      build:
        'cd android && ./gradlew :app:assembleDebug :app:assembleAndroidTest -DtestBuildType=debug --no-daemon',
      reversePorts: [8081],
    },
    // The RELEASE app is what a person actually holds: an Android debug build keeps developer support on
    // and chases Metro at launch even with the bundle embedded, so it dies with the laptop's bundler.
    // Release has no dev server to reach for. The RN template signs release with the debug keystore,
    // which is why this needs no extra signing setup.
    'android.release': {
      type: 'android.apk',
      binaryPath: 'android/app/build/outputs/apk/release/app-release.apk',
      build:
        'cd android && ./gradlew :app:assembleRelease :app:assembleAndroidTest -DtestBuildType=release --no-daemon',
    },
    'ios.debug': {
      type: 'ios.app',
      binaryPath: 'ios/build/Build/Products/Debug-iphonesimulator/HopDemo.app',
      build:
        "cd ios && xcodebuild -workspace HopDemo.xcworkspace -scheme HopDemo -configuration Debug " +
        "-sdk iphonesimulator -derivedDataPath ./build",
    },
  },
  devices: {
    emulator: {
      type: 'android.emulator',
      device: { avdName: process.env.DETOX_AVD_NAME || 'Pixel_7_API_34' },
    },
    // A USB-attached physical Android phone. The serial is deliberately NOT defaulted: a hardcoded serial
    // would be one developer's phone, and a wrong one produces a confusing Detox error rather than a clear
    // one. e2e/pair/run-pair.mjs validates it against `adb devices` before spawning anything.
    attachedAndroid: {
      type: 'android.attached',
      device: { adbName: process.env.DETOX_ADB_NAME || '' },
    },
    simulator: {
      type: 'ios.simulator',
      device: { type: process.env.DETOX_SIM_NAME || 'iPhone 16' },
    },
  },
  configurations: {
    'android.emu.debug': { device: 'emulator', app: 'android.debug' },
    'android.attached.debug': { device: 'attachedAndroid', app: 'android.debug' },
    'ios.sim.debug': { device: 'simulator', app: 'ios.debug' },
    'android.attached.release': { device: 'attachedAndroid', app: 'android.release' },
  },
};
