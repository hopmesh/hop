// Detox lifecycle wired into Cucumber.
//
// Detox normally ships its own Jest integration. With Cucumber the lifecycle has to be driven by hand, and
// the API to drive it with is `detox/internals`, NOT the `detox` main export. This file previously called
// `detox.init(config)` and `detox.device`, which do not exist on that export in Detox 20: the main entry
// exposes only the matcher surface (`device`, `element`, `by`, `expect`, `waitFor`), while `init`,
// `cleanup`, `onTestStart` and `onTestDone` live on `detox/internals`. The old shape failed at the first
// BeforeAll with "TypeError: detox.init is not a function", so the suite could never have run on a device;
// a cucumber --dry-run does not execute hooks, which is how that survived unnoticed.
//
// `detoxInternals.init()` resolves the configuration itself from the CLI invocation, so the config is not
// passed in here. It also installs the globals, which is why the steps can import from 'detox' directly.
//
// onTestStart / onTestDone are not optional bookkeeping. Detox uses them to bracket a test for artifacts
// and to decide whether the app needs relaunching, and skipping them makes device state leak between
// scenarios.

const {
  BeforeAll,
  AfterAll,
  Before,
  After,
  setDefaultTimeout,
} = require('@cucumber/cucumber');
const detoxInternals = require('detox/internals');
const {device} = require('detox');

setDefaultTimeout(120000);

// A scenario name is the closest thing Cucumber has to a test title. Outlines reuse the same name with
// different examples, so the example values are already interpolated into pickle.name by this point.
const titleOf = (scenario) => (scenario && scenario.pickle && scenario.pickle.name) || 'scenario';

BeforeAll({timeout: 600000}, async () => {
  await detoxInternals.init();
});

Before({timeout: 300000}, async function (scenario) {
  const title = titleOf(scenario);
  await detoxInternals.onTestStart({title, fullName: title, status: 'running'});
  // A fresh launch per scenario. delete:true wipes app data so identity and peers start clean: this app
  // opens two Hop nodes and pairs them over a loopback bearer, so a scenario that sent a message would
  // otherwise leave peers connected and messages on screen for the next one to pass on.
  await device.launchApp({newInstance: true, delete: true});
});

After({timeout: 300000}, async function (scenario) {
  const title = titleOf(scenario);
  const passed = scenario && scenario.result && scenario.result.status === 'PASSED';

  // Capture a screenshot for anything that did not pass, named after the scenario, so a failure comes with
  // evidence instead of a bare matcher message. A screenshot failure must never mask the real failure.
  if (!passed) {
    try {
      await device.takeScreenshot(`failed-${title.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}`);
    } catch (e) {
      // deliberately swallowed
    }
  }

  await detoxInternals.onTestDone({
    title,
    fullName: title,
    status: passed ? 'passed' : 'failed',
  });
});

AfterAll({timeout: 300000}, async () => {
  await detoxInternals.cleanup();
});
