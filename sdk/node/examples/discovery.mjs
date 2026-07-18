// Proves the full DNS-free discovery chain: a client resolves a domain by name, the TLS cert proves
// the domain (WebPKI), the served reach record self-certifies the address, and the WSS handshake
// confirms it, then a hops:// round trip runs over the WebSocket. One process, a real self-signed
// HTTPS server (production uses a real cert; here we accept the self-signed one with insecureTLS).
import https from 'node:https'
import { HopEndpoint } from '../lib/endpoint.mjs'
import { selfSignedTls } from '../lib/dev-tls.mjs'

const PORT = 8443
const PUBLIC = `wss://localhost:${PORT}/_hop`

// self-signed cert for localhost, generated IN-PROCESS (no openssl CLI); production has a real WebPKI cert
const tls = selfSignedTls()

// --- the server: an existing https server, wired in ONE call ---
const server = new HopEndpoint({ name: 'orders' })
server.on('acme/orders', (req, reply) => {
  console.log(`  [server] ${req.service}/${req.method} from ${req.from.slice(0, 10)}: ${req.text}`)
  reply(201, req.args)
})
const httpsServer = https.createServer(tls)
server.attach(httpsServer, { publicUrl: PUBLIC }) // wires GET /.well-known/hop + wss /_hop
await new Promise((r) => httpsServer.listen(PORT, r))
console.log(`endpoint on https://localhost:${PORT} (well-known + wss)  addr=${server.address.slice(0, 12)}`)

// --- the client: resolve by NAME, verifying the record, then round-trip over WSS ---
const client = new HopEndpoint({ name: 'client' })
const address = await client.dialByName(`https://localhost:${PORT}`, { insecureTLS: true })
console.log(`  [client] resolved the domain -> ${address.slice(0, 12)} (reach record verified)`)

const res = await client.request(address, 'acme/orders', 'create', 'widget')
console.log(`  [client] <- ${res.status} ${res.body}`)

const ok = res.status === 201 && res.body.toString() === 'widget'
res.accept()
server.close()
client.close()
httpsServer.close()
console.log(ok ? '\nPASS: name -> verified address -> WSS hops:// round trip.' : '\nFAIL')
process.exit(ok ? 0 : 1)
