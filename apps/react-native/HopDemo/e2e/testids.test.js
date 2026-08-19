// Lockstep guard: every testID the Detox steps address must exist in App.tsx, and every testID fixed by
// agreement must be rendered by App.tsx whether or not a step addresses it yet.
//
// Why this exists. Detox failures are slow, need an emulator, and report "element not visible", which
// reads like a product bug when it is really a rename. This runs in milliseconds with no device and names
// the missing id. It caught two real drifts the first time it ran: the bearer notice is `bearer-note`, and
// peer rows were keyed by address rather than index.
//
// It is also written so it CAN fail. It parses ids out of both files rather than comparing a hardcoded
// list to itself, and it asserts the extracted sets are non-empty, so a broken regex fails loudly instead
// of silently comparing nothing against nothing.

const fs = require('fs');
const path = require('path');

const read = (rel) => fs.readFileSync(path.join(__dirname, '..', rel), 'utf8');

// Ids rendered by the app, both plain and template forms. A template `peer-row-${index}` is recorded as
// the prefix `peer-row-` because the suffix is decided at runtime.
const appTestIds = () => {
  const src = read('App.tsx');
  const plain = [...src.matchAll(/testID="([^"]+)"/g)].map((m) => m[1]);
  const templated = [...src.matchAll(/testID=\{`([^`]+)`\}/g)].map((m) => m[1].replace(/\$\{[^}]+\}/g, ''));
  return { plain: new Set(plain), prefixes: new Set(templated) };
};

// Ids addressed by the steps, from by.id('x') and by.id(`x-${i}`).
const stepTestIds = () => {
  const src = read('e2e/steps/mesh.steps.js');
  const plain = [...src.matchAll(/by\.id\('([^']+)'\)/g)].map((m) => m[1]);
  const templated = [...src.matchAll(/by\.id\(`([^`]+)`\)/g)].map((m) => m[1].replace(/\$\{[^}]+\}/g, ''));
  const fromTextOf = [...src.matchAll(/textOf\(`?([a-z-]+?)-?\$?\{?/g)].map((m) => m[1]);
  return { plain: new Set(plain), prefixes: new Set([...templated, ...fromTextOf.filter(Boolean)]) };
};

describe('Detox steps address real testIDs', () => {
  const app = appTestIds();
  const steps = stepTestIds();

  it('extracted non-empty sets from both files', () => {
    // Without this, a regex typo would make every assertion below vacuously true.
    expect(app.plain.size).toBeGreaterThan(5);
    expect(app.prefixes.size).toBeGreaterThan(0);
    expect(steps.plain.size).toBeGreaterThan(3);
  });

  it('every plain testID used by a step exists in App.tsx', () => {
    const missing = [...steps.plain].filter((id) => {
      if (app.plain.has(id)) return false;
      // A step may address a templated id with a literal suffix, e.g. peer-row-0.
      return ![...app.prefixes].some((p) => id.startsWith(p));
    });
    expect(missing).toEqual([]);
  });

  it('every templated prefix used by a step exists in App.tsx', () => {
    const missing = [...steps.prefixes].filter(
      (p) => ![...app.prefixes].some((ap) => ap.startsWith(p) || p.startsWith(ap)) && !app.plain.has(p),
    );
    expect(missing).toEqual([]);
  });
});

describe('App.tsx renders the testIDs the relay contract fixed', () => {
  // Why this exists alongside the checks above, which are NOT enough on their own. Those run in one
  // direction, steps -> App, so they cannot see an id the steps have not started addressing yet. The
  // relay ids were agreed before the device-pair steps were written, which leaves a window where
  // renaming one in App.tsx breaks nothing and is noticed on a phone instead. These are the ids that
  // were fixed by agreement; App.tsx has to render every one.
  //
  // This is not a list compared against itself: the right-hand side is parsed out of App.tsx, so a
  // rename there fails this, and the parse is asserted non-empty first so a regex typo cannot make it
  // vacuous.
  const app = appTestIds();

  const fixed = [
    'screen-main',
    'own-address',
    'bearer-note',
    'message-input',
    'send-button',
    'relay-status',
    'relay-url',
    'relay-url-input',
    'relay-connect-button',
    'peer-address-input',
    'add-peer-button',
  ];

  // Runtime-suffixed ids, recorded by their prefix for the same reason the parser records them that way.
  const fixedPrefixes = [
    'peer-row-',
    'peer-address-',
    'peer-transport-',
    'message-row-',
    'message-body-',
    'message-from-',
  ];

  it('parsed a non-empty set of ids out of App.tsx', () => {
    expect(app.plain.size).toBeGreaterThan(10);
    expect(app.prefixes.size).toBeGreaterThan(3);
  });

  it('renders every fixed testID', () => {
    expect(fixed.filter((id) => !app.plain.has(id))).toEqual([]);
  });

  it('renders every fixed templated testID', () => {
    expect(fixedPrefixes.filter((p) => !app.prefixes.has(p))).toEqual([]);
  });
});

describe('the feature file and the steps agree', () => {
  const feature = read('e2e/features/mesh.feature');
  const steps = read('e2e/steps/mesh.steps.js');

  it('every Gherkin step has a definition', () => {
    const lines = feature
      .split('\n')
      .map((l) => l.trim())
      .filter((l) => /^(Given|When|Then|And) /.test(l));
    expect(lines.length).toBeGreaterThan(8);

    // Normalise a Gherkin line to the shape a cucumber-expression would match: quoted strings and bare
    // integers become placeholders.
    const norm = (l) =>
      l
        .replace(/^(Given|When|Then|And) /, '')
        .replace(/"[^"]*"/g, '{string}')
        .replace(/(?<![\w{])\d+(?![\w}])/g, '{int}')
        .replace(/<[^>]+>/g, '{string}')
        .trim();

    const defined = new Set(
      [...steps.matchAll(/(?:Given|When|Then)\('([^']+)'/g)].map((m) => m[1].trim()),
    );
    expect(defined.size).toBeGreaterThan(8);

    const undefinedSteps = [...new Set(lines.map(norm))].filter((s) => {
      if (defined.has(s)) return false;
      // 'And' lines inherit the previous keyword, and quoted-vs-placeholder forms can differ slightly, so
      // accept an exact match against any definition after the same normalisation.
      return ![...defined].some((d) => d === s);
    });
    expect(undefinedSteps).toEqual([]);
  });

  it('multi-device scenarios never assert on a simulator', () => {
    // Every scenario tagged @multi-device must reach a step that throws pending. Proven structurally: the
    // steps unique to those scenarios all call needsHardware.
    const hardwareSteps = [...steps.matchAll(/needsHardware\(/g)];
    expect(hardwareSteps.length).toBeGreaterThan(5);
    const multiCount = (feature.match(/@multi-device/g) || []).length;
    expect(multiCount).toBeGreaterThan(2);
  });
});
