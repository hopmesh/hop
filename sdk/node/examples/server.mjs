// A standalone, self-hostable Hop endpoint (the two-process deployment shape). Run this, then run
// client.mjs with the address it prints. In production HNS would resolve a name to this host/port/key,
// and you would persist the key (set HOP_DB) so the address is stable across restarts.
import { HopEndpoint } from '../lib/endpoint.mjs'
import { listen } from '../lib/tcp-bearer.mjs'

const PORT = Number(process.env.PORT || 9944)
// dbPath persists the identity (and thus the address). Omit for an ephemeral demo identity.
const server = new HopEndpoint({ name: 'orders-service', dbPath: process.env.HOP_DB })

server.on('acme/orders', (req, reply) => {
  // req.from is the cryptographically VERIFIED sender, not a spoofable header. No auth middleware.
  console.log(`[server] ${req.service}/${req.method} from ${req.from.slice(0, 12)}…: ${req.text}`)
  reply(201, { ok: true, received: req.json() })
})
server.on('error', (e) => console.error('[server] error:', e.message))

await listen(server, PORT)
console.log(`hop endpoint listening on tcp://0.0.0.0:${PORT}`)
console.log(`address: ${server.address}`)
console.log(`\ntry it:\n  node examples/client.mjs ${server.address} localhost ${PORT}`)
