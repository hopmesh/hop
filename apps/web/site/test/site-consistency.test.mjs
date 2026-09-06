import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync, statSync, mkdtempSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { resolve, dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const siteRoot = resolve(here, '..');
const repoRoot = resolve(siteRoot, '..', '..', '..');

function readSite(rel) {
  return readFileSync(resolve(siteRoot, rel), 'utf8');
}

function readRepo(rel) {
  return readFileSync(resolve(repoRoot, rel), 'utf8');
}

test('CLAIM-012: pricing.astro delivery promise must not contradict faq.astro or use unqualified always/never', () => {
  const pricing = readSite('src/pages/pricing.astro');
  const faq = readSite('src/pages/faq.astro');

  // FAQ documents conditional at-least-once delivery with lifetime and custody-cap eviction
  assert.match(faq, /Not unconditionally/);
  assert.match(faq, /custody cap evicts/);

  // pricing.astro must NOT make unqualified absolute delivery promises for in-flight bundles
  assert.doesNotMatch(
    pricing,
    /always deliver/i,
    'pricing.astro must not claim in-flight bundles "always deliver" unconditionally'
  );
  assert.doesNotMatch(
    pricing,
    /never drop a message/i,
    'pricing.astro must not claim "we never drop a message you handed us"'
  );
});

test('BIZ-001: public statements on license tiers must match actual component licenses (services = FSL, others = Apache-2.0)', () => {
  const pricing = readSite('src/pages/pricing.astro');
  const releng = readRepo('docs/release-engineering.md');

  // pricing.astro must NOT state that services are Apache-2.0 or that protocol core is FSL
  assert.doesNotMatch(
    pricing,
    /The services are\s+licensed[^\w]+Apache-2\.0/i,
    'pricing.astro inverted license: claims services are Apache-2.0'
  );
  assert.doesNotMatch(
    pricing,
    /protocol core they embed is\s+source-available under[^\w]+FSL/i,
    'pricing.astro inverted license: claims protocol core is FSL'
  );

  // pricing.astro must correctly attribute FSL to services and Apache-2.0 to core/SDKs
  assert.match(
    pricing,
    /services[\s\S]*?FSL-1\.1-ALv2/i,
    'pricing.astro must state services are FSL-1.1-ALv2'
  );
  assert.match(
    pricing,
    /protocol core[\s\S]*?Apache-2\.0/i,
    'pricing.astro must state protocol core is Apache-2.0'
  );

  // docs/release-engineering.md must NOT claim core/ uses FSL and services use Apache-2.0
  assert.doesNotMatch(
    releng,
    /Components under `core\/` use\s+FSL-1\.1-ALv2;\s+SDKs, services/i,
    'docs/release-engineering.md inverted license tier statement'
  );
  assert.match(
    releng,
    /services[^\n]*FSL-1\.1-ALv2/i,
    'docs/release-engineering.md must state services use FSL-1.1-ALv2'
  );
});

test('BIZ-002: Terms of Service and Acceptable Use Policy must be published and linked in Footer; privacy policy must be formal', () => {
  // Required legal pages must exist
  assert.equal(existsSync(resolve(siteRoot, 'src/pages/terms.astro')), true, 'terms.astro must exist');
  assert.equal(existsSync(resolve(siteRoot, 'src/pages/acceptable-use.astro')), true, 'acceptable-use.astro must exist');

  // Footer must link to Terms of Service
  const footer = readSite('src/components/Footer.astro');
  assert.match(footer, /href="\/terms\/"/, 'Footer must link to /terms/');
  assert.match(footer, /href="\/acceptable-use\/"/, 'Footer must link to /acceptable-use/');

  // privacy.astro must not be a temporary pre-formal placeholder
  const privacy = readSite('src/pages/privacy.astro');
  assert.doesNotMatch(
    privacy,
    /A formal policy\s+accompanies general availability/i,
    'privacy.astro must be formal, not a pre-formal placeholder'
  );
});

test('BIZ-003: pricing headline must not falsely claim "Nothing else" while additional billed dimensions exist', () => {
  const pricing = readSite('src/pages/pricing.astro');

  // Headline must not claim "Nothing else" when egress and mailbox storage are also billed
  assert.doesNotMatch(
    pricing,
    /You pay for[^\n]*Nothing else\./i,
    'pricing.astro headline must not claim "Nothing else" when additional meters apply'
  );
  assert.doesNotMatch(
    pricing,
    /Pay only for reach and telemetry/i,
    'pricing.astro CTA must not claim "Pay only for reach and telemetry"'
  );
});

test('BIZ-005: public safety and defense page must substantiate or properly qualify export compliance claims', () => {
  const psd = readSite('src/pages/public-safety-defense.astro');

  // Must not make unqualified assertion that export questions are already cleared case-by-case without compliance qualification
  assert.doesNotMatch(
    psd,
    /Procurement, compliance, and export questions handled\s+case by case\./,
    'public-safety-defense.astro must qualify export-classification evaluation for prospective defense buyers'
  );
});

test('CLAIM-011: protocol.js must not claim demand-based regional routing or empty-region cost guarantees', () => {
  const protocol = readSite('src/data/protocol.js');

  assert.doesNotMatch(
    protocol,
    /never pay to flood empty ones/i,
    'protocol.js must not claim unbacked demand-routing cost guarantee "never pay to flood empty ones"'
  );
  assert.doesNotMatch(
    protocol,
    /only fans to regions with live subscribers/i,
    'protocol.js must not claim demand-based topic fan-out "only fans to regions with live subscribers"'
  );
  assert.doesNotMatch(
    protocol,
    /only ships to regions that actually have subscribers/i,
    'protocol.js must not claim demand-based topic shipping to regions'
  );
});

test('CLAIM-018: driver documentation and developer pages must describe C ABI and HopContract architecture rather than UniFFI', () => {
  const driverDoc = readSite('src/pages/docs/build-a-driver.astro');
  const developers = readSite('src/pages/developers.astro');
  const faq = readSite('src/pages/faq.astro');
  const llms = readSite('src/pages/llms.txt.js');
  const llmsFull = readSite('src/pages/llms-full.txt.js');
  const drivers = readSite('src/data/drivers.js');

  for (const [name, content] of [
    ['build-a-driver.astro', driverDoc],
    ['developers.astro', developers],
    ['faq.astro', faq],
    ['llms.txt.js', llms],
    ['llms-full.txt.js', llmsFull],
    ['drivers.js', drivers],
  ]) {
    assert.doesNotMatch(
      content,
      /\bUniFFI\b/i,
      `${name} must not reference UniFFI; Hop uses the C ABI and HopContract architecture`
    );
  }

  // Verify HopContract architecture elements in build-a-driver.astro
  assert.match(driverDoc, /HopContract/, 'build-a-driver.astro must document HopContract');
  assert.match(driverDoc, /func[^\w]*start\(\)/, 'build-a-driver.astro must document start()');
  assert.match(driverDoc, /func[^\w]*stop\(\)/, 'build-a-driver.astro must document stop()');
  assert.match(driverDoc, /func[^\w]*send\(/, 'build-a-driver.astro must document send()');
  assert.match(driverDoc, /func[^\w]*close\(/, 'build-a-driver.astro must document close()');
  assert.match(driverDoc, /func[^\w]*authenticated\(/, 'build-a-driver.astro must document authenticated()');
  assert.match(driverDoc, /LinkSink/, 'build-a-driver.astro must document LinkSink');
  assert.match(driverDoc, /BearerManager/, 'build-a-driver.astro must document BearerManager');

  // Verify C ABI universal floor
  assert.match(developers, /C ABI/, 'developers.astro must reference C ABI');
  assert.match(faq, /C ABI/, 'faq.astro must reference C ABI');
  assert.match(llms, /C ABI/, 'llms.txt.js must reference C ABI');
  assert.match(llmsFull, /C ABI/, 'llms-full.txt.js must reference C ABI');
  assert.match(drivers, /C ABI/, 'drivers.js must reference C ABI');
});

test('CLAIM-021: drivers.js must accurately describe ESP32 C ABI consumption instead of no-std embedded context', () => {
  const drivers = readSite('src/data/drivers.js');
  assert.doesNotMatch(
    drivers,
    /no-std/i,
    'drivers.js line 54 must not claim ESP32 runs in a no-std embedded context'
  );
  assert.doesNotMatch(
    drivers,
    /bare-metal/i,
    'drivers.js line 51 must not claim ESP32 is a bare-metal host'
  );
  assert.match(
    drivers,
    /ESP-IDF/i,
    'drivers.js must mention ESP-IDF for ESP32 driver'
  );
  assert.match(
    drivers,
    /C ABI/i,
    'drivers.js must mention C ABI for ESP32 driver'
  );
});

test('CLAIM-019: crates.io package names cited in website docs must match allowed list in docs/repo-catalog.md', () => {
  const catalog = readRepo('docs/repo-catalog.md');
  const allowedCrates = new Set();
  for (const line of catalog.split('\n')) {
    const m = line.match(/\|\s*`[^`]+`\s*\|\s*`([^`]+)`\s*\|\s*\[crates\.io/);
    if (m) {
      allowedCrates.add(m[1]);
    }
  }
  assert.ok(allowedCrates.has('hop-mesh-core'), 'catalog must define hop-mesh-core');
  assert.ok(allowedCrates.has('hop-mesh-store-sqlite'), 'catalog must define hop-mesh-store-sqlite');
  assert.ok(allowedCrates.has('hop-mesh-store-firestore'), 'catalog must define hop-mesh-store-firestore');

  // Verify quickstart.astro specifically
  const quickstart = readSite('src/pages/docs/quickstart.astro');
  assert.doesNotMatch(
    quickstart,
    /hop-core\s*=\s*"0\.1"/i,
    'quickstart.astro must not reference third-party crate hop-core = "0.1"'
  );
  assert.match(
    quickstart,
    /hop-mesh-core\s*=\s*"0\.0\.3"/,
    'quickstart.astro must reference hop-mesh-core = "0.0.3"'
  );

  // Scan all pages under src/pages/docs for Cargo dependency blocks and crates.io links
  const docsDir = resolve(siteRoot, 'src/pages/docs');
  function findFiles(dir) {
    let results = [];
    for (const entry of readdirSync(dir)) {
      const full = resolve(dir, entry);
      if (statSync(full).isDirectory()) {
        results = results.concat(findFiles(full));
      } else if (entry.endsWith('.astro') || entry.endsWith('.md')) {
        results.push(full);
      }
    }
    return results;
  }
  const docFiles = findFiles(docsDir);
  for (const file of docFiles) {
    const text = readFileSync(file, 'utf8');
    // Check crates.io links: e.g. crates.io/crates/<crate-name>
    const crateLinkMatches = text.matchAll(/crates\.io\/crates\/([a-zA-Z0-9_-]+)/g);
    for (const match of crateLinkMatches) {
      const crateName = match[1];
      assert.ok(
        allowedCrates.has(crateName),
        `File ${file} links to unlisted crates.io package '${crateName}'. Allowed: ${[...allowedCrates].join(', ')}`
      );
    }
    // Check dependency blocks for hop-core
    assert.doesNotMatch(
      text,
      /\[dependencies\][^`]*\bhop-core\b\s*=/s,
      `File ${file} cites 'hop-core' as Cargo dependency; must be 'hop-mesh-core'`
    );
  }
});
test('BIZ-008: terms, public-safety-defense, and use-cases must disclaim 911 and emergency dispatch capabilities', () => {
  const terms = readSite('src/pages/terms.astro');
  const psd = readSite('src/pages/public-safety-defense.astro');
  const useCases = readSite('src/data/use-cases.js');

  // terms.astro Section 8 must prominently disclaim 911 and emergency services
  assert.match(terms, /NO 911 OR EMERGENCY SERVICES/i, 'terms.astro Section 8 must include NO 911 OR EMERGENCY SERVICES heading');
  assert.match(terms, /(?:not|nor|or) a replacement for (?:traditional )?emergency (?:dispatch|services)/i, 'terms.astro must state Hop is not a replacement for emergency dispatch');
  assert.match(terms, /(?:do not|does not|cannot) connect to (?:911|PSAP|Public Safety Answering Point)/i, 'terms.astro must state Hop does not connect to 911 or PSAPs');

  // public-safety-defense.astro must clarify delay-tolerant software is not certified for life-safety emergency dispatch
  assert.match(psd, /not certified for life-safety|not a certified emergency dispatch|best-effort/i, 'public-safety-defense.astro must disclaim certified emergency dispatch');

  // use-cases.js broadcast scenario must include an emergency disclaimer
  assert.match(useCases, /not a certified emergency alert system|not a replacement for official (?:civilian|emergency)|best-effort/i, 'use-cases.js must clarify alerts are best-effort delay-tolerant and not certified emergency broadcast');
});

test('BIZ-010: dpa.astro must incorporate mandatory GDPR Article 28(3) processor terms and subprocessor objection procedures', () => {
  const dpa = readSite('src/pages/dpa.astro');

  // Documented instructions (Art. 28(3)(a))
  assert.match(dpa, /documented instructions/i, 'dpa.astro must mandate processing only on documented instructions');

  // Confidentiality (Art. 28(3)(b))
  assert.match(dpa, /confidentiality/i, 'dpa.astro must require personnel confidentiality commitments');

  // Breach notice timeline within 48 hours (Art. 28(3)(f))
  assert.match(dpa, /48 hours/i, 'dpa.astro must require personal data breach notification within 48 hours');

  // DSAR assistance (Art. 28(3)(e))
  assert.match(dpa, /data subject rights|DSAR/i, 'dpa.astro must commit to assisting with data subject rights');

  // Deletion or return on termination (Art. 28(3)(g))
  assert.match(dpa, /delete or return|deletion upon termination/i, 'dpa.astro must obligate deletion or return of customer data');

  // Audits and inspection (Art. 28(3)(h))
  assert.match(dpa, /audits? and inspections?|audit rights?/i, 'dpa.astro must permit audits and inspections');

  // Subprocessor notice and objection (Art. 28.2 / 28.4)
  assert.match(dpa, /objection|right to object/i, 'dpa.astro must establish subprocessor notice and objection procedure');
});

test('BIZ-011: terms, dpa, and privacy must explicitly identify Hop Mesh, LLC and include legal contact details', () => {
  const terms = readSite('src/pages/terms.astro');
  const dpa = readSite('src/pages/dpa.astro');
  const privacy = readSite('src/pages/privacy.astro');

  // Must identify Hop Mesh, LLC exactly without unverified state of organization
  assert.match(terms, /Hop Mesh, LLC/i, 'terms.astro must identify Hop Mesh, LLC');
  assert.doesNotMatch(terms, /Hop Mesh, LLC,\s+a Delaware limited liability company/i, 'terms.astro must not assert unverified state of organization');
  assert.match(dpa, /Hop Mesh, LLC/i, 'dpa.astro must identify Hop Mesh, LLC');
  assert.doesNotMatch(dpa, /Hop Mesh, LLC,\s+a Delaware limited liability company/i, 'dpa.astro must not assert unverified state of organization');
  assert.match(privacy, /Hop Mesh, LLC/i, 'privacy.astro must identify Hop Mesh, LLC');
  assert.doesNotMatch(privacy, /Hop Mesh, LLC,\s+a Delaware limited liability company/i, 'privacy.astro must not assert unverified state of organization');

  // terms.astro must include legal notice channel and counsel placeholder, without ungrounded address
  assert.match(terms, /legal@hopme\.sh/i, 'terms.astro must include legal notice email');
  assert.match(terms, /Counsel placeholder/i, 'terms.astro must include counsel placeholder for registered office');
  assert.doesNotMatch(terms, /1309 Coffeen Avenue/i, 'terms.astro must not assert ungrounded physical address');
});

test('BIZ-012: acceptable-use must publish DMCA notice procedure and terms must mandate binding individual arbitration with class waiver', () => {
  const aup = readSite('src/pages/acceptable-use.astro');
  const terms = readSite('src/pages/terms.astro');

  // acceptable-use.astro must publish DMCA notice procedure directed to copyright team
  assert.match(aup, /Digital Millennium Copyright Act|DMCA/i, 'acceptable-use.astro must publish DMCA policy');
  assert.match(aup, /dmca@hopme\.sh/i, 'acceptable-use.astro must designate dmca@hopme.sh for notices');
  assert.match(aup, /DMCA notices should be sent to/i, 'acceptable-use.astro must state DMCA notices should be sent to copyright team');
  assert.match(aup, /counter-notice/i, 'acceptable-use.astro must publish DMCA counter-notification procedure');
  assert.doesNotMatch(aup, /1309 Coffeen Avenue/i, 'acceptable-use.astro must not assert ungrounded physical address');

  // terms.astro Section 10 must mandate binding individual arbitration, class action waiver, and jury waiver
  assert.match(terms, /binding (?:individual )?arbitration/i, 'terms.astro must mandate binding arbitration');
  assert.match(terms, /class action waiver|waiver of class/i, 'terms.astro must include class action waiver');
  assert.match(terms, /jury trial waiver|waive.*jury/i, 'terms.astro must include jury trial waiver');
});

test('BIZ-013: DESIGN.md Section 37 must align billing meters with pricing.astro and define Reach delivery formula', () => {
  const design = readRepo('DESIGN.md');
  const pricing = readSite('src/pages/pricing.astro');
  const costModel = readRepo('docs/pricing-cost-model.md');

  // DESIGN.md Section 37 must define Reach delivery meter and formula
  assert.match(design, /reach_delivery|Reach delivery/i, 'DESIGN.md §37 must document Reach delivery meter');
  assert.match(design, /0\.002/i, 'DESIGN.md §37 must document $0.002 Reach unit price');
  assert.match(design, /10,?000/i, 'DESIGN.md §37 must document 10,000 included Reach allowance');
  assert.match(design, /telemetry_events|Telemetry events/i, 'DESIGN.md §37 must document telemetry events meter');

  // MAD must be clarified as $0 / tenant auth only, never a per-seat fee
  assert.match(design, /never (?:as )?a per-seat fee|\$0 per device/i, 'DESIGN.md §37 must document MAD as non-fee / tenant auth');

  // pricing.astro and cost-model must match Reach and Telemetry
  assert.match(pricing, /\$0\.002\s*\/\s*offline delivery/i, 'pricing.astro must match Reach delivery price');
  assert.match(costModel, /\$0\.002 per backbone delivery/i, 'pricing-cost-model.md must match Reach delivery price');
});

test('BIZ-014: early-access, business, index, and quickstart pages must reflect developer preview / testnet status without dead status links or auto-redirect', () => {
  const earlyAccess = readSite('src/pages/early-access.astro');
  const business = readSite('src/pages/business.astro');
  const index = readSite('src/pages/index.astro');
  const quickstart = readSite('src/pages/docs/quickstart.astro');

  // early-access must NOT claim "Early access is over", must not auto-redirect, and must not link to status.hopme.sh
  assert.doesNotMatch(earlyAccess, /Early access is over/i, 'early-access.astro must not claim early access is over');
  assert.doesNotMatch(earlyAccess, /window\.location\.replace/i, 'early-access.astro must not auto-redirect');
  assert.doesNotMatch(earlyAccess, /status\.hopme\.sh/i, 'early-access.astro must not link to non-resolving status.hopme.sh');
  assert.match(earlyAccess, /developer preview|testnet/i, 'early-access.astro must describe developer preview / testnet status');

  // business.astro must describe preview / testnet status and not link to status.hopme.sh
  assert.match(business, /developer preview|testnet/i, 'business.astro must describe preview / testnet status');
  assert.doesNotMatch(business, /status\.hopme\.sh/i, 'business.astro must not link to non-resolving status.hopme.sh');

  // index.astro and quickstart.astro must qualify hosted fleet access as preview and not link to status.hopme.sh
  assert.match(index, /developer preview|preview/i, 'index.astro must qualify hosted backbone with preview');
  assert.match(quickstart, /developer preview|preview/i, 'quickstart.astro must describe developer preview');
  assert.doesNotMatch(index, /status\.hopme\.sh/i, 'index.astro must not link to status.hopme.sh');
  assert.doesNotMatch(quickstart, /status\.hopme\.sh/i, 'quickstart.astro must not link to status.hopme.sh');
});

test('BIZ-015: CLA templates must not contain generic template disclaimers, CONTRIBUTING.md must document CLA, and DCO workflow must exist', () => {
  const contributing = readRepo('CONTRIBUTING.md');
  assert.match(contributing, /Contributor License Agreement|CLA/i, 'CONTRIBUTING.md must document CLA requirement');
  assert.match(contributing, /Developer Certificate of Origin|DCO/i, 'CONTRIBUTING.md must document DCO / sign-off');

  // .github/workflows/dco.yml must exist, gate only external contributors, and exempt maintainers / bots
  assert.equal(existsSync(resolve(repoRoot, '.github/workflows/dco.yml')), true, '.github/workflows/dco.yml must exist');
  const dcoWorkflow = readRepo('.github/workflows/dco.yml');
  assert.doesNotMatch(dcoWorkflow, /pull_request_target/i, 'dco.yml must never use pull_request_target');
  assert.match(dcoWorkflow, /OWNER/i, 'dco.yml must reference OWNER author_association');
  assert.match(dcoWorkflow, /MEMBER/i, 'dco.yml must reference MEMBER author_association');
  assert.match(dcoWorkflow, /COLLABORATOR/i, 'dco.yml must reference COLLABORATOR author_association');
  assert.match(dcoWorkflow, /dependabot\[bot\]/i, 'dco.yml must explicitly exempt dependabot[bot]');
  assert.match(dcoWorkflow, /hop-sync/i, 'dco.yml must explicitly exempt hop-sync');

  // Self-test of DCO shell logic: maintainers and bots must exit 0, external contributors must be validated
  const dcoRunScript = dcoWorkflow.match(/run:\s*\|\n([\s\S]*?)(?=\n\s*\w+:|$)/)[1];
  const resOwner = spawnSync('bash', ['-c', dcoRunScript], {
    env: { ...process.env, AUTHOR_ASSOCIATION: 'OWNER' }
  });
  assert.equal(resOwner.status, 0, 'DCO script must exit 0 for OWNER');
  assert.match(resOwner.stdout.toString(), /Exempting repository maintainer \(OWNER\)/);

  const resBot = spawnSync('bash', ['-c', dcoRunScript], {
    env: { ...process.env, ACTOR: 'dependabot[bot]' }
  });
  assert.equal(resBot.status, 0, 'DCO script must exit 0 for dependabot[bot]');
  assert.match(resBot.stdout.toString(), /Exempting maintainer or automated actor \(dependabot\[bot\]\)/);

  const resSync = spawnSync('bash', ['-c', dcoRunScript], {
    env: { ...process.env, PR_USER: 'hop-sync' }
  });
  assert.equal(resSync.status, 0, 'DCO script must exit 0 for hop-sync');
  assert.match(resSync.stdout.toString(), /Exempting maintainer or automated PR author \(hop-sync\)/);

  // GitHub computes author_association lazily: the owner's own PR #131 arrived as CONTRIBUTOR at
  // event time, so the maintainer exemption has to hold on the login as well.
  const resMaintainerLogin = spawnSync('bash', ['-c', dcoRunScript], {
    env: { ...process.env, AUTHOR_ASSOCIATION: 'CONTRIBUTOR', ACTOR: 'jwaldrip', PR_USER: 'jwaldrip' }
  });
  assert.equal(resMaintainerLogin.status, 0, 'DCO script must exit 0 for the maintainer login even when author_association lags');
  assert.match(resMaintainerLogin.stdout.toString(), /Exempting maintainer or automated actor \(jwaldrip\)/);

  // An outside contributor with an unsigned commit must still be refused: exercise the real
  // rev-list path against this repository's own history with a synthetic unsigned commit range.
  const tmpRepo = mkdtempSync(join(tmpdir(), 'hop-dco-'));
  const git = (...args) => spawnSync('git', ['-C', tmpRepo, ...args], { env: { ...process.env, GIT_AUTHOR_NAME: 'Outside', GIT_AUTHOR_EMAIL: 'o@example.com', GIT_COMMITTER_NAME: 'Outside', GIT_COMMITTER_EMAIL: 'o@example.com' } });
  git('init', '-q');
  git('-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'base');
  const base = git('rev-parse', 'HEAD').stdout.toString().trim();
  git('-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'unsigned change');
  const head = git('rev-parse', 'HEAD').stdout.toString().trim();
  const resOutside = spawnSync('bash', ['-c', dcoRunScript], {
    cwd: tmpRepo,
    env: { ...process.env, AUTHOR_ASSOCIATION: 'CONTRIBUTOR', ACTOR: 'outsider', PR_USER: 'outsider', BASE_SHA: base, HEAD_SHA: head }
  });
  assert.notEqual(resOutside.status, 0, 'DCO script must refuse an unsigned commit from an outside contributor');
  assert.match(resOutside.stdout.toString(), /lacks a valid 'Signed-off-by: Name <email>' DCO trailer/);
  git('-c', 'commit.gpgsign=false', 'commit', '-q', '--amend', '--allow-empty', '--no-edit', '-s');
  const signedHead = git('rev-parse', 'HEAD').stdout.toString().trim();
  const resSigned = spawnSync('bash', ['-c', dcoRunScript], {
    cwd: tmpRepo,
    env: { ...process.env, AUTHOR_ASSOCIATION: 'CONTRIBUTOR', ACTOR: 'outsider', PR_USER: 'outsider', BASE_SHA: base, HEAD_SHA: signedHead }
  });
  assert.equal(resSigned.status, 0, 'DCO script must accept the same commit once signed off');
  rmSync(tmpRepo, { recursive: true, force: true });

  // All 22 CLA.md files must NOT have "This is a template"
  const claPaths = [
    'bearers/android/CLA.md',
    'bearers/apple/CLA.md',
    'core/hop-core/CLA.md',
    'core/hop-wasm/CLA.md',
    'core/hop/CLA.md',
    'core/stores/hop-store-firestore/CLA.md',
    'core/stores/hop-store-sqlite/CLA.md',
    'drivers/android/hop-driver/CLA.md',
    'drivers/apple/HopDriver/CLA.md',
    'sdk/android/CLA.md',
    'sdk/apple/CLA.md',
    'sdk/compose/CLA.md',
    'sdk/crystal/CLA.md',
    'sdk/elixir/CLA.md',
    'sdk/flutter/CLA.md',
    'sdk/go/CLA.md',
    'sdk/node/CLA.md',
    'sdk/python/CLA.md',
    'sdk/ruby/CLA.md',
    'services/hop-endpoint/CLA.md',
    'services/hop-gateway/CLA.md',
    'services/hop-relayd/CLA.md',
  ];

  for (const p of claPaths) {
    const content = readRepo(p);
    assert.doesNotMatch(content, /This is a template, provided as a starting point/i, `${p} must not contain generic template disclaimer`);
  }
});

test('BIZ-016: EU SCC package and TIA documentation must exist, render as site pages, and be referenced in dpa.astro as template', () => {
  assert.equal(existsSync(resolve(repoRoot, 'docs/legal/eu-scc-package.md')), true, 'docs/legal/eu-scc-package.md must exist');
  assert.equal(existsSync(resolve(repoRoot, 'docs/legal/transfer-impact-assessment.md')), true, 'docs/legal/transfer-impact-assessment.md must exist');
  assert.equal(existsSync(resolve(repoRoot, 'apps/web/site/src/pages/legal/eu-scc-package.astro')), true, 'eu-scc-package.astro must exist');
  assert.equal(existsSync(resolve(repoRoot, 'apps/web/site/src/pages/legal/transfer-impact-assessment.astro')), true, 'transfer-impact-assessment.astro must exist');

  const scc = readRepo('docs/legal/eu-scc-package.md');
  assert.match(scc, /template/i, 'SCC package must describe itself as a template to be executed upon request');
  assert.match(scc, /never pre-executed/i, 'SCC package must state it is never pre-executed');
  assert.match(scc, /Module 2.*Controller-to-Processor/i, 'SCC package must include Module 2');
  assert.match(scc, /Module 3.*Processor-to-Processor/i, 'SCC package must include Module 3');
  assert.match(scc, /ANNEX I/i, 'SCC package must include Annex I');
  assert.match(scc, /ANNEX II/i, 'SCC package must include Annex II');

  const tia = readRepo('docs/legal/transfer-impact-assessment.md');
  assert.match(tia, /Transfer Impact Assessment/i, 'TIA must be documented');
  assert.match(tia, /FISA 702|Schrems II/i, 'TIA must address US legal regime');

  const dpa = readSite('src/pages/dpa.astro');
  assert.match(dpa, /\/legal\/eu-scc-package\//i, 'dpa.astro must reference /legal/eu-scc-package/');
  assert.match(dpa, /\/legal\/transfer-impact-assessment\//i, 'dpa.astro must reference /legal/transfer-impact-assessment/');
});

test('BIZ-017: terms and privacy must enforce minimum age floor and privacy must disclose third-party icon script', () => {
  const terms = readSite('src/pages/terms.astro');
  const privacy = readSite('src/pages/privacy.astro');

  // Age floor
  assert.match(terms, /13 years of age|18 years of age|COPPA/i, 'terms.astro must set minimum age floor');
  assert.match(privacy, /Children's Privacy|under 13|COPPA/i, 'privacy.astro must contain children privacy / age disclosure');

  // Third-party font script disclosure
  assert.match(privacy, /Font Awesome|Fonticons/i, 'privacy.astro must disclose Font Awesome third-party script');
});

test('BIZ-018: terms must include US export and OFAC sanctions representations and export compliance must be documented', () => {
  const terms = readSite('src/pages/terms.astro');
  assert.match(terms, /Export Controls?|Sanctions/i, 'terms.astro must include export control section');
  assert.match(terms, /OFAC|EAR|Specially Designated Nationals/i, 'terms.astro must include OFAC / restricted parties representation');

  assert.equal(existsSync(resolve(repoRoot, 'docs/legal/export-compliance.md')), true, 'docs/legal/export-compliance.md must exist');
  const exportDoc = readRepo('docs/legal/export-compliance.md');
  assert.match(exportDoc, /5D002|5D992|EAR99/i, 'docs/legal/export-compliance.md must document ECCN classification');
  assert.match(exportDoc, /15 C\.F\.R\.\s*§?\s*734\.7/i, 'docs/legal/export-compliance.md must document publicly available open source exemption');

  const psd = readSite('src/pages/public-safety-defense.astro');
  assert.match(psd, /export-compliance evaluation|export classification|EAR/i, 'public-safety-defense.astro must reference export evaluation');
});

test('CLAIM-020: privacy.astro and dpa.astro must accurately describe persistent Firestore KV device public key and timestamp storage', () => {
  const privacy = readSite('src/pages/privacy.astro');
  const dpa = readSite('src/pages/dpa.astro');

  // privacy.astro must disclose persistent relay KV storage of device public keys and timestamps
  assert.match(privacy, /relays\/\{node\}\/kv|device public keys and timestamps|session.*metadata/i, 'privacy.astro must disclose persistent session and device metadata in relay KV');

  // dpa.astro must disclose persistent relay KV storage
  assert.match(dpa, /relays\/\{node\}\/kv|device public keys and timestamps|session.*metadata/i, 'dpa.astro must disclose persistent session and device metadata in relay KV');
});

test('CLAIM-018: index.astro must describe universal C ABI and HopContract bindings rather than UniFFI', () => {
  const index = readSite('src/pages/index.astro');
  assert.doesNotMatch(index, /native bindings via UniFFI/i, 'index.astro must not claim native bindings via UniFFI');
  assert.match(index, /universal C ABI|HopContract/i, 'index.astro must describe universal C ABI and HopContract bindings');
});

test('CLAIM-017: sdk/elixir/mix.exs must reflect Apache-2.0 license for vendored protocol crates', () => {
  const mix = readRepo('sdk/elixir/mix.exs');
  assert.doesNotMatch(mix, /crates retain FSL/i, 'mix.exs must not claim vendored protocol crates retain FSL');
  assert.match(mix, /vendored protocol crates are Apache-2\.0/i, 'mix.exs must document vendored protocol crates as Apache-2.0');
});
