import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
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
