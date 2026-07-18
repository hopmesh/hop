// Proves the Internet bearer: a server endpoint LISTENS on a TCP port, a client endpoint DIALS it
// over a real socket, and the hops:// round trip completes over TCP with real Noise. One process,
// real loopback sockets (see server.mjs + client.mjs for the two-process deployment shape).
import { HopEndpoint } from '../lib/endpoint.mjs'
import { listen, dial } from '../lib/tcp-bearer.mjs'

const PORT = 9944

const server = new HopEndpoint({ name: 'orders' })
server.on('acme/orders', (req, reply) => {
  console.log(`  [server] ${req.service}/${req.method} from ${req.from.slice(0, 10)}… over TCP: ${req.text}`)
  reply(201, { ok: true, item: req.json().item })
})
await listen(server, PORT)
console.log(`server listening on tcp://localhost:${PORT}  addr=${server.address.slice(0, 12)}…`)

const client = new HopEndpoint({ name: 'client' })
dial(client, 'localhost', PORT) // in production: HNS resolves name -> host/port/key

// send the request by the server's ADDRESS (a client would resolve this from HNS, not share a process)
const res = await client.request(server.address, 'acme/orders', 'create', { item: 'widget' })
console.log(`  [client] <- ${res.status}`, res.body.toString())

const body = JSON.parse(res.body.toString())
const passed = res.status === 201 && body.ok === true && body.item === 'widget'
res.accept()
server.close()
client.close()
console.log(passed ? '\nPASS: hops:// round trip over a real TCP Internet bearer.' : '\nFAIL')
process.exit(passed ? 0 : 1)
