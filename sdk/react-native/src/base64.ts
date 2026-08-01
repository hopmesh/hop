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

/** Decode a base64 string back to raw bytes. Rejects characters outside the alphabet. */
export function fromBase64(text: string): Uint8Array {
  const clean = text.replace(/[\r\n\s]/g, "");
  if (clean.length % 4 !== 0) {
    throw new Error("invalid base64: length is not a multiple of 4");
  }
  const padding = clean.endsWith("==") ? 2 : clean.endsWith("=") ? 1 : 0;
  const out = new Uint8Array((clean.length / 4) * 3 - padding);
  let o = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const c0 = LOOKUP[clean.charCodeAt(i)];
    const c1 = LOOKUP[clean.charCodeAt(i + 1)];
    const c2 = LOOKUP[clean.charCodeAt(i + 2)];
    const c3 = LOOKUP[clean.charCodeAt(i + 3)];
    if (c0 < 0 || c1 < 0 || c2 < 0 || c3 < 0) {
      throw new Error("invalid base64: character outside the alphabet");
    }
    const triple = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
    if (o < out.length) out[o++] = (triple >> 16) & 0xff;
    if (o < out.length) out[o++] = (triple >> 8) & 0xff;
    if (o < out.length) out[o++] = triple & 0xff;
  }
  return out;
}

/** Encode a UTF-8 string as bytes (TextEncoder is available in the RN Hermes runtime and in Node). */
export function utf8ToBytes(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

/** Decode UTF-8 bytes to a string. */
export function bytesToUtf8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

/** Accept either raw bytes or a UTF-8 string and return bytes. Used by the message/body helpers. */
export function asBytes(value: Uint8Array | string): Uint8Array {
  return typeof value === "string" ? utf8ToBytes(value) : value;
}
