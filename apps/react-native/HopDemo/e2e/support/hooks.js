// Detox lifecycle wired into Cucumber.
//
// Detox is normally driven by its own Jest runner. With Cucumber the lifecycle has to be explicit: init
// once for the run, relaunch the app before each scenario so scenarios cannot leak state into each other,
// and clean up at the end.
//
// The relaunch is deliberate rather than cheap. This app opens two Hop nodes and pairs them over a
// loopback bearer, so a scenario that sent a message leaves peers connected and messages on screen. Reusing
// that state would let a later scenario pass on residue from an earlier one.
//
// Detox 20.28 split its entry points. `require('detox')` now returns the CLIENT API only (device, element,
// expect, by, waitFor); the LIFECYCLE API (init, cleanup, installWorker) lives at `detox/internals`. The
// old `detox.init(config, { initGlobals: true })` shape fails here with "detox.init is not a function"
// because init is a Symbol-keyed method on the context, exported explicitly only via the internals entry.
// The steps import the client API from 'detox' directly, which is why they never needed globals.

const { BeforeAll, AfterAll, Before, After, setDefaultTimeout } = require('@cucumber/cucumber');
const detox = require('detox');
const { init: detoxInit, cleanup: detoxCleanup } = require('detox/internals');

setDefaultTimeout(120000);

BeforeAll({ timeout: 300000 }, async () => {
  // No config argument, unlike the pre-20.28 API. Under `detox test` the CLI resolves .detoxrc.js, starts
  // the IPC server, and hands this process the resolved session via DETOX_CONFIG_SNAPSHOT_PATH; init()
  // connects to that session and installs the worker, which allocates the device from the configuration
  // the CLI already selected.
  await detoxInit();
});

Before({ timeout: 120000 }, async () => {
  // A fresh launch per scenario. delete:true wipes app data so identity and peers start clean.
  await detox.device.launchApp({ newInstance: true, delete: true });
});

After({ timeout: 60000 }, async function (scenario) {
  // Capture a screenshot for anything that did not pass, named after the scenario, so a failure comes with
  // evidence instead of a bare matcher message.
  if (scenario.result && scenario.result.status !== 'PASSED') {
    const safe = scenario.pickle.name.replace(/[^a-z0-9]+/gi, '-').toLowerCase();
    try {
      await detox.device.takeScreenshot(`failed-${safe}`);
    } catch (e) {
      // A screenshot failure must never mask the real scenario failure.
    }
  }
});

AfterAll({ timeout: 120000 }, async () => {
  await detoxCleanup();
});
