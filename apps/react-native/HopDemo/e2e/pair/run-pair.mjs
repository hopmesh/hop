#!/usr/bin/env node
// Runs the @device-pair scenarios on TWO targets at once.
//
// WHY THIS EXISTS. Detox drives one app instance per process: `detox.device` is a singleton and
// `detox.init` attaches to a single target. There is no supported way to drive two devices from one Detox
// run, so a two-device scenario is two coordinated runs. This script is that coordination: it validates the
// targets, optionally starts a local relay, points each device at a URL it can actually reach, creates the
// rendezvous directory the two processes agree through, spawns both Detox runs, interleaves their output,
// and fails if either side fails.
//
// It refuses rather than degrades. An unreachable device, a missing serial, an unreachable relay: each stops
// the run with a message naming what was wrong. Nothing here falls back to a single device, because a
// single-device run cannot prove anything this scenario claims.
//
// Usage, from apps/react-native/HopDemo:
//
//   node e2e/pair/run-pair.mjs --a android.attached.debug --b android.emu.debug \
//     --adb 1A2B3C4D --avd Pixel_6a_API_34 --relay local
//
//   --a / --b        Detox configuration per side (see .detoxrc.js)
//   --sender a|b     which side sends (default a); swap it to prove the other direction
//   --relay          `local` to start hop-relayd here, or a full ws:// / wss:// URL to use as is
//   --relay-port     port for `--relay local` (default 8080)
//   --adb            serial for an android.attached target, validated against `adb devices`
//   --avd            AVD name for an android.emulator target
//   --sim            simulator name for an ios.simulator target
//   --no-metro       do not start Metro; assume something is already serving 8081
//   --reuse          pass --reuse to Detox, skipping reinstall

import {spawn, spawnSync} from 'node:child_process';
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const argv = process.argv.slice(2);
const flag = (name, fallback = null) => {
  const i = argv.indexOf(`--${name}`);
  return i === -1 ? fallback : argv[i + 1];
};
const has = (name) => argv.includes(`--${name}`);

const die = (msg) => {
  console.error(`\nrun-pair: ${msg}\n`);
  process.exit(2);
};

const A = flag('a', 'android.attached.debug');
const B = flag('b', 'android.emu.debug');
const SENDER = flag('sender', 'a');
if (!['a', 'b'].includes(SENDER)) die('--sender must be a or b');
const RELAY = flag('relay', 'local');
const RELAY_PORT = Number(flag('relay-port', '8080'));
const ADB_SERIAL = flag('adb', process.env.DETOX_ADB_NAME || null);
const AVD = flag('avd', process.env.DETOX_AVD_NAME || null);
const SIM = flag('sim', process.env.DETOX_SIM_NAME || null);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- target validation ---------------------------------------------------------------------------------

const adbPath = () => {
  const home = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT;
  return home ? path.join(home, 'platform-tools', 'adb') : 'adb';
};

// `adb devices` prints one "serial<TAB>state" line per device. Only `device` is usable: `unauthorized`
// means the USB debugging prompt was never accepted, and `offline` means the daemon lost it.
const attachedSerials = () => {
  const r = spawnSync(adbPath(), ['devices'], {encoding: 'utf8'});
  if (r.status !== 0) {
    die(`\`adb devices\` failed (${r.status}). ${String(r.stderr || '').trim()}`);
  }
  return r.stdout
    .split('\n')
    .slice(1)
    .map((l) => l.trim().split(/\s+/))
    .filter((p) => p.length === 2)
    .map(([serial, state]) => ({serial, state}));
};

const kindOf = (config) => {
  if (config.includes('attached')) return 'android.attached';
  if (config.includes('emu')) return 'android.emulator';
  if (config.includes('sim')) return 'ios.simulator';
  if (config.includes('ios.device')) return 'ios.device';
  return die(`cannot tell what kind of target ${config} is`);
};

const validate = (side, config) => {
  const kind = kindOf(config);
  if (kind === 'android.attached') {
    if (!ADB_SERIAL) {
      die(
        `side ${side} is ${config}, which needs a physical phone, but no serial was given. Pass --adb ` +
          `<serial>. Attached now: ${JSON.stringify(attachedSerials())}`,
      );
    }
    const found = attachedSerials().find((d) => d.serial === ADB_SERIAL);
    if (!found) {
      die(
        `--adb ${ADB_SERIAL} is not attached. \`adb devices\` reports ` +
          `${JSON.stringify(attachedSerials())}.`,
      );
    }
    if (found.state !== 'device') {
      die(
        `--adb ${ADB_SERIAL} is in state ${found.state}, not device. unauthorized means the USB debugging ` +
          'prompt on the phone was not accepted; offline means adb lost it, try unplugging it.',
      );
    }
    return {kind, label: `${ADB_SERIAL} (attached Android)`};
  }
  if (kind === 'android.emulator') {
    if (!AVD) die(`side ${side} is ${config} and needs --avd <name>`);
    return {kind, label: `${AVD} (Android emulator)`};
  }
  if (kind === 'ios.simulator') {
    return {kind, label: `${SIM || 'default simulator'} (iOS simulator)`};
  }
  return {kind, label: config};
};

// --- relay ---------------------------------------------------------------------------------------------

const repoRoot = () => path.resolve(process.cwd(), '..', '..', '..');

const portAnswers = (port, host = '127.0.0.1') =>
  new Promise((resolve) => {
    const s = net.connect({port, host});
    const done = (v) => {
      s.destroy();
      resolve(v);
    };
    s.setTimeout(1000);
    s.once('connect', () => done(true));
    s.once('timeout', () => done(false));
    s.once('error', () => done(false));
  });

// relayd peek-classifies on the WS port, so /healthz on the same port answers plain HTTP. It reports 503
// until the driver loop has ticked once, so any status line means the daemon is serving.
const healthz = (port) =>
  new Promise((resolve) => {
    const s = net.connect({port, host: '127.0.0.1'});
    let buf = '';
    s.setTimeout(2000);
    s.once('connect', () => s.write(`GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n`));
    s.on('data', (d) => {
      buf += d.toString();
      if (buf.includes('\r\n')) {
        s.destroy();
        resolve(buf.split('\r\n')[0]);
      }
    });
    const fail = () => {
      s.destroy();
      resolve(null);
    };
    s.once('timeout', fail);
    s.once('error', fail);
    s.once('close', () => resolve(buf ? buf.split('\r\n')[0] : null));
  });

const startLocalRelay = async () => {
  if (await portAnswers(RELAY_PORT)) {
    die(
      `port ${RELAY_PORT} is already in use, so --relay local cannot bind it. Stop whatever is on it, or ` +
        `pass --relay-port. If you already have a relay there, pass --relay ws://127.0.0.1:${RELAY_PORT}/ ` +
        'instead and this script will use it as is.',
    );
  }
  const db = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'hop-pair-relay-')), 'relay.db');
  console.log(`run-pair: starting hop-relayd on ws 0.0.0.0:${RELAY_PORT}, db ${db}`);
  const child = spawn(
    'cargo',
    ['run', '-q', '--release', '-p', 'hop-relayd', '--', '--ws', `0.0.0.0:${RELAY_PORT}`, '--db', db],
    {cwd: repoRoot(), stdio: ['ignore', 'pipe', 'pipe']},
  );
  child.stdout.on('data', (d) => process.stdout.write(`[relayd] ${d}`));
  child.stderr.on('data', (d) => process.stderr.write(`[relayd] ${d}`));
  child.on('exit', (code) => {
    if (code !== null && code !== 0) console.error(`[relayd] exited ${code}`);
  });

  for (let i = 0; i < 120; i += 1) {
    const line = await healthz(RELAY_PORT);
    if (line) {
      console.log(`run-pair: relayd is serving, /healthz says ${JSON.stringify(line)}`);
      return child;
    }
    if (child.exitCode !== null) die(`hop-relayd exited ${child.exitCode} before it served`);
    await sleep(500);
  }
  child.kill('SIGTERM');
  return die(`hop-relayd never answered /healthz on ${RELAY_PORT}`);
};

/**
 * The URL a given target can actually reach the host on. This differs per device and getting it wrong is
 * the single most likely reason a pair run stalls at `connecting`:
 *   attached phone    loopback works only because we `adb reverse` the port over USB
 *   emulator          10.0.2.2 is the emulator's alias for the host loopback
 *   iOS simulator     shares the host network stack, so plain loopback
 */
const urlFor = (kind, port) => {
  if (kind === 'android.emulator') return `ws://10.0.2.2:${port}/`;
  return `ws://127.0.0.1:${port}/`;
};

const adbReverse = (serial, port) => {
  const r = spawnSync(adbPath(), ['-s', serial, 'reverse', `tcp:${port}`, `tcp:${port}`], {
    encoding: 'utf8',
  });
  if (r.status !== 0) {
    die(
      `\`adb -s ${serial} reverse tcp:${port} tcp:${port}\` failed: ${String(r.stderr || r.stdout).trim()}. ` +
        'Without it the phone cannot reach a relay on this machine over USB.',
    );
  }
  console.log(`run-pair: adb reverse tcp:${port} on ${serial}, so the phone reaches the host on loopback`);
};

// Espresso waits for the root of the view hierarchy to have window focus, and an open notification shade
// holds focus instead: every scenario then fails with "Waited for the root of the view hierarchy to have
// window focus ... has-window-focus=false" while dumpsys reports mCurrentFocus=NotificationShade even
// though mFocusedApp is the app under test. Measured on a real phone, where an open shade is ordinary.
// Collapse it before handing the device to Detox, and dismiss the keyguard, which fails the same way for
// the same reason.
const settleDevice = (serial) => {
  for (const args of [
    ['shell', 'cmd', 'statusbar', 'collapse'],
    ['shell', 'wm', 'dismiss-keyguard'],
    // Keep the screen on for the run: a display that sleeps mid-run loses window focus too.
    ['shell', 'svc', 'power', 'stayon', 'true'],
  ]) {
    const r = spawnSync(adbPath(), ['-s', serial, ...args], {encoding: 'utf8'});
    if (r.status !== 0) {
      console.log(`run-pair: note, \`adb ${args.join(' ')}\` on ${serial} returned ${r.status}`);
    }
  }
};

// --- metro -------------------------------------------------------------------------------------------

const startMetro = async () => {
  if (await portAnswers(8081)) {
    console.log('run-pair: something is already serving 8081, using it as Metro');
    return null;
  }
  console.log('run-pair: starting Metro on 8081');
  const child = spawn('npx', ['react-native', 'start'], {stdio: ['ignore', 'pipe', 'pipe']});
  child.stdout.on('data', (d) => process.stdout.write(`[metro] ${d}`));
  child.stderr.on('data', (d) => process.stderr.write(`[metro] ${d}`));
  for (let i = 0; i < 120; i += 1) {
    if (await portAnswers(8081)) {
      console.log('run-pair: Metro is up');
      return child;
    }
    if (child.exitCode !== null) die(`Metro exited ${child.exitCode}`);
    await sleep(500);
  }
  child.kill('SIGTERM');
  return die('Metro never came up on 8081');
};

// --- the run -----------------------------------------------------------------------------------------

const runSide = (side, config, env, prefix) =>
  new Promise((resolve) => {
    const args = ['detox', 'test', '-c', config];
    if (has('reuse')) args.push('--reuse');
    args.push('--', '--profile', 'pair');
    const child = spawn('npx', args, {env: {...process.env, ...env}, stdio: ['ignore', 'pipe', 'pipe']});
    const pipe = (stream, to) =>
      stream.on('data', (d) =>
        String(d)
          .split('\n')
          .filter((l) => l.length > 0)
          .forEach((l) => to.write(`${prefix} ${l}\n`)),
      );
    pipe(child.stdout, process.stdout);
    pipe(child.stderr, process.stderr);
    child.on('exit', (code) => resolve({side, config, code: code === null ? 1 : code}));
  });

const main = async () => {
  const infoA = validate('a', A);
  const infoB = validate('b', B);

  // Hand Detox a device that can actually take window focus.
  for (const info of [infoA, infoB]) {
    if (info.kind === 'android.attached') settleDevice(ADB_SERIAL);
  }

  const roleA = SENDER === 'a' ? 'sender' : 'receiver';
  const roleB = SENDER === 'a' ? 'receiver' : 'sender';

  let relayChild = null;
  let urlA;
  let urlB;
  if (RELAY === 'local') {
    relayChild = await startLocalRelay();
    urlA = urlFor(infoA.kind, RELAY_PORT);
    urlB = urlFor(infoB.kind, RELAY_PORT);
  } else {
    if (!/^wss?:\/\//.test(RELAY)) die(`--relay must be \`local\` or a ws:// / wss:// URL, got ${RELAY}`);
    urlA = RELAY;
    urlB = RELAY;
  }

  // A phone reaches a host port over USB only once it is reversed. Needed whenever ITS url is loopback,
  // which covers both `--relay local` and an explicitly passed loopback URL.
  for (const [info, url] of [
    [infoA, urlA],
    [infoB, urlB],
  ]) {
    if (info.kind === 'android.attached' && /\/\/(127\.0\.0\.1|localhost)[:/]/.test(url)) {
      adbReverse(ADB_SERIAL, new URL(url).port || (url.startsWith('wss') ? 443 : 80));
    }
  }

  const metroChild = has('no-metro') ? null : await startMetro();

  const runId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `hop-pair-${runId}-`));

  console.log('');
  console.log('run-pair: two Detox processes, one per device. Detox drives one app instance per process,');
  console.log('run-pair: so this is two coordinated runs agreeing through a directory, not one run.');
  console.log(`run-pair:   run id      ${runId}`);
  console.log(`run-pair:   rendezvous  ${dir}`);
  console.log(`run-pair:   side a      ${A}  ${infoA.label}  role=${roleA}  relay=${urlA}`);
  console.log(`run-pair:   side b      ${B}  ${infoB.label}  role=${roleB}  relay=${urlB}`);
  console.log('');

  const shared = {HOP_PAIR_DIR: dir, HOP_PAIR_RUN: runId};
  const envA = {
    ...shared,
    HOP_PAIR_ROLE: roleA,
    HOP_PAIR_RELAY_URL: urlA,
    HOP_PAIR_LABEL: infoA.label,
    HOP_PAIR_PEER_LABEL: infoB.label,
    DETOX_ADB_NAME: infoA.kind === 'android.attached' ? ADB_SERIAL : '',
    ...(AVD && infoA.kind === 'android.emulator' ? {DETOX_AVD_NAME: AVD} : {}),
    ...(SIM && infoA.kind === 'ios.simulator' ? {DETOX_SIM_NAME: SIM} : {}),
  };
  const envB = {
    ...shared,
    HOP_PAIR_ROLE: roleB,
    HOP_PAIR_RELAY_URL: urlB,
    HOP_PAIR_LABEL: infoB.label,
    HOP_PAIR_PEER_LABEL: infoA.label,
    DETOX_ADB_NAME: infoB.kind === 'android.attached' ? ADB_SERIAL : '',
    ...(AVD && infoB.kind === 'android.emulator' ? {DETOX_AVD_NAME: AVD} : {}),
    ...(SIM && infoB.kind === 'ios.simulator' ? {DETOX_SIM_NAME: SIM} : {}),
  };

  const results = await Promise.all([
    runSide('a', A, envA, '[a]'),
    runSide('b', B, envB, '[b]'),
  ]);

  // The rendezvous is the evidence trail: it records what each side observed, independently of how
  // cucumber summarised it.
  console.log('\nrun-pair: rendezvous contents, what each side actually recorded');
  for (const f of fs.readdirSync(dir).sort()) {
    if (f.endsWith('.tmp')) continue;
    console.log(`  ${f}: ${fs.readFileSync(path.join(dir, f), 'utf8').trim()}`);
  }

  if (relayChild) relayChild.kill('SIGTERM');
  if (metroChild) metroChild.kill('SIGTERM');

  const failed = results.filter((r) => r.code !== 0);
  console.log('');
  for (const r of results) {
    console.log(`run-pair: side ${r.side} (${r.config}) exit ${r.code}`);
  }
  if (failed.length > 0) {
    console.error(
      `\nrun-pair: FAILED. ${failed.length} of 2 sides failed. A pair run is only green when BOTH sides ` +
        'are, because one side passing while the other fails proves nothing crossed.',
    );
    process.exit(1);
  }
  console.log('\nrun-pair: PASSED on both devices.');
  process.exit(0);
};

main().catch((e) => die(e && e.stack ? e.stack : String(e)));
