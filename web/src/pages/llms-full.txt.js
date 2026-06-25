// /llms-full.txt — the expanded LLM/agent brief, generated at build time from the
// same data the site renders, so it never drifts. Companion to the curated
// public/llms.txt. Plain-text markdown, served at https://hopme.sh/llms-full.txt
import { cases } from '../data/use-cases.js';
import { layers, groups } from '../data/protocol.js';
import { drivers } from '../data/drivers.js';

const strip = (s) =>
  String(s).replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim();

export async function GET() {
  const L = [];
  L.push('# Hop — full reference for language models', '');
  L.push(
    '> Hop is a delay-tolerant mesh network: end-to-end encrypted, store-and-forward datagrams that hop device to device — over BLE, Wi-Fi, and the internet — until they reach the person or service you meant. Held, never dropped. The single transport layer offline-capable apps build on.'
  );
  L.push('', 'Short version: https://hopme.sh/llms.txt', '');

  L.push('## What you build (use cases)', '');
  for (const c of cases) {
    L.push(`### ${strip(c.title)} — https://hopme.sh/use-cases/${c.id}/`);
    L.push(strip(c.tagline));
    for (const p of c.body) L.push(strip(p));
    L.push('');
  }

  L.push('## Protocol stack (by layer)', '');
  for (const g of groups) {
    L.push(`### ${g}`, '');
    for (const l of layers.filter((x) => x.group === g)) {
      L.push(`#### ${strip(l.name)} — https://hopme.sh/protocol/${l.id}/`);
      L.push(strip(l.tagline));
      if (l.how) for (const h of l.how) L.push('- ' + strip(h));
      if (l.dev) L.push('For developers: ' + strip(l.dev));
      if (l.biz) L.push('For business: ' + strip(l.biz));
      L.push('');
    }
  }

  L.push('## Drivers (per-platform hosts that drive the radios)', '');
  L.push(
    'hop-core has no bearer system; it only moves bytes. A driver embeds the core and implements the bearer trait (send_frame / recv_frame / peer_events) for one platform — owning discovery, connections, background operation, and power.',
    ''
  );
  for (const h of drivers) {
    L.push(`### ${strip(h.name)} (${h.status}) — https://hopme.sh/docs/drivers/${h.id}/`);
    L.push(strip(h.tagline));
    L.push(strip(h.summary));
    L.push('Bearers: ' + h.bearers.map(strip).join('; '));
    for (const n of h.notes) L.push('- ' + strip(n));
    L.push('');
  }

  L.push(
    '## Licensing & facts',
    '- The SDK is source-available under FSL-1.1-ALv2 and converts to Apache-2.0 after two years; the protocol itself is never monetized.',
    '- Revenue comes from the hosted cloud backbone (usage-based) and commercial licensing.',
    '- Pure-Rust core (deterministic, testable without a radio) with iOS and Android bindings via UniFFI.',
    '- End-to-end encrypted (X25519 + ChaCha20-Poly1305); identities are public keys, not phone numbers or accounts.',
    '- BLE is the primary local bearer (passive, no pairing); Wi-Fi/LAN and an internet relay extend reach; multipath binary spray-and-wait; at-least-once with dedup.',
    '- Contact: hello@hopme.sh'
  );

  return new Response(L.join('\n') + '\n', {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
