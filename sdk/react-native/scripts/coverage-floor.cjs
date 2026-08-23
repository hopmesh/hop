#!/usr/bin/env node
"use strict";
// Run the test suite under coverage and fail if it drops below the floor.
//
// THE NUMBERS BELOW ARE A RATCHET, NOT A TARGET, and specifically not an endorsement. They are the
// coverage this package HAPPENED to have when it was last measured, measured rather than chosen. Raise
// them when you add tests. Do not lower them to make a red build green.
//
// They started at 80.33% line, 90.91% branch, 45.28% function, where function coverage at 45% meant
// roughly half the HopNode surface was never called by any test. Binding the section 19 relay pool and
// the hps:// pub/sub surface came with a test per bridged call, which took the measurement to 87.23%
// line, 93.97% branch, 63.75% function. About a third of the surface is still uncalled, mostly the
// thin one-line pass-throughs on the older identity and bearer-seam methods. That is a known gap,
// written down here so it cannot quietly get worse while nobody is looking.
//
// Why a script instead of node's own thresholds: --test-coverage-lines and friends landed after Node
// 20, and the CI action pins node 20.20.2. Parsing the summary keeps the floor working on the version
// CI actually runs, rather than silently doing nothing there.

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const FLOORS = { line: 87.0, branch: 93.0, function: 63.0 };

const pkg = path.resolve(__dirname, "..");
const result = spawnSync(
  process.execPath,
  ["--test", "--experimental-test-coverage", "test/base64.test.cjs", "test/node.test.cjs"],
  { cwd: pkg, encoding: "utf8" }
);

const output = `${result.stdout || ""}${result.stderr || ""}`;
process.stdout.write(output);

if (result.status !== 0) {
  console.error("\ncoverage floor: the test suite itself failed; fix that before reading coverage");
  process.exit(result.status === null ? 1 : result.status);
}

// The summary row looks like:  ℹ all files      |  80.33 |    90.91 |   45.28 |
const summary = output
  .split("\n")
  .map((line) => line.replace(/^\s*[^\w|]*\s*/, ""))
  .find((line) => line.startsWith("all files"));

if (!summary) {
  // A missing summary is an unknown, never a pass. If node changes its coverage output shape this
  // must go red and be fixed, not silently stop enforcing anything.
  console.error(
    "\ncoverage floor: could not find the 'all files' summary row in the coverage report.\n" +
      "The report format changed, or coverage did not run. Refusing to report success."
  );
  process.exit(1);
}

const numbers = summary.match(/(\d+(?:\.\d+)?)/g);
if (!numbers || numbers.length < 3) {
  console.error(`\ncoverage floor: could not parse percentages from: ${summary}`);
  process.exit(1);
}

const actual = {
  line: Number(numbers[0]),
  branch: Number(numbers[1]),
  function: Number(numbers[2]),
};

let failed = false;
console.log("\ncoverage floor:");
for (const metric of ["line", "branch", "function"]) {
  const value = actual[metric];
  const floor = FLOORS[metric];
  const ok = value >= floor;
  if (!ok) failed = true;
  console.log(
    `  ${metric.padEnd(9)} ${value.toFixed(2).padStart(6)}%  floor ${floor.toFixed(2)}%  ${ok ? "ok" : "BELOW FLOOR"}`
  );
}

if (failed) {
  console.error(
    "\ncoverage floor: coverage fell below the ratchet. Add tests rather than lowering the floor."
  );
  process.exit(1);
}
console.log("coverage floor: ok");
