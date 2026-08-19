// Cucumber configuration for the Detox-driven suite.
//
// IMPORTANT, about what gates what. `cucumber-js --dry-run` does NOT fail on an undefined step: measured
// on cucumber-js 11.3.0, an undefined step prints "Undefined" and still exits 0, and adding `strict` in
// this config or `--strict` on the command line does not change that. So the dry run is INFORMATIONAL.
// The real gate is e2e/testids.test.js, which fails (rc=1) when a step definition is missing or an app
// testID is renamed, and which was proven to fail in both directions by sabotage.
//
// Default profile excludes @multi-device AND @device-pair, so a developer with no hardware still gets a
// meaningful green run that never claimed to cover either.
//
// @multi-device needs BLE radios and up to three phones and can still not be driven at all: the React
// Native SDK ships no radio bearer. `npm run e2e:multi` lists those with their hardware requirements so a
// manual run has a checklist.
//
// @device-pair DOES assert, on two real devices through a real relay, and is run by `npm run e2e:pair`,
// which starts one Detox process per device because Detox drives one app instance per process. It is not
// in the default profile because it needs two reachable devices and a reachable relay; when those are
// absent it FAILS naming what was unreachable rather than skipping, which is only useful when a developer
// asked for it.
module.exports = {
  default: {
    require: ['e2e/support/**/*.js', 'e2e/steps/**/*.js'],
    paths: ['e2e/features/**/*.feature'],
    tags: 'not @multi-device and not @device-pair',
    format: ['progress-bar', 'summary'],
    formatOptions: { snippetInterface: 'async-await' },
    timeout: 120000,
  },
  smoke: {
    require: ['e2e/support/**/*.js', 'e2e/steps/**/*.js'],
    paths: ['e2e/features/**/*.feature'],
    tags: '@smoke and not @multi-device and not @device-pair',
    format: ['progress-bar', 'summary'],
    timeout: 120000,
  },
  multi: {
    require: ['e2e/support/**/*.js', 'e2e/steps/**/*.js'],
    paths: ['e2e/features/**/*.feature'],
    tags: '@multi-device',
    format: ['summary'],
    timeout: 120000,
  },
  // Driven by e2e/pair/run-pair.mjs, once per device, with HOP_PAIR_ROLE differing per process. Running
  // this profile by hand without that harness fails immediately: the rendezvous env is absent, and the
  // steps say so rather than skipping.
  pair: {
    require: ['e2e/support/**/*.js', 'e2e/steps/**/*.js'],
    paths: ['e2e/features/**/*.feature'],
    tags: '@device-pair',
    format: ['summary'],
    formatOptions: { snippetInterface: 'async-await' },
    timeout: 600000,
  },
};
