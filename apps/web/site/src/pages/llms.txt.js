// /llms.txt, the curated LLM/agent brief. web-r2-06: this used to be a hand-maintained
// static file (public/llms.txt) whose per-page URLs could silently drift from the real
// pages and from the generated llms-full.txt. It is now a build-time route that derives
// every per-page URL from the SAME data as the site (protocol.js / use-cases.js / drivers.js),
// so a renamed or removed id fails the build here instead of shipping a dead link. The prose
// stays curated (an id -> one-line summary map below); a data id that has no summary, or a
// summary whose id no longer exists in the data, is a hard build error.
import { cases } from '../data/use-cases.js';
import { layers } from '../data/protocol.js';
import { drivers } from '../data/drivers.js';

const strip = (s) =>
  String(s).replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim();

// Curated ORDER + one-line summary for the subset of protocol layers we surface here (the
// full set is in llms-full.txt). Each id MUST exist in protocol.js `layers`.
const PROTOCOL = [
  ['hdp', 'hdp://, the datagram waist', 'sealed, addressed, store-and-forward datagrams; the narrow waist all traffic rides.'],
  ['hops', 'hops://, internet egress & services', 'HTTP semantics carried as sealed datagrams; reach the internet (or a specific service) from offline.'],
  ['hps', 'hps://, topic pub/sub', 'one-to-many fanout; members decrypt, non-members carry blind, reach is acknowledged.'],
  ['streams', 'streams, chunked transfer', 'large payloads split into ordered, individually-sealed chunks, reassembled across multiple peers/paths even when received out of order.'],
  ['hns', 'HNS, name resolution', 'names resolve to Hop addresses (public keys, not IPs), with TTL caching so resolution usually never reaches public DNS.'],
  ['ble', 'BLE, the primary local bearer', 'passive, no pairing; GATT for control + an L2CAP fast lane for bulk.'],
  ['bearers', 'Bearers, any transport', 'BLE and Wi-Fi/LAN today; the internet relay, long-range sub-GHz radio, and satellite fit the same trait.'],
];

// Curated summary per use case id (all cases are surfaced, in data order).
const CASE_SUMMARY = {
  messaging: 'people to people, no infrastructure.',
  sync: 'offline-first collections that converge (set reconciliation / anti-entropy).',
  files: 'any size, chunked and reassembled.',
  web: 'reach a service from no connection via sealed HTTP egress.',
  telemetry: 'data from past the edge, bridged on contact.',
  broadcast: 'one-to-many push to an area or topic, even with no tower.',
};

// Curated summary per driver id (all drivers are surfaced, in data order).
const DRIVER_SUMMARY = {
  ios: 'Swift host over CoreBluetooth (BLE GATT + L2CAP, LAN).',
  android: 'Kotlin host (BLE + Wi-Fi/LAN) with a foreground service.',
  macos: 'a desktop node and rendezvous.',
  esp32: 'embedded host for the Hop Bridge (BLE to 900 MHz, multi-firmware).',
  linux: 'the relay & backbone host (TCP/WebSocket, internet egress).',
};

function requireId(id, present, where) {
  if (!present.has(id)) {
    throw new Error(`llms.txt: '${id}' is referenced by the ${where} curation but no longer exists in the site data. Update src/pages/llms.txt.js or the data file.`);
  }
}

export async function GET() {
  const layerIds = new Set(layers.map((l) => l.id));
  const caseIds = new Set(cases.map((c) => c.id));
  const driverIds = new Set(drivers.map((d) => d.id));

  const L = [];
  L.push('# Hop', '');
  L.push(
    '> Hop is a delay-tolerant mesh network: end-to-end encrypted, store-and-forward datagrams that hop device to device, over BLE, Wi-Fi, and the internet, until they reach the person or service you meant. Held until they land or expire, not dropped for a missing network. It is the single transport layer that offline-capable apps build on, so each app doesn\'t have to rebuild intermittent-network plumbing.',
    ''
  );
  L.push(
    'Hop ships as a pure-Rust SDK (`hop-core`) with native iOS and Android bindings via UniFFI, plus an optional hosted cloud backbone. The SDK is free and runs fully peer-to-peer on its own; the managed backbone is usage-based and bridges messages across the world whenever any node touches the internet. You can also run a private backbone.',
    ''
  );
  L.push('Key design points:');
  L.push('- Delay-tolerant, not real-time: a message is held on nearby devices and re-offered at every encounter, delivered the moment a path opens (lifetime measured in hours to days). When a path is live, delivery is quick.');
  L.push('- Multipath: copies are spread across independent routes at once (epidemic forward); the first to arrive delivers and an acknowledgement cancels the rest. At-least-once with idempotency/dedup.');
  L.push('- The network finds many ways. BLE is the primary local bearer because it is passive, devices discover and relay through each other with no pairing, no taps, no setup (a deliberate trade-off: lower throughput for always-on, invisible meshing). Wi-Fi/LAN carries high-bandwidth local transfers; an internet relay bridges globally; the bearer is a pluggable trait, so the same sealed bundles ride whatever is available.');
  L.push('- Confidential by default: every payload is end-to-end encrypted (X25519 + ChaCha20-Poly1305), sealed to the destination\'s key. Relays carry ciphertext they cannot read. Identities are public keys, no phone numbers, no accounts.');
  L.push('');

  L.push('## Protocol (the stack, by layer)');
  for (const [id, label, summary] of PROTOCOL) {
    requireId(id, layerIds, 'protocol');
    L.push(`- [${label}](https://hopme.sh/protocol/${id}/): ${summary}`);
  }
  L.push('');

  L.push('## Use cases (what you build)');
  for (const c of cases) {
    requireId(c.id, new Set(Object.keys(CASE_SUMMARY)), 'use-case-summary map');
    L.push(`- [${strip(c.title)}](https://hopme.sh/use-cases/${c.id}/), ${CASE_SUMMARY[c.id]}`);
  }
  L.push('');

  L.push('## Where it runs (verticals)');
  L.push('- [Business](https://hopme.sh/business/), events & venues, field operations, maritime, rural, response, industrial.');
  L.push('- [Public safety & defense](https://hopme.sh/public-safety-defense/), comms across denied, degraded, intermittent, limited (DDIL) environments; private fleets, on-prem, no internet required.');
  L.push('- [Hop Bridge](https://hopme.sh/lora/), a small ESP32 device bridging BLE to a long-range 900 MHz radio; multi-firmware (LoRa is one waveform of several on the same chipset).');
  L.push('');

  L.push('## Drivers (docs, the per-platform hosts)');
  L.push('hop-core has no bearer system of its own; it only moves bytes. A driver is the per-platform host that embeds the core and runs the radios (it implements the bearer trait). Docs hub: https://hopme.sh/docs/');
  for (const d of drivers) {
    requireId(d.id, new Set(Object.keys(DRIVER_SUMMARY)), 'driver-summary map');
    requireId(d.id, driverIds, 'drivers data');
    L.push(`- [${strip(d.name)}](https://hopme.sh/docs/drivers/${d.id}/), ${DRIVER_SUMMARY[d.id]}`);
  }
  L.push('');

  L.push('## For developers');
  L.push('- [Developers](https://hopme.sh/developers/), embed the core; reach a device by key, or the internet.');
  L.push('- [Quickstart](https://hopme.sh/docs/quickstart/), add the dependency, open a node from a secret, send, receive.');
  L.push('- [Pricing](https://hopme.sh/pricing/), free SDK; usage-based managed backbone.');
  L.push('- [FAQ](https://hopme.sh/faq/), latency, privacy, message size, offline delivery, battery, platforms, licensing.');
  L.push('');

  L.push('## Facts');
  L.push('- Licensing: two-tier and per-component. The hosted services (services/*: relay, endpoint, gateway, telemetry, account, billing) are source-available under FSL-1.1-ALv2 and convert to Apache-2.0 after two years; the protocol core, the SDKs, the bearers and the drivers are Apache-2.0. The protocol itself is never monetized; revenue comes from the hosted cloud backbone (usage-based) and commercial licensing.');
  L.push('- Platforms: pure-Rust core (deterministic, testable without a radio) with iOS and Android bindings via UniFFI.');
  L.push('- Billing meters counts and bytes on the sealed envelope, never content.');
  L.push('- Contact: hello@hopme.sh');

  // Every protocol id we surfaced must still be a real layer (URL freshness).
  for (const [id] of PROTOCOL) requireId(id, layerIds, 'protocol layers data');

  return new Response(L.join('\n') + '\n', {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
}
