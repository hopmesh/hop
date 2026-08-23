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

// --- background ---------------------------------------------------------------------------------------

Given('the app is running', async () => {
  await waitFor(element(by.id('own-address')))
    .toBeVisible()
    .withTimeout(TIMEOUT);
});

// --- single device, real assertions -------------------------------------------------------------------

Then('I should see my own address', async () => {
  await detoxExpect(element(by.id('own-address'))).toBeVisible();
});

Then('my address should be a base58 address', async () => {
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
  await element(by.id('peer-row-0')).tap();
  // The composer (message-input, send-button) is the last block inside main-scroll, below the fold on
  // current devices. App.tsx gives the outer ScrollView its testID for exactly this purpose: its own
  // comment says a test that needs a control in view must scroll it. Tapping without scrolling fails
  // with "View is not hittable", which is the harness's job to fix, not the app's layout. Detox's
  // scroll() and scrollTo() actions both reject RN Fabric scroll views ("not an instance of
  // UIScrollView"), so the swipe is a real gesture, which the scroll view follows on both platforms.
  await element(by.id('main-scroll')).swipe('up', 'slow', 0.75);
  // Fail loudly here if the swipe did not reveal the composer, instead of with an opaque
  // not-hittable error on the tap below.
  await waitFor(element(by.id('send-button'))).toBeVisible().withTimeout(5000);
  if (body.length > 0) {
    await element(by.id('message-input')).typeText(body);
    // Dismiss the keyboard: it covers the bottom of the screen where send-button sits, and iOS Detox
    // does not auto-scroll. The input is single-line, so the return key blurs it.
    await element(by.id('message-input')).tapReturnKey();
  }
  await element(by.id('send-button')).tap();
});

Then('the message should be reported as on its way', async () => {
  await waitFor(element(by.id('send-status')))
    .toBeVisible()
    .withTimeout(TIMEOUT);
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
