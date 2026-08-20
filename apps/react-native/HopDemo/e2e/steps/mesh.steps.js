// Step definitions for e2e/features/mesh.feature.
//
// Steps are written against the app's stable testIDs, never against copy or screen position, because
// copy changes. Every testID used here is asserted to exist in App.tsx by e2e/testids.test.js, so a
// rename breaks a fast unit test instead of a slow device run. That guard already caught two real drifts
// while this file was being written: the bearer notice is `bearer-note`, not `discovery-unavailable`, and
// peer rows were keyed by address, which a test cannot know before the row renders.
//
// The @multi-device steps deliberately do NOT assert. They throw a pending error naming the hardware they
// need. A scenario that quietly returned success while running on a single simulator would be a false
// proof, which is worse than an obvious gap.

const { Given, When, Then } = require('@cucumber/cucumber');
const { element, by, waitFor, expect: detoxExpect } = require('detox');

const TIMEOUT = 30000;

// What the composer actually held when Send was pressed, which is not always what the scenario asked for:
// a real soft keyboard auto-capitalizes the first letter. The receiving device shows these exact bytes, so
// any cross-device comparison must use this rather than the Gherkin literal.
let composedBody = null;

const needsHardware = (what) => {
  const e = new Error(
    `SKIPPED, needs real hardware: ${what}. Detox drives one app instance and a simulator has no radio, ` +
      `so this cannot be proven here. Run it by hand on two or three physical devices.`,
  );
  e.pending = true;
  throw e;
};

const textOf = async (testID) => {
  const attrs = await element(by.id(testID)).getAttributes();
  return String(attrs.text || attrs.label || '').trim();
};

// Bring an element far enough into view that Espresso will act on it.
//
// Espresso refuses a tap or a type unless the target covers at least 75% of its own area on screen, and
// reports that as "Action will not be performed because the target view does not match one or more of the
// following constraints" even though the view is VISIBLE. The screen is a ScrollView taller than one
// viewport, so message-input, the buttons and send-status sit under the fold on a phone.
//
// This is Detox's own scroll-until-visible, driven off the ScrollView's `main-scroll` id. It replaced two
// earlier attempts, both rejected by measurement rather than taste:
//   * swiping `screen-main`, the SafeAreaView AROUND the ScrollView, scrolled nothing at all: a screenshot
//     taken after eight swipes was still pinned at the top of the screen;
//   * swiping a child with 'fast' velocity did scroll, but flung. The ScrollView kept moving after the
//     gesture ended, so toBeVisible passed and the following tap landed somewhere else, leaving the
//     composer empty and send-status null, which reads as the app failing to send rather than as a
//     harness race.
// whileElement scrolls in bounded steps and re-checks between them, so there is no fling and no race.
const bringIntoView = async (matcher) =>
  waitFor(matcher).toBeVisible().whileElement(by.id('main-scroll')).scroll(320, 'down');

// --- background ---------------------------------------------------------------------------------------

Given('the app is running', async () => {
  // The app lands on the Chats tab, like both native demos, so "running" means the peer list is up. The
  // address itself lives on the Status tab and has its own step that goes there.
  //
  // Retried, because the Before hook relaunches with delete:true and a cold start after a data wipe can
  // still be creating its activity when Espresso first looks. Measured on a Pixel 7: one scenario in nine
  // failed with "No activities found", which is the app not up YET rather than the app being broken. A
  // step whose whole job is to wait for the app should wait rather than report that as a product failure.
  let last = null;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      await waitFor(element(by.id('peers-list')))
        .toBeVisible()
        .withTimeout(TIMEOUT);
      return;
    } catch (e) {
      last = e;
      // Only a missing-activity race is worth retrying. Anything else is a real failure and rethrown.
      if (!/No activities (found|in stage RESUMED)/.test(String(e))) {
        throw e;
      }
      await new Promise(r => setTimeout(r, 3000));
    }
  }
  throw last;
});

// --- single device, real assertions -------------------------------------------------------------------

Then('I should see my own address', async () => {
  await element(by.id('tab-status')).tap();
  await detoxExpect(element(by.id('own-address'))).toBeVisible();
});

Then('my address should be a base58 address', async () => {
  await element(by.id('tab-status')).tap();
  // Bitcoin-alphabet base58 excludes 0, O, I and l. Asserting the shape catches a placeholder or a hex
  // leak, which a bare visibility check would happily pass.
  const text = await textOf('own-address');
  if (!/^[1-9A-HJ-NP-Za-km-z]{16,}$/.test(text)) {
    throw new Error(`address is not base58-shaped: ${JSON.stringify(text)}`);
  }
});

Then('I should be told discovery is unavailable without a bearer', async () => {
  await detoxExpect(element(by.id('bearer-note'))).toBeVisible();
});

Then('I should be told the QR code is unavailable', async () => {
  // The QR row lives on the Status tab now, matching the native demos' four-tab layout, so the step has
  // to go there first. The tab bar ids are covered by the lockstep guard like every other id.
  await element(by.id('tab-status')).tap();
  await detoxExpect(element(by.id('qr-unavailable'))).toBeVisible();
});

Then('I should see {int} person I can reach', async (count) => {
  await waitFor(element(by.id('peers-list')))
    .toBeVisible()
    .withTimeout(TIMEOUT);
  for (let i = 0; i < count; i += 1) {
    await detoxExpect(element(by.id(`peer-row-${i}`))).toBeVisible();
    // The row must carry a real address, not an empty label.
    const addr = await textOf(`peer-address-${i}`);
    if (addr.length === 0) {
      throw new Error(`peer row ${i} shows no address`);
    }
  }
});

When('I send {string} to the person I can reach', async (body) => {
  // Select the peer only once it is actionable. Tapping a row that is under the fold can be accepted by
  // Espresso and still not land where intended, and App.tsx's send() returns EARLY, setting no state at
  // all, when there is no selected peer or the draft is empty. That early return is why a lost tap or a
  // lost keystroke shows up later as `send-status` being null, which reads as the app failing to send
  // rather than as the harness missing. So this step verifies its own preconditions before pressing Send.
  await bringIntoView(element(by.id('peer-row-0')));
  await element(by.id('peer-row-0')).tap();

  if (body.length > 0) {
    await bringIntoView(element(by.id('message-input')));
    await element(by.id('message-input')).typeText(body);

    // Read the composer back. On a ScrollView taller than the viewport a scroll can still be settling when
    // the keystrokes arrive, and the text silently goes nowhere. One retry, then a precise failure.
    //
    // The comparison is case-insensitive ON PURPOSE. A real soft keyboard auto-capitalizes the first letter
    // of a sentence, so typing "meet at dawn" genuinely produces "Meet at dawn" on the device. That is the
    // keyboard behaving correctly for a chat composer, not a lost keystroke, and an exact match rejected it.
    const landed = (t) => t.trim().toLowerCase() === body.trim().toLowerCase();
    let typed = await textOf('message-input');
    if (!landed(typed)) {
      await element(by.id('message-input')).clearText();
      await element(by.id('message-input')).typeText(body);
      typed = await textOf('message-input');
    }
    if (!landed(typed)) {
      throw new Error(
        `the composer did not accept the text: wanted ${JSON.stringify(body)}, ` +
          `message-input holds ${JSON.stringify(typed)}. The tap or the keystrokes were lost, so Send would ` +
          `have been pressed with an empty draft and the app would correctly do nothing.`,
      );
    }
    // Remember what was ACTUALLY composed, not what was requested. The receiving device will show these
    // exact bytes, so a cross-device assertion has to compare against this rather than the literal.
    composedBody = typed;
  }

  await bringIntoView(element(by.id('send-button')));
  await element(by.id('send-button')).tap();
});

Then('the message should be reported as on its way', async () => {
  // send-status renders BELOW the send button, so on a phone it is off screen the moment it appears. It is
  // also where the LogBox dev banner sits, which is a second reason to scroll it up rather than assert it
  // where it lands.
  await bringIntoView(element(by.id('send-status')));
  const text = await textOf('send-status');
  // The app reports the REAL HopStatus. Progress words must appear; an empty status or a failure must not
  // pass, which is what makes this assertion able to fail.
  if (!/relayed|delivered|sending|sent/i.test(text) || /fail/i.test(text)) {
    throw new Error(`send status does not report progress: ${JSON.stringify(text)}`);
  }
});

Then('no delivery should be reported', async () => {
  // An empty body must not produce a status line at all.
  await detoxExpect(element(by.id('send-status'))).not.toBeVisible();
});

// --- multi device, deliberately not asserted ----------------------------------------------------------

Given('another phone running HopDemo is within Bluetooth range', async () =>
  needsHardware('a second physical phone with Bluetooth'),
);

Given('three phones in a line where the outer two are out of range of each other', async () =>
  needsHardware('three physical phones positioned so the outer two cannot hear each other'),
);

Then('I should see that phone listed by its device model name', async () =>
  needsHardware('a second physical phone advertising over BLE'),
);

When('I send {string} to that phone', async () => needsHardware('a second physical phone'));

Then('that phone should show the message in its chat', async () =>
  needsHardware('reading the screen of a second physical phone'),
);

When('the first phone sends {string} to the third', async () => needsHardware('three physical phones'));

Then('the third phone should receive it', async () => needsHardware('three physical phones'));

Then('the middle phone should have carried it', async () =>
  needsHardware('three physical phones, and inspecting the middle one relay count'),
);

// --- device pair, real assertions across two real devices -----------------------------------------------
//
// These run in TWO processes, one per device, started by e2e/pair/run-pair.mjs. Detox drives a single app
// instance per process (`detox.device` is a singleton), so a two-device scenario cannot be one Detox run.
// Both processes execute the SAME scenario and every step below branches on HOP_PAIR_ROLE, so the Gherkin
// stays readable as one story while each side only ever asserts what its own device shows.
//
// What makes these honest rather than decorative:
//   * they are excluded from the default profile, so a developer with no hardware still gets a green run
//     that never pretended to cover this;
//   * the two sides exchange REAL addresses read off each device's own-address element, and the run aborts
//     if the two addresses are equal, which is what a harness pointed at one device twice would produce;
//   * the body carries the run id, so residue from an earlier run cannot satisfy the assertion;
//   * the only thing that decides the scenario is the RECEIVER seeing the body, and the sender adopts the
//     receiver's verdict, so neither side can go green while the other goes red;
//   * an unreachable relay FAILS naming the URL and the app's relay-error text. It never skips.

const pair = require('../pair/rendezvous');

// Generous, because the first send also waits for the receiver's prekey bundle to propagate through the
// relay before an untraceable send can seal to it.
const PAIR_TIMEOUT = 180000;
const RESEND_EVERY = 15000;
const MAX_SENDS = 8;

let peerAddr = null;
let lastBody = null;
let matchedRow = null;

// The Gherkin literal plus the run id. Both processes derive the same string from the same shared id, and
// no earlier run can have produced it.
const bodyFor = (text) => `${text} [run ${pair.runId()}]`;

// Read text from an already-built matcher, so every testID below appears LITERALLY inside a by.id call.
// That is what puts these steps under e2e/testids.test.js: the guard extracts ids out of the by.id calls
// in this file, both the quoted and the template-literal form, so an id handed to a helper as a bare
// string variable would be invisible to it. Verbose on purpose; the alternative is assertions that
// nothing checks. Note also that the guard scans this file as text, comments included, so an example id
// written inside a comment would be read as a real one.
const readText = async (matcher) => {
  const attrs = await matcher.getAttributes();
  return String(attrs.text || attrs.label || '').trim();
};

// getAttributes throws when the element is not mounted, which for an index-addressed row simply means the
// row is not there yet.
const readTextOrNull = async (matcher) => {
  try {
    return await readText(matcher);
  } catch (e) {
    return null;
  }
};

Given('both devices are paired for this run', async () => {
  await pair.meet(PAIR_TIMEOUT);
  await waitFor(element(by.id('own-address')))
    .toBeVisible()
    .withTimeout(TIMEOUT);
});

Given('this device is connected to the relay under test', async () => {
  const url = pair.relayUrl();
  // replaceText, not typeText: the field is prefilled with the compiled-in default.
  await bringIntoView(element(by.id('relay-url-input')));
  await element(by.id('relay-url-input')).replaceText(url);
  await bringIntoView(element(by.id('relay-connect-button')));
  await element(by.id('relay-connect-button')).tap();

  // A socket that opens is NOT proof the relay accepted the link: the bearer carries opaque bytes and
  // cannot see the Noise XX handshake. So `up` is only a precondition here, never the assertion.
  const state = await pair.waitFor(
    `${pair.label()} to report the relay link up at ${url}`,
    async () => {
      const s = await readTextOrNull(element(by.id('relay-status')));
      if (s === 'up') return s;
      if (s === 'down') {
        const why =
          (await readTextOrNull(element(by.id('relay-error')))) || 'no relay-error text rendered';
        throw new Error(`${pair.label()} could not reach the relay at ${url}: ${why}`);
      }
      return null;
    },
    PAIR_TIMEOUT,
    () => `relay-status never left connecting. The relay at ${url} is unreachable from this device.`,
  );
  if (state !== 'up') {
    throw new Error(`relay-status is ${JSON.stringify(state)}, expected up`);
  }

  // The redial actually took, rather than the field being edited and ignored.
  const shown = await readText(element(by.id('relay-url')));
  if (shown !== url) {
    throw new Error(`relay-url shows ${JSON.stringify(shown)} but this device was pointed at ${url}`);
  }
});

Given('the two devices have exchanged addresses', async () => {
  const mine = await readText(element(by.id('own-address')));
  if (!/^[1-9A-HJ-NP-Za-km-z]{16,}$/.test(mine)) {
    throw new Error(`own address is not base58-shaped, refusing to publish it: ${JSON.stringify(mine)}`);
  }
  pair.publishAddress(mine);
  peerAddr = await pair.peerAddress(PAIR_TIMEOUT);

  // The check that stops this suite from lying. If both processes drove the same device, or the same app
  // instance twice, the two addresses would be identical and a "delivery" would just be the loopback pair
  // inside one app. Two devices means two identities.
  if (peerAddr === mine) {
    throw new Error(
      `both halves of the pair report the same Hop address (${mine}), so this is ONE device, not two. ` +
        'Nothing about a second device or a relay can be proven from that, so the run stops here.',
    );
  }
});

// Type the body and send. Separate from the step so the sender can repeat it.
const sendBody = async (body) => {
  await bringIntoView(element(by.id('message-input')));
  await element(by.id('message-input')).replaceText(body);
  await bringIntoView(element(by.id('send-button')));
  await element(by.id('send-button')).tap();
  const status = await readText(element(by.id('send-status')));
  if (/fail/i.test(status)) {
    throw new Error(`${pair.label()} could not send: ${status}`);
  }
};

When('the sending device sends {string} to the receiving device', async (text) => {
  lastBody = bodyFor(text);

  if (pair.role() !== 'sender') {
    // The receiving device does nothing but wait: it must not touch its own send controls, or a message it
    // displays might be one it sent to itself.
    await pair.waitForFirstSend(PAIR_TIMEOUT);
    return;
  }

  // The relay peer is reached by address, typed in. There is no discovery over a relay: the RN SDK has no
  // discovery surface at all, so the address comes from the other device's screen and nowhere else.
  await bringIntoView(element(by.id('peer-address-input')));
  await element(by.id('peer-address-input')).replaceText(peerAddr);
  await bringIntoView(element(by.id('add-peer-button')));
  await element(by.id('add-peer-button')).tap();

  const transport = await readText(element(by.id('peer-transport-1')));
  if (!/relay/i.test(transport)) {
    throw new Error(
      `peer-row-1 reports transport ${JSON.stringify(transport)}, not relay. The typed address did not ` +
        'become a relay peer, so a send would not cross the relay.',
    );
  }
  await element(by.id('peer-row-1')).tap();

  await sendBody(lastBody);
  pair.recordSend(1, lastBody);
});

// Scan the newest few rows for an exact body match, returning the row index or null. Newest-first, so a
// resend lands at index 0. The index is remembered so the attribution assertion reads the SAME row that
// carried the body, rather than assuming it was the newest.
const rowShowing = async (body, depth = 5) => {
  for (let i = 0; i < depth; i += 1) {
    const t = await readTextOrNull(element(by.id(`message-body-${i}`)));
    if (t === null) return null;
    if (t === body) return i;
  }
  return null;
};

Then('the receiving device shows the same message', async () => {
  const url = pair.relayUrl();

  if (pair.role() === 'receiver') {
    try {
      await pair.waitFor(
        `the exact body to appear on ${pair.label()}`,
        async () => {
          const i = await rowShowing(lastBody);
          if (i === null) return null;
          matchedRow = i;
          return true;
        },
        PAIR_TIMEOUT,
        () => {
          const sent = pair.sendAttempts();
          return (
            `The sender reported ${sent ? sent.attempt : 0} send attempt(s) of ${JSON.stringify(lastBody)} ` +
            `but this device never displayed it. Relay in use: ${url}. This is a real failure of the ` +
            'two-device path, not a missing capability.'
          );
        },
      );
      pair.putVerdict(true, `displayed ${JSON.stringify(lastBody)}`);
    } catch (e) {
      pair.putVerdict(false, e.message);
      throw e;
    }
    return;
  }

  // Sender: wait for the receiver's verdict, resending on an interval while it waits. Resending is
  // legitimate rather than a retry-until-green, because the assertion is still the receiver seeing THIS
  // run's body: what a resend covers is the prekey bundle not having propagated before the first send.
  let attempt = 1;
  const deadline = Date.now() + PAIR_TIMEOUT;
  let nextResend = Date.now() + RESEND_EVERY;
  let seen = null;
  while (Date.now() < deadline) {
    seen = pair.verdict('receiver');
    if (seen) break;
    if (Date.now() >= nextResend && attempt < MAX_SENDS) {
      attempt += 1;
      await sendBody(lastBody);
      pair.recordSend(attempt, lastBody);
      nextResend = Date.now() + RESEND_EVERY;
    }
    await pair.sleep(500);
  }

  if (!seen) {
    const e = new Error(
      `no verdict from the receiving device (${pair.label(pair.otherRole())}) after ${attempt} send ` +
        `attempt(s) over ${url}.`,
    );
    pair.putVerdict(false, e.message);
    throw e;
  }
  if (!seen.ok) {
    const e = new Error(
      `the receiving device (${pair.label(pair.otherRole())}) never showed the message after ${attempt} ` +
        `send attempt(s) over ${url}: ${seen.detail}`,
    );
    pair.putVerdict(false, e.message);
    throw e;
  }
  pair.putVerdict(true, `receiver confirmed after ${attempt} send attempt(s)`);
});

Then('both devices agree the message crossed', async () => {
  // The gate against a half-green pair: one process passing while the other failed must fail BOTH.
  for (const which of pair.ROLES) {
    const v = await pair.waitForVerdict(which, PAIR_TIMEOUT, () =>
      `The ${which} never recorded one, so the two sides did not agree.`,
    );
    if (!v.ok) {
      throw new Error(`the ${which} reports the message did not cross: ${v.detail}`);
    }
  }
});

Then('the receiving device attributes it to the sending device', async () => {
  if (pair.role() !== 'receiver') {
    // The sending device cannot see the receiving device's screen. Nothing to assert here, and inventing
    // something would only mean asserting against its own copy of the message.
    return;
  }
  if (matchedRow === null) {
    throw new Error('no row was matched, so there is nothing to attribute');
  }

  // This is the assertion that rules out the receiving app having produced the message itself. The app
  // also runs an in-process loopback peer, so "a message appeared" alone does not prove it came from the
  // other device. The row must be attributed to the SENDER's identity, which this process only knows
  // because the sender published the address it read off its own screen.
  const from = await readText(element(by.id(`message-from-${matchedRow}`)));
  // shortAddress() joins a leading and trailing run of 6 characters, so both ends appear verbatim. Match
  // on those rather than the whole rendering, which also carries hop count and secured state.
  const head = peerAddr.slice(0, 6);
  const tail = peerAddr.slice(-6);
  if (!from.includes(head) || !from.includes(tail)) {
    throw new Error(
      `the message is not attributed to the sending device. Row ${matchedRow} reports from ` +
        `${JSON.stringify(from)}, which does not carry ${head}...${tail} from the sender's address ` +
        `${peerAddr}. A body that appears without the sender's identity could have come from this app's ` +
        'own loopback peer, so this run proves nothing about two devices.',
    );
  }
});
