import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
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
