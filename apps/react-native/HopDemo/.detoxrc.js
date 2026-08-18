// Detox configuration for the React Native HopDemo.
//
// The Android paths here are the ones actually produced on this machine: `./gradlew :app:assembleDebug`
// writes android/app/build/outputs/apk/debug/app-debug.apk, a 140 MB APK carrying libhop.so and
// libjnidispatch.so for all four ABIs. That build is verified.
//
// The iOS configuration is written but CANNOT run yet, and the reason is a defect rather than a missing
// step: sdk/react-native/ios/HopMesh.swift does `import Hop`, and HopMesh.podspec only supplies that
// module through `s.spm_dependency` guarded by `if s.respond_to?(:spm_dependency)`. Under CocoaPods 1.17.0
// that method does not exist, so the guard silently skips and `pod ipc spec HopMesh.podspec` evaluates to a
// spec with no SPM dependency at all. xcodebuild then fails with "unable to resolve module dependency:
// 'Hop'". Leaving the config here, accurate, so the suite runs the moment the SDK supplies the module.

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
      build:
        'cd android && ./gradlew :app:assembleDebug -DtestBuildType=debug --no-daemon',
      reversePorts: [8081],
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
    simulator: {
      type: 'ios.simulator',
      device: { type: process.env.DETOX_SIM_NAME || 'iPhone 16' },
    },
  },
  configurations: {
    'android.emu.debug': { device: 'emulator', app: 'android.debug' },
    'ios.sim.debug': { device: 'simulator', app: 'ios.debug' },
  },
};
