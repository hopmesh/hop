// Discovery: bind a human name to a Hop address using the domain's TLS cert (WebPKI)
// plus a self-certifying reachability record. The endpoint serves the signed record at
// /.well-known/hop over HTTPS; a client fetches it (TLS proves the domain), verifies the record's
// signature (proves the address signed this endpoint), then dials the WSS and the Noise handshake
// confirms the address. Every link is either WebPKI-anchored or self-certifying.
import { verifyReach } from './ffi.mjs'

export const WELL_KNOWN_PATH = '/.well-known/hop'

// The JSON body an endpoint serves at /.well-known/hop. `publicUrl` is where it is reachable, e.g.
// "wss://myaddress.com/_hop"; the endpoint signs a reach record binding its address to it.
export function wellKnownBody(endpoint, publicUrl, ttlSecs = 3600) {
  const record = endpoint.signReach(publicUrl, ttlSecs) // Buffer
  return JSON.stringify({
    address: endpoint.address,
    endpoint: publicUrl,
    reach: record.toString('base64'),
  })
}

// Resolve a base HTTPS URL (e.g. "https://myaddress.com") to { address, addressBytes, wssUrl } by
// fetching + verifying its well-known. Throws if the record is missing, malformed, or fails
// verification. `fetchOpts` is passed to fetch (use { rejectUnauthorized:false } only for dev certs;
// see dialByName which threads it through).
export async function resolve(baseUrl, { fetch: fetchImpl = fetch } = {}) {
  const base = new URL(baseUrl)
  if (base.protocol !== 'https:' || !base.hostname || base.username || base.password) {
    throw new Error('discovery base URL must be an HTTPS origin without credentials')
  }
  const url = new URL(WELL_KNOWN_PATH, base)
  const res = await fetchImpl(url, { redirect: 'error' })
  if (res.url) {
    const finalUrl = new URL(res.url)
    if (finalUrl.protocol !== 'https:' || finalUrl.origin !== url.origin) {
      throw new Error('well-known fetch changed origin')
    }
  }
  if (!res.ok) throw new Error(`well-known fetch failed: HTTP ${res.status} for ${url}`)
  const body = await res.json()
  if (!body.reach) throw new Error('well-known has no `reach` record')
  const info = verifyReach(Buffer.from(body.reach, 'base64'))
  if (!info) throw new Error('reach record failed verification (bad signature or expired)')
  return { address: info.address, addressBytes: info.addressBytes, wssUrl: info.endpoint }
}
