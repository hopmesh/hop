// Pre-flight gate for the on-device suite. Runs in seconds and refuses to let a long run start against a
// broken app.
//
// WHY THIS EXISTS. A 25-minute, 9-scenario Detox run once failed every single scenario for one reason: the
// Metro bundler on the host had died, so the debug APK had no JS to load and the phone showed a red
// "Unable to load script" screen for the whole run. Detox reported step failures that read like product
// bugs. Nothing in the suite could see the red box, because a LogBox error is not an element a matcher asks
// about. So verification now runs cheap-to-expensive: prove the app RENDERS, then spend minutes on scenarios.
//
// This gate deliberately does NOT require Metro. An app that only works while a workstation daemon is alive
// is not deployed; the APK under test should carry its own bundle (see `bundleInDebug` in
// android/app/build.gradle). Metro is reported if present, and its absence is not a failure.
//
// Usage: node e2e/preflight.mjs   (exit 0 = safe to run the suite)

import {execFileSync} from 'node:child_process';

const SERIAL = process.env.DETOX_ADB_NAME || '';
const PKG = 'com.hopdemo';
const PORT = process.env.RCT_METRO_PORT || '8081';

const fail = (msg) => {
  console.error(`preflight FAILED: ${msg}`);
  process.exit(1);
};

if (!SERIAL) {
  fail('DETOX_ADB_NAME is not set, so there is no device to check. Export the adb serial.');
}
const adb = (args, opts = {}) =>
  execFileSync('adb', ['-s', SERIAL, ...args], {encoding: 'utf8', ...opts});

// Metro is optional: reported for information, never required. If it IS running, wire the tunnel so a
// Metro-backed build can reach it too.
try {
  const res = await fetch(`http://localhost:${PORT}/status`, {signal: AbortSignal.timeout(3000)});
  const status = (await res.text()).trim();
  console.log(`  metro: ${status || 'answered, empty body'}`);
  adb(['reverse', `tcp:${PORT}`, `tcp:${PORT}`]);
} catch (e) {
  console.log('  metro: not running (fine for an embedded-bundle build)');
}

// Wake, unobstruct, and relaunch, so what follows is a real cold start rather than a stale screen.
adb(['shell', 'input', 'keyevent', 'KEYCODE_WAKEUP']);
adb(['shell', 'cmd', 'statusbar', 'collapse']);
adb(['shell', 'wm', 'dismiss-keyguard']);
adb(['logcat', '-c']);
adb(['shell', 'am', 'force-stop', PKG]);
adb(['shell', 'am', 'start', '-n', `${PKG}/.MainActivity`], {stdio: 'ignore'});

// Watch for the two outcomes that matter and stop at the FIRST: a bundle-load failure (the red box), or the
// first screen rendering. Polling uiautomator rather than Detox keeps this independent of the framework
// whose runs it gates.
const deadline = Date.now() + 45000;
let redbox = null;
let rendered = false;
while (Date.now() < deadline) {
  await new Promise((r) => setTimeout(r, 2500));

  const log = adb(['logcat', '-d']);
  const hit = log
    .split('\n')
    .find((l) =>
      /Unable to load script|Could not connect to development server|Unable to resolve module/i.test(l),
    );
  if (hit) {
    redbox = hit.trim();
    break;
  }

  try {
    adb(['shell', 'uiautomator', 'dump', '/sdcard/preflight.xml'], {stdio: 'ignore'});
    const xml = adb(['shell', 'cat', '/sdcard/preflight.xml']);
    if (xml.includes('peers-list') || xml.includes('own-address')) {
      rendered = true;
      break;
    }
  } catch (e) {
    // The activity may not be up yet; keep polling until the deadline.
  }
}

if (redbox) {
  fail(
    'the app could not load its JS bundle, which is the red screen a human sees and no matcher can:\n' +
      `    ${redbox}\n` +
      '    If this build expects Metro, start it. If it should be standalone, rebuild with bundleInDebug.',
  );
}
if (!rendered) {
  fail(
    'the app launched but its first screen never rendered within 45s (no peers-list and no own-address in ' +
      'the view hierarchy). Do not start the suite: every scenario would fail on the Background step.',
  );
}

console.log('  app rendered its first screen');
console.log('preflight OK');
