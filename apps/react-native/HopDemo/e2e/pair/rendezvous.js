// File-based rendezvous between the two Detox processes of a @device-pair run.
//
// WHY A FILE AND NOT A SOCKET. Detox drives exactly one app instance per process: `detox.device` is a
// singleton and `detox.init` attaches to a single target, so two devices means two processes. Those two
// processes must agree on three things at runtime: that both actually started, what each device's Hop
// address is, and whether the receiving device saw the bytes. A directory of atomically renamed files is
// the smallest thing that survives two processes started by one parent, needs no port, and leaves the
// whole exchange on disk afterwards as evidence of what each side observed.
//
// Every wait here FAILS on timeout and names what it was waiting for. None of them returns a default or
// resolves early, because a @device-pair scenario that proceeded on a missing address would assert against
// whatever happened to be on screen.

const fs = require('fs');
const path = require('path');

const POLL_MS = 250;

const ROLES = ['sender', 'receiver'];

/** The run's shared directory. Absent means this scenario was run outside the pair harness. */
const dir = () => {
  const d = process.env.HOP_PAIR_DIR;
  if (!d) {
    throw new Error(
      'HOP_PAIR_DIR is not set, so there is no rendezvous and no second device. @device-pair scenarios ' +
        'are excluded from the default profile on purpose: run them with `npm run e2e:pair`, which ' +
        'creates the rendezvous and starts one Detox process per device.',
    );
  }
  return d;
};

/** Which half of the pair this process is driving. */
const role = () => {
  const r = process.env.HOP_PAIR_ROLE;
  if (!ROLES.includes(r)) {
    throw new Error(
      `HOP_PAIR_ROLE must be one of ${ROLES.join(', ')}, got ${JSON.stringify(r)}. The pair harness sets ` +
        'this per process; a scenario cannot decide its own role.',
    );
  }
  return r;
};

const otherRole = () => (role() === 'sender' ? 'receiver' : 'sender');

/** A human label for this device, so a red run names the hardware rather than a role word. */
const label = (which = role()) =>
  (which === role() ? process.env.HOP_PAIR_LABEL : process.env.HOP_PAIR_PEER_LABEL) || which;

/** The relay URL THIS device should dial. The two sides can legitimately differ: a USB-attached phone
 *  reaches the host over `adb reverse` on loopback while an emulator reaches it as 10.0.2.2. */
const relayUrl = () => {
  const u = process.env.HOP_PAIR_RELAY_URL;
  if (!u) {
    throw new Error('HOP_PAIR_RELAY_URL is not set. The pair harness sets one URL per device.');
  }
  return u;
};

/** Identifies this run, so an assertion cannot be satisfied by residue from an earlier one. */
const runId = () => {
  const r = process.env.HOP_PAIR_RUN;
  if (!r) {
    throw new Error('HOP_PAIR_RUN is not set. The pair harness generates one id per run.');
  }
  return r;
};

// Rename is atomic within a directory, so a reader never observes a half-written file.
const put = (name, text) => {
  const target = path.join(dir(), name);
  const tmp = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, text);
  fs.renameSync(tmp, target);
};

const peek = (name) => {
  try {
    return fs.readFileSync(path.join(dir(), name), 'utf8');
  } catch (e) {
    if (e.code === 'ENOENT') return null;
    throw e;
  }
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Poll until `read()` yields something, or throw naming what was missing. `extra()` adds live detail to
 * the timeout message, which is how a stalled pair explains itself instead of reporting a bare timeout.
 */
const waitFor = async (what, read, timeoutMs, extra = () => '') => {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const v = await read();
    if (v !== null && v !== undefined) return v;
    if (Date.now() >= deadline) {
      const detail = extra();
      throw new Error(
        `timed out after ${Math.round(timeoutMs / 1000)}s waiting for ${what}` +
          (detail ? `. ${detail}` : ''),
      );
    }
    await sleep(POLL_MS);
  }
};

// --- the things the two processes must agree on ----------------------------------------------------------

/** Announce this process, then wait until the other one has announced too. */
const meet = async (timeoutMs) => {
  put(`role-${role()}.json`, JSON.stringify({role: role(), pid: process.pid, label: label()}));
  await waitFor(
    `the ${otherRole()} process to start (${label(otherRole())})`,
    () => peek(`role-${otherRole()}.json`),
    timeoutMs,
    () =>
      'Only one half of the pair reached the rendezvous. An unreachable device makes its process exit ' +
      'before this point, so check the other side of the interleaved log for a Detox startup failure.',
  );
};

const publishAddress = (addr) => put(`addr-${role()}.txt`, addr);

const peerAddress = async (timeoutMs) => {
  const addr = await waitFor(
    `the ${otherRole()}'s Hop address`,
    () => peek(`addr-${otherRole()}.txt`),
    timeoutMs,
    () => `The ${otherRole()} publishes it once its own-address element renders.`,
  );
  return addr.trim();
};

/** The sender records each attempt so a receiver failure can say how many sends it did not see. */
const recordSend = (attempt, body) =>
  put('sent.json', JSON.stringify({attempt, body, at: new Date().toISOString()}));

const sendAttempts = () => {
  const raw = peek('sent.json');
  return raw ? JSON.parse(raw) : null;
};

const waitForFirstSend = (timeoutMs) =>
  waitFor('the sender to report its first send', () => sendAttempts(), timeoutMs);

/** The receiver's verdict decides the scenario; the sender reads it and adopts it, so neither side can
 *  report green while the other reports red. */
const putVerdict = (ok, detail) =>
  put(`verdict-${role()}.json`, JSON.stringify({role: role(), ok, detail, at: new Date().toISOString()}));

const verdict = (which) => {
  const raw = peek(`verdict-${which}.json`);
  return raw ? JSON.parse(raw) : null;
};

const waitForVerdict = (which, timeoutMs, extra) =>
  waitFor(`the ${which}'s verdict`, () => verdict(which), timeoutMs, extra);

module.exports = {
  ROLES,
  dir,
  role,
  otherRole,
  label,
  relayUrl,
  runId,
  sleep,
  waitFor,
  meet,
  publishAddress,
  peerAddress,
  recordSend,
  sendAttempts,
  waitForFirstSend,
  putVerdict,
  verdict,
  waitForVerdict,
};
