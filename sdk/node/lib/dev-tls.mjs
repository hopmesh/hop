// DEV/TEST ONLY: an in-process self-signed cert for the discovery example (no openssl CLI, no deps).
// Node's `crypto` generates keys + signs but does not build X.509 certs, so we DER-encode a minimal
// self-signed v3 certificate by hand and sign it with SHA256-RSA. Never use a self-signed cert in
// production; there a real WebPKI cert proves the domain.
import crypto from 'node:crypto'

// ---- minimal DER (ASN.1) writers ----
const lenOf = (n) => {
  if (n < 0x80) return Buffer.from([n])
  const b = []
  while (n > 0) {
    b.unshift(n & 0xff)
    n >>= 8
  }
  return Buffer.from([0x80 | b.length, ...b])
}
const tlv = (tag, content) => Buffer.concat([Buffer.from([tag]), lenOf(content.length), content])
const int = (buf) => tlv(0x02, buf[0] & 0x80 ? Buffer.concat([Buffer.from([0]), buf]) : buf) // positive
const smallInt = (n) => int(Buffer.from([n]))
const seq = (...items) => tlv(0x30, Buffer.concat(items))
const set = (...items) => tlv(0x31, Buffer.concat(items))
const nullDer = tlv(0x05, Buffer.alloc(0))
const utf8 = (s) => tlv(0x0c, Buffer.from(s, 'utf8'))
const ctx = (n, content) => tlv(0xa0 | n, content) // context [n] EXPLICIT
const bitString = (buf) => tlv(0x03, Buffer.concat([Buffer.from([0]), buf])) // 0 unused bits
const oid = (str) => {
  const p = str.split('.').map(Number)
  const bytes = [40 * p[0] + p[1]]
  for (let i = 2; i < p.length; i++) {
    let v = p[i]
    const stack = [v & 0x7f]
    v >>= 7
    while (v > 0) {
      stack.unshift((v & 0x7f) | 0x80)
      v >>= 7
    }
    bytes.push(...stack)
  }
  return tlv(0x06, Buffer.from(bytes))
}
const utcTime = (date) => tlv(0x17, Buffer.from(`${date.toISOString().replace(/[-:T]/g, '').slice(2, 14)}Z`, 'ascii'))
const pem = (der, label) => `-----BEGIN ${label}-----\n${der.toString('base64').replace(/(.{64})/g, '$1\n')}\n-----END ${label}-----\n`

// Returns { key, cert } PEM strings for https.createServer (EC/RSA self-signed, CN=<cn>, 1h).
export function selfSignedTls(cn = 'localhost') {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 })
  const spki = publicKey.export({ type: 'spki', format: 'der' }) // a complete SubjectPublicKeyInfo
  const sigAlg = seq(oid('1.2.840.113549.1.1.11'), nullDer) // sha256WithRSAEncryption
  const name = seq(set(seq(oid('2.5.4.3'), utf8(cn)))) // CN=<cn>
  const now = new Date()
  const validity = seq(utcTime(new Date(now - 60_000)), utcTime(new Date(now.getTime() + 3_600_000)))
  const tbs = seq(ctx(0, smallInt(2)), smallInt(1), sigAlg, name, validity, name, spki) // v3, serial 1, self-signed
  const signature = crypto.sign('sha256', tbs, privateKey) // PKCS#1 v1.5 RSA
  const cert = seq(tbs, sigAlg, bitString(signature))
  return { key: privateKey.export({ type: 'pkcs8', format: 'pem' }), cert: pem(cert, 'CERTIFICATE') }
}
