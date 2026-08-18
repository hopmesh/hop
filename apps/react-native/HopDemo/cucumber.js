// Cucumber configuration for the Detox-driven suite.
//
// IMPORTANT, about what gates what. `cucumber-js --dry-run` does NOT fail on an undefined step: measured
// on cucumber-js 11.3.0, an undefined step prints "Undefined" and still exits 0, and adding `strict` in
// this config or `--strict` on the command line does not change that. So the dry run is INFORMATIONAL.
// The real gate is e2e/testids.test.js, which fails (rc=1) when a step definition is missing or an app
// testID is renamed, and which was proven to fail in both directions by sabotage.
//
// Default profile excludes @multi-device, because those scenarios need two or three physical phones and
// would otherwise report as failures on an emulator. They are not deleted: `npm run e2e:multi` lists them
// with their hardware requirements so a manual run has a checklist.
module.exports = {
  default: {
    require: ['e2e/support/**/*.js', 'e2e/steps/**/*.js'],
    paths: ['e2e/features/**/*.feature'],
    tags: 'not @multi-device',
    format: ['progress-bar', 'summary'],
    formatOptions: { snippetInterface: 'async-await' },
    timeout: 120000,
  },
  smoke: {
    require: ['e2e/support/**/*.js', 'e2e/steps/**/*.js'],
    paths: ['e2e/features/**/*.feature'],
    tags: '@smoke and not @multi-device',
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
};
