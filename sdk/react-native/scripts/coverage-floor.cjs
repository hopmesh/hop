#!/usr/bin/env node
"use strict";
// Run the test suite under coverage and fail if it drops below the floor.
//
// THE NUMBERS BELOW ARE A RATCHET, NOT A TARGET, and specifically not an endorsement. They are the
// coverage this package HAPPENED to have when the floor was introduced, measured rather than chosen:
// 80.33% line, 90.91% branch, 45.28% function. Function coverage at 45% means roughly half the HopNode
// surface, mostly the thin one-line pass-throughs, is never called by any test. That is a known gap,
// written down here so it cannot quietly get worse while nobody is looking. Raise these when you add
// tests. Do not lower them to make a red build green.
//
// THE FLOOR IS DELIBERATELY BELOW WHAT CI REPORTS, so do not "correct" it upward to match a green
// run. Node's coverage attribution differs by version: the same suite and the same sources measure
// 80.33 / 90.91 / 45.28 on Node 26 locally and 88.01 / 93.28 / 54.46 on the Node 20.20.2 that CI
// pins. The floor has to be the LOWER of the versions this package is run on, or a developer on a
// newer Node fails a floor derived from CI while having changed nothing. Raise it only when the
// lowest measurement across supported Node versions rises.
//
// Why a script instead of node's own thresholds: --test-coverage-lines and friends landed after Node
// 20, and the CI action pins node 20.20.2. Parsing the summary keeps the floor working on the version
// CI actually runs, rather than silently doing nothing there.

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const FLOORS = { line: 80.0, branch: 90.0, function: 45.0 };

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
