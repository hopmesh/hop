// Detox lifecycle wired into Cucumber.
//
// Detox is normally driven by its own Jest runner. With Cucumber the lifecycle has to be explicit: init
// once for the run, relaunch the app before each scenario so scenarios cannot leak state into each other,
// and clean up at the end.
//
// The relaunch is deliberate rather than cheap. This app opens two Hop nodes and pairs them over a
// loopback bearer, so a scenario that sent a message leaves peers connected and messages on screen. Reusing
// that state would let a later scenario pass on residue from an earlier one.

const { BeforeAll, AfterAll, Before, After, setDefaultTimeout } = require('@cucumber/cucumber');
const detox = require('detox');
const config = require('../../.detoxrc');

setDefaultTimeout(120000);

BeforeAll({ timeout: 300000 }, async () => {
  await detox.init(config, { initGlobals: true });
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
  await detox.cleanup();
});
