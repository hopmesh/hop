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

// ---- UTF-8 -----------------------------------------------------------------------------------
//
// These helpers are hand-rolled because Hermes has no `TextDecoder` (and only recent Hermes has
// `TextEncoder`), so they are the SDK's own code and need their own coverage. The decoder must be
// TOTAL: it runs inside the inbound-message accept path, where a throw stalls delivery silently
// instead of surfacing, which is exactly how the original defect stayed invisible.

test("utf8 round-trips every sequence length, including 4-byte astral code points", () => {
  const cases = [
    "",
    "a",
    "ascii only, 1 byte per char",
    "héllo mesh", // 2-byte
    "日本語のチャンネル", // 3-byte
    "\u0800\uFFFD\uFFFF", // 3-byte boundaries
    "😀🛰️🔑", // 4-byte, surrogate pairs
    "mixed: a é 日 😀 end",
    "\u{10000}\u{10FFFF}", // the astral plane's first and last code points
  ];
  for (const text of cases) {
    assert.equal(bytesToUtf8(utf8ToBytes(text)), text, JSON.stringify(text));
  }
});

test("utf8 encodes known byte sequences per RFC 3629", () => {
  assert.deepEqual(Array.from(utf8ToBytes("A")), [0x41]);
  assert.deepEqual(Array.from(utf8ToBytes("é")), [0xc3, 0xa9]);
  assert.deepEqual(Array.from(utf8ToBytes("€")), [0xe2, 0x82, 0xac]);
  assert.deepEqual(Array.from(utf8ToBytes("😀")), [0xf0, 0x9f, 0x98, 0x80]);
  // A 4-byte code point is one code point but TWO JS string units; length must not confuse them.
  assert.equal("😀".length, 2);
  assert.equal(utf8ToBytes("😀").length, 4);
});

test("utf8 decodes known byte sequences, including a surrogate pair round trip", () => {
  assert.equal(bytesToUtf8(new Uint8Array([0x41])), "A");
  assert.equal(bytesToUtf8(new Uint8Array([0xc3, 0xa9])), "é");
  assert.equal(bytesToUtf8(new Uint8Array([0xe2, 0x82, 0xac])), "€");
  const grin = bytesToUtf8(new Uint8Array([0xf0, 0x9f, 0x98, 0x80]));
  assert.equal(grin, "😀");
  assert.equal(grin.length, 2, "an astral code point decodes to a surrogate PAIR");
  assert.equal(grin.charCodeAt(0), 0xd83d);
  assert.equal(grin.charCodeAt(1), 0xde00);
});

test("utf8 preserves embedded NUL rather than terminating at it", () => {
  const text = "before\u0000after";
  const bytes = utf8ToBytes(text);
  assert.deepEqual(Array.from(bytes).indexOf(0), 6);
  assert.equal(bytes.length, 12);
  assert.equal(bytesToUtf8(bytes), text);
  // A body that is nothing but NULs must survive too (a C-string assumption would return "").
  assert.equal(bytesToUtf8(new Uint8Array([0, 0, 0])), "\u0000\u0000\u0000");
});

test("bytesToUtf8 NEVER throws on malformed input and yields replacement characters", () => {
  const malformed = [
    [0x80], // stray continuation
    [0xbf],
    [0xc0, 0x80], // overlong 2-byte
    [0xc1, 0xbf],
    [0xc2], // truncated 2-byte
    [0xe0, 0x80, 0x80], // overlong 3-byte
    [0xe0, 0xa0], // truncated 3-byte
    [0xed, 0xa0, 0x80], // UTF-16 surrogate encoded as UTF-8 (CESU-8), not valid UTF-8
    [0xed, 0xbf, 0xbf],
    [0xf0, 0x80, 0x80, 0x80], // overlong 4-byte
    [0xf0, 0x9f], // truncated 4-byte
    [0xf4, 0x90, 0x80, 0x80], // above U+10FFFF
    [0xf5, 0x80, 0x80, 0x80], // lead byte that can never be valid
    [0xff],
    [0xfe, 0xfe, 0xff, 0xff],
    [0x41, 0xff, 0x42], // good, bad, good
  ];
  for (const bytes of malformed) {
    const input = new Uint8Array(bytes);
    let decoded;
    assert.doesNotThrow(() => {
      decoded = bytesToUtf8(input);
    }, `must not throw on ${JSON.stringify(bytes)}`);
    assert.equal(typeof decoded, "string");
    assert.ok(
      decoded.includes("\uFFFD"),
      `malformed input ${JSON.stringify(bytes)} must yield U+FFFD, got ${JSON.stringify(decoded)}`,
    );
  }
});

test("bytesToUtf8 resyncs after bad bytes instead of swallowing the good data after them", () => {
  // The reason maximal-subpart resync matters: a truncated sequence must not eat the next message
  // fragment. "A", one bad byte, "B" must still show both letters.
  assert.equal(bytesToUtf8(new Uint8Array([0x41, 0xff, 0x42])), "A\uFFFDB");
  // A truncated 3-byte lead followed by ASCII: one replacement, then the ASCII.
  assert.equal(bytesToUtf8(new Uint8Array([0xe2, 0x82, 0x41])), "\uFFFDA");
  // An E0 with an out-of-range second byte: the lead is one maximal subpart, the stray
  // continuation is another, then the good byte.
  assert.equal(bytesToUtf8(new Uint8Array([0xe0, 0x80, 0x41])), "\uFFFD\uFFFDA");
  assert.equal(bytesToUtf8(new Uint8Array([0xf0, 0x9f, 0x98, 0x41])), "\uFFFDA");
});

test("utf8ToBytes turns unpaired surrogates into U+FFFD instead of emitting invalid UTF-8", () => {
  const replacement = [0xef, 0xbf, 0xbd];
  assert.deepEqual(Array.from(utf8ToBytes("\uD83D")), replacement, "lone lead surrogate");
  assert.deepEqual(Array.from(utf8ToBytes("\uDE00")), replacement, "lone trail surrogate");
  assert.deepEqual(
    Array.from(utf8ToBytes("a\uD83Db")),
    [0x61, ...replacement, 0x62],
    "lone surrogate between good characters",
  );
  // Whatever comes out must itself be decodable, which is the property that keeps a malformed JS
  // string from becoming a malformed wire body.
  assert.equal(bytesToUtf8(utf8ToBytes("a\uD83Db")), "a\uFFFDb");
});

test("utf8 handles a body large enough to exercise the decoder's chunked flush", () => {
  // The decoder batches code units and flushes in chunks; a body longer than one chunk must not
  // drop or duplicate anything at the boundary.
  const unit = "aé日😀";
  const text = unit.repeat(2000);
  const round = bytesToUtf8(utf8ToBytes(text));
  assert.equal(round.length, text.length);
  assert.equal(round, text);
});

test("the utf8 helpers do not depend on TextEncoder or TextDecoder", () => {
  // The defect this guards: Hermes has no TextDecoder, so a global reference threw ReferenceError
  // inside the accept path. Hide both globals and the helpers must still work.
  const savedEncoder = global.TextEncoder;
  const savedDecoder = global.TextDecoder;
  try {
    delete global.TextEncoder;
    delete global.TextDecoder;
    assert.equal(bytesToUtf8(utf8ToBytes("no globals here 😀 é 日")), "no globals here 😀 é 日");
    assert.deepEqual(Array.from(asBytes("é")), [0xc3, 0xa9]);
  } finally {
    if (savedEncoder !== undefined) global.TextEncoder = savedEncoder;
    if (savedDecoder !== undefined) global.TextDecoder = savedDecoder;
  }
});
