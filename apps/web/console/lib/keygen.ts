// Client-side carriage-key generation. The keypair is minted in the browser with WebCrypto; only the
// PUBLIC key (64-hex Ed25519) is ever sent to the server (registered via /keys/carriage), and the
// PRIVATE key is handed to the operator ONCE for download and never leaves their machine. This is the
// zero-custody model: the console never sees a private key.

const HEX = Array.from({ length: 256 }, (_, i) => i.toString(16).padStart(2, "0"));
function toHex(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += HEX[b];
  return s;
}
function toPem(der: Uint8Array, label: string): string {
  let b64 = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < der.length; i += CHUNK) {
    b64 += String.fromCharCode(...der.subarray(i, i + CHUNK));
  }
  b64 = btoa(b64);
  const lines = b64.match(/.{1,64}/g) ?? [b64];
  return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----\n`;
}

export type CarriageKeypair = { pubkeyHex: string; privatePem: string };

/** Mint an Ed25519 carriage keypair in-browser. Returns the 64-hex public key to register and the
 *  PKCS#8 PEM private key to hand to the operator once (kept on their own infrastructure). */
export async function generateCarriageKeypair(): Promise<CarriageKeypair> {
  const kp = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const rawPub = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey));
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
  return { pubkeyHex: toHex(rawPub), privatePem: toPem(pkcs8, "PRIVATE KEY") };
}

/** Whether this browser can mint an Ed25519 key (a graceful check before offering generation). */
export async function ed25519Supported(): Promise<boolean> {
  try {
    await crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"]);
    return true;
  } catch {
    return false;
  }
}

/** Trigger a browser download of `text` as `filename`. */
export function downloadText(filename: string, text: string): void {
  const blob = new Blob([text], { type: "application/x-pem-file" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}
