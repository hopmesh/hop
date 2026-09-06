// Dependency-free base64 <-> bytes helpers. The native bridge (Kotlin/Swift <-> JS) can only carry
// JSON-safe scalars, so every binary field (bodies, 32-byte addresses, bundle/request ids) crosses as
// a base64 string. These helpers are the single encode/decode point on the JS side; keep them pure so
// the rest of the SDK stays testable without React Native present.

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const LOOKUP: number[] = (() => {
  const table = new Array<number>(256).fill(-1);
  for (let i = 0; i < ALPHABET.length; i += 1) {
    table[ALPHABET.charCodeAt(i)] = i;
  }
  table["=".charCodeAt(0)] = 0;
  return table;
})();

/** Encode raw bytes as a standard (padded) base64 string. */
export function toBase64(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += ALPHABET[b0 >> 2];
    out += ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)];
    out += i + 1 < bytes.length ? ALPHABET[((b1 & 0x0f) << 2) | (b2 >> 6)] : "=";
    out += i + 2 < bytes.length ? ALPHABET[b2 & 0x3f] : "=";
  }
  return out;
}

/** Decode a base64 string back to raw bytes. Rejects characters outside the alphabet. Enforces maxBytes (default 65536). */
export function fromBase64(text: string, maxBytes: number = 65536): Uint8Array {
  const clean = text.replace(/[\r\n\s]/g, "");
  if (clean.length % 4 !== 0) {
    throw new Error("invalid base64: length is not a multiple of 4");
  }
  const padding = clean.endsWith("==") ? 2 : clean.endsWith("=") ? 1 : 0;
  if (clean.includes("=")) {
    const firstEq = clean.indexOf("=");
    if (padding === 0 || firstEq < clean.length - padding) {
      throw new Error("invalid base64: character outside the alphabet");
    }
  }
  const decodedLen = (clean.length / 4) * 3 - padding;
  if (decodedLen > maxBytes) {
    throw new Error(`base64 payload exceeds maximum envelope (${decodedLen} > ${maxBytes})`);
  }
  const out = new Uint8Array(decodedLen);
  let o = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const code0 = clean.charCodeAt(i);
    const code1 = clean.charCodeAt(i + 1);
    const code2 = clean.charCodeAt(i + 2);
    const code3 = clean.charCodeAt(i + 3);
    if (code0 > 255 || code1 > 255 || code2 > 255 || code3 > 255) {
      throw new Error("invalid base64: character outside the alphabet");
    }
    const c0 = LOOKUP[code0];
    const c1 = LOOKUP[code1];
    const c2 = LOOKUP[code2];
    const c3 = LOOKUP[code3];
    if (c0 === undefined || c0 < 0 || c1 === undefined || c1 < 0 || c2 === undefined || c2 < 0 || c3 === undefined || c3 < 0) {
      throw new Error("invalid base64: character outside the alphabet");
    }
    const triple = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
    if (o < out.length) out[o++] = (triple >> 16) & 0xff;
    if (o < out.length) out[o++] = (triple >> 8) & 0xff;
    if (o < out.length) out[o++] = triple & 0xff;
  }
  return out;
}

// UTF-8 <-> string, hand-rolled for the same reason as the base64 helpers above: this module must
// not depend on anything the host runtime happens to provide.
//
// `TextDecoder` is NOT in the React Native Hermes runtime, so `new TextDecoder()` throws
// `ReferenceError` there. `TextEncoder` is present in RECENT Hermes only, which is not the same
// claim: this package's peer range is `react-native: "*"`, so an app on an older Hermes has
// neither. The previous code used both globals on the strength of the encoder appearing to work,
// and the decoder's throw landed inside the inbound-message accept path, where it turned every
// received item into a silent redelivery loop rather than a visible error. Both directions are
// therefore implemented here, and the decoder is deliberately total: it never throws.

/** Encode a string as UTF-8 bytes. Lone surrogates encode as U+FFFD, matching `TextEncoder`. */
export function utf8ToBytes(text: string): Uint8Array {
  // Two passes so the result is allocated exactly once at exactly the right size.
  let size = 0;
  for (let i = 0; i < text.length; i += 1) {
    const cp = codePointAt(text, i);
    if (cp > 0xffff) i += 1; // consumed a surrogate pair
    size += cp <= 0x7f ? 1 : cp <= 0x7ff ? 2 : cp <= 0xffff ? 3 : 4;
  }
  const out = new Uint8Array(size);
  let o = 0;
  for (let i = 0; i < text.length; i += 1) {
    const cp = codePointAt(text, i);
    if (cp > 0xffff) i += 1;
    if (cp <= 0x7f) {
      out[o++] = cp;
    } else if (cp <= 0x7ff) {
      out[o++] = 0xc0 | (cp >> 6);
      out[o++] = 0x80 | (cp & 0x3f);
    } else if (cp <= 0xffff) {
      out[o++] = 0xe0 | (cp >> 12);
      out[o++] = 0x80 | ((cp >> 6) & 0x3f);
      out[o++] = 0x80 | (cp & 0x3f);
    } else {
      out[o++] = 0xf0 | (cp >> 18);
      out[o++] = 0x80 | ((cp >> 12) & 0x3f);
      out[o++] = 0x80 | ((cp >> 6) & 0x3f);
      out[o++] = 0x80 | (cp & 0x3f);
    }
  }
  return out;
}

/**
 * The code point at `i`, combining a well-formed surrogate pair. An unpaired surrogate (either
 * half) yields U+FFFD, so a malformed JS string encodes to valid UTF-8 instead of garbage.
 */
function codePointAt(text: string, i: number): number {
  const unit = text.charCodeAt(i);
  if (unit < 0xd800 || unit > 0xdfff) return unit;
  if (unit >= 0xdc00) return 0xfffd; // trailing surrogate with no lead
  const next = i + 1 < text.length ? text.charCodeAt(i + 1) : 0;
  if (next < 0xdc00 || next > 0xdfff) return 0xfffd; // lead with no trail
  return 0x10000 + ((unit - 0xd800) << 10) + (next - 0xdc00);
}

/**
 * Decode UTF-8 bytes to a string. TOTAL: never throws. Malformed input yields U+FFFD replacement
 * characters exactly where a WHATWG decoder puts them, because this runs inside the accept path of
 * inbound messages, where a throw silently stalls delivery instead of surfacing.
 *
 * Rejects, as replacement characters, everything the spec calls malformed: overlong encodings,
 * surrogate code points, values above U+10FFFF, stray or missing continuation bytes. On a bad
 * sequence it emits one U+FFFD for the maximal valid subpart and re-examines the offending byte,
 * so a truncated sequence followed by good data does not swallow the good data.
 */
export function bytesToUtf8(bytes: Uint8Array): string {
  let out = "";
  let units: number[] = [];
  const flush = () => {
    // Chunked so a large body cannot exhaust the argument limit of `apply`.
    out += String.fromCharCode.apply(null, units);
    units = [];
  };
  const push = (cp: number) => {
    if (cp > 0xffff) {
      const v = cp - 0x10000;
      units.push(0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff));
    } else {
      units.push(cp);
    }
    if (units.length >= 0x1000) flush();
  };

  let i = 0;
  while (i < bytes.length) {
    const b0 = bytes[i];
    if (b0 <= 0x7f) {
      push(b0);
      i += 1;
      continue;
    }
    // Sequence length, plus the legal range of the SECOND byte. The second byte's range is
    // narrowed for C0/C1 (overlong), E0 (overlong), ED (surrogates), F0 (overlong) and F4 (> max),
    // which is what makes those sequences malformed rather than merely unusual.
    let needed: number;
    let lower = 0x80;
    let upper = 0xbf;
    let cp: number;
    if (b0 >= 0xc2 && b0 <= 0xdf) {
      needed = 1;
      cp = b0 & 0x1f;
    } else if (b0 >= 0xe0 && b0 <= 0xef) {
      needed = 2;
      cp = b0 & 0x0f;
      if (b0 === 0xe0) lower = 0xa0;
      if (b0 === 0xed) upper = 0x9f;
    } else if (b0 >= 0xf0 && b0 <= 0xf4) {
      needed = 3;
      cp = b0 & 0x07;
      if (b0 === 0xf0) lower = 0x90;
      if (b0 === 0xf4) upper = 0x8f;
    } else {
      // A stray continuation byte (0x80-0xBF), an overlong lead (0xC0/0xC1), or 0xF5-0xFF.
      push(0xfffd);
      i += 1;
      continue;
    }
    let consumed = 0;
    let ok = true;
    for (let k = 1; k <= needed; k += 1) {
      const b = i + k < bytes.length ? bytes[i + k] : -1;
      const lo = k === 1 ? lower : 0x80;
      const hi = k === 1 ? upper : 0xbf;
      if (b < lo || b > hi) {
        ok = false;
        break;
      }
      cp = (cp << 6) | (b & 0x3f);
      consumed = k;
    }
    if (!ok) {
      // Maximal subpart: consume only the bytes that were valid so far and re-read the rest, so
      // the byte that broke the sequence still gets judged on its own.
      push(0xfffd);
      i += 1 + consumed;
      continue;
    }
    push(cp);
    i += 1 + needed;
  }
  flush();
  return out;
}

/** Accept either raw bytes or a UTF-8 string and return bytes. Used by the message/body helpers. */
export function asBytes(value: Uint8Array | string): Uint8Array {
  return typeof value === "string" ? utf8ToBytes(value) : value;
}
