"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");

const { toBase64, fromBase64, utf8ToBytes, bytesToUtf8, asBytes } = require("../lib/base64.js");

test("base64 encodes known vectors (RFC 4648)", () => {
  assert.equal(toBase64(utf8ToBytes("")), "");
  assert.equal(toBase64(utf8ToBytes("f")), "Zg==");
  assert.equal(toBase64(utf8ToBytes("fo")), "Zm8=");
  assert.equal(toBase64(utf8ToBytes("foo")), "Zm9v");
  assert.equal(toBase64(utf8ToBytes("foob")), "Zm9vYg==");
  assert.equal(toBase64(utf8ToBytes("fooba")), "Zm9vYmE=");
  assert.equal(toBase64(utf8ToBytes("foobar")), "Zm9vYmFy");
});

test("base64 round-trips arbitrary bytes including high bytes and 32-byte ids", () => {
  for (const len of [0, 1, 2, 3, 16, 31, 32, 33, 255]) {
    const bytes = new Uint8Array(len);
    for (let i = 0; i < len; i += 1) bytes[i] = (i * 37 + 251) & 0xff;
    const round = fromBase64(toBase64(bytes));
    assert.deepEqual(Array.from(round), Array.from(bytes), `len ${len}`);
  }
});

test("fromBase64 rejects malformed input", () => {
  assert.throws(() => fromBase64("Zg="), /multiple of 4/);
  assert.throws(() => fromBase64("****"), /outside the alphabet/);
});

test("utf8 round-trips and asBytes accepts strings and bytes", () => {
  assert.equal(bytesToUtf8(utf8ToBytes("héllo mesh")), "héllo mesh");
  assert.deepEqual(Array.from(asBytes("ab")), [97, 98]);
  const raw = new Uint8Array([1, 2, 3]);
  assert.equal(asBytes(raw), raw);
});
