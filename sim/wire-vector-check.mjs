// Independent consumer for the committed deterministic bundle corpus. Every complete vector crosses
// the real wasm-bindgen boundary, is decoded, verified, and canonically re-encoded by hop-core, then
// stable metadata is compared here in JavaScript.
//
// Run after sim/build-wasm.sh:
//   node sim/wire-vector-check.mjs
import { createRequire } from 'module';
import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { validate_wire_bundle: validateWireBundle } = require(
  join(here, '../core/hop-wasm/pkg-node/hop_wasm.js'),
);
const corpus = JSON.parse(readFileSync(
  join(here, '../core/hop-core/vectors/bundle-v11.json'),
  'utf8',
));

if (corpus.bundle_version !== 11) {
  throw new Error(`expected bundle corpus version 11, got ${corpus.bundle_version}`);
}

function assertVariantSet(label, actual, expected) {
  const names = [...new Set(actual)].sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length
      || names.length !== wanted.length
      || names.some((name, index) => name !== wanted[index])) {
    throw new Error(`${label} variants ${names.join(',')} != ${wanted.join(',')}`);
  }
}

assertVariantSet(
  'destination',
  corpus.destinations.map(vector => vector.variant),
  ['Device', 'AckTo', 'Broadcast', 'Vaccine'],
);
assertVariantSet(
  'payload',
  corpus.bundles.filter(vector => vector.primary_payload).map(vector => vector.payload_variant),
  [
    'HttpRequest', 'HttpResponse', 'PeerMessage', 'SessionInit', 'SessionMessage', 'Private',
    'Ack', 'StreamOpen', 'StreamData', 'StreamAck', 'StreamClose', 'ServiceRequest',
    'ServiceResponse', 'Carrier', 'HpsJoinRequest', 'HpsKeys', 'HpsInvite',
    'HpsInviteAccept', 'HpsLeave', 'HpsRekey', 'HpsReachAck', 'HpsPublish', 'SessionReset',
  ],
);

function fromHex(value) {
  if (value.length % 2 !== 0 || !/^[0-9a-f]*$/.test(value)) {
    throw new Error('invalid lowercase hex in wire corpus');
  }
  return Uint8Array.from(value.match(/../g)?.map(byte => Number.parseInt(byte, 16)) ?? []);
}

function equalBytes(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

let checked = 0;
let stampedCount = 0;
const families = new Map();
const privateInner = [];
for (const vector of corpus.bundles) {
  const bytes = fromHex(vector.bytes_hex);
  const id = fromHex(vector.id_hex);
  const metadata = validateWireBundle(bytes, id);
  const access = fromHex(vector.access_hex);
  if (access.length === 0 || access[0] !== Number(vector.access_present)
      || (!vector.access_present && access.length !== 1)) {
    throw new Error(`${vector.name}: carriage-stamp access layout differs from corpus metadata`);
  }
  if (vector.access_present) stampedCount++;
  if (metadata.length !== 211) throw new Error(`${vector.name}: metadata length ${metadata.length}`);
  const view = new DataView(metadata.buffer, metadata.byteOffset, metadata.byteLength);
  const checks = [
    ['version', metadata[0], vector.version],
    ['destination', metadata[1], vector.destination_code],
    ['private', metadata[2], Number(vector.private)],
    ['is_ack', metadata[3], Number(vector.is_ack)],
    ['wire length', view.getUint32(4, true), bytes.length],
    ['ciphertext length', view.getUint32(8, true), fromHex(vector.ciphertext_hex).length],
    ['copies', view.getUint16(12, true), vector.copies],
    ['hops', metadata[14], vector.hops],
    ['trace length', metadata[15], vector.trace_len],
    ['created_at', view.getBigUint64(16, true), BigInt(vector.created_at)],
    ['lifetime_ms', view.getUint32(24, true), vector.lifetime_ms],
    ['hop_limit', metadata[28], vector.hop_limit],
  ];
  for (const [field, actual, expected] of checks) {
    if (actual !== expected) throw new Error(`${vector.name}: ${field} ${actual} != ${expected}`);
  }
  if (!equalBytes(metadata.slice(29, 61), id)) throw new Error(`${vector.name}: returned id differs`);
  const fixedFields = [
    ['private content id', 61, 93, vector.private_content_id_hex],
    ['recognition tag', 93, 109, vector.recognition_tag_hex],
    ['recognition ephemeral', 109, 141, vector.recognition_ephemeral_hex],
    ['private mailbox', 142, 144, vector.private_mailbox_hex],
  ];
  for (const [field, start, end, expectedHex] of fixedFields) {
    const expected = fromHex(expectedHex);
    const actual = metadata.slice(start, end);
    if (expected.length === 0) {
      if (actual.some(value => value !== 0)) throw new Error(`${vector.name}: ${field} is not zero-filled`);
    } else if (!equalBytes(actual, expected)) {
      throw new Error(`${vector.name}: ${field} differs`);
    }
  }
  if (metadata[141] !== Number(vector.private_mailbox_present)) {
    throw new Error(`${vector.name}: private mailbox presence differs`);
  }
  const integrityCodes = { Ed25519Signature: 0, PrivateWireId: 1, VaccineId: 2 };
  if (metadata[144] !== integrityCodes[vector.integrity_kind]) {
    throw new Error(`${vector.name}: integrity kind differs`);
  }
  const signature = fromHex(vector.signature_hex);
  if (view.getUint16(145, true) !== signature.length
      || !equalBytes(metadata.slice(147, 147 + signature.length), signature)) {
    throw new Error(`${vector.name}: signature differs`);
  }
  if (vector.private) privateInner.push(vector.private_inner_variant);
  checked++;
  families.set(vector.family, (families.get(vector.family) ?? 0) + 1);
}

const expectedPrivateInner = ['Ack', 'SessionInit', 'SessionMessage', 'SessionMessage'];
privateInner.sort();
if (privateInner.length !== expectedPrivateInner.length
    || privateInner.some((name, index) => name !== expectedPrivateInner[index])) {
  throw new Error(`private inner payload variants ${privateInner.join(',')} are incomplete`);
}
if (corpus.bundles.filter(vector => vector.private && !vector.private_mailbox_present).length !== 1) {
  throw new Error('expected one complete private envelope without a mailbox route');
}
if (checked !== 30) throw new Error(`expected 30 complete bundle vectors, checked ${checked}`);
if (stampedCount !== 1) throw new Error(`expected one stamped bundle vector, checked ${stampedCount}`);
const bare = corpus.bundles.find(vector => vector.name === 'traced-envelope-empty-forwarding');
const stamped = corpus.bundles.find(vector => vector.name === 'traced-envelope-carriage-stamped');
if (!bare || !stamped || bare.id_hex !== stamped.id_hex
    || bare.signature_hex !== stamped.signature_hex || bare.bytes_hex === stamped.bytes_hex) {
  throw new Error('stamped and unstamped bundle pair does not preserve signed identity');
}
console.log(`wire vectors: ${checked} complete bundles (${stampedCount} stamped) verified through WASM`);
console.log(`destinations: ${corpus.destinations.length}; primary payloads: ${corpus.bundles.filter(v => v.primary_payload).length}`);
for (const [family, count] of [...families].sort()) console.log(`  ${family}: ${count}`);
