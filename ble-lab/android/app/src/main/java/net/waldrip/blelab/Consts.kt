package net.waldrip.blelab

// The all-in-one Ble.kt used to define this top-level TAG. After the transport moved into the
// :bearers module, the app's own components (BleService, MainActivity, AnchorWatchdogReceiver,
// ProofSink) still log under the same HOPLOG tag, so `adb logcat -s HOPLOG` keeps working end-to-end
// (the module logs under its own internal "HOPLOG" tag too).
const val TAG = "HOPLOG"
