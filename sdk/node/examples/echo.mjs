// The Express/Fastify-shaped DX, running on real hop-core over the C ABI. A server endpoint
// registers a receiver; a client calls it and gets a reply. Delivery is delay-tolerant underneath.
import { HopEndpoint, connectInProcess } from '../lib/endpoint.mjs'

const server = new HopEndpoint({ name: 'orders-service' })
const client = new HopEndpoint({ name: 'client' })

// --- this is the whole server: mount a receiver, reply with a status + body ---
server.on('acme/orders', async (req, reply) => {
  console.log(`  [server] ${req.service}/${req.method} from ${req.from.slice(0, 10)}… body=${req.text}`)
  const order = req.json()
  reply(200, { ok: true, id: 42, item: order.item }) // uint16 status, JSON body
})

// wire the two endpoints together (in-process bearer; swap for TCP to make it reachable by any device)
connectInProcess(server, client)

console.log('server address:', server.address)
console.log('client address:', client.address)

// --- client calls the service, like an HTTP request, but forward-secret + delay-tolerant ---
const res = await client.request(server.address, 'acme/orders', 'create', { item: 'widget' })
console.log(`  [client] <- ${res.status}`, res.body.toString())

const body = JSON.parse(res.body.toString())
const passed = res.status === 200 && body.ok === true && body.item === 'widget'
res.accept()
server.close()
client.close()
console.log(passed ? '\nPASS: hop.on(service, handler) + reply(status, body) over real hop-core.' : '\nFAIL')
process.exit(passed ? 0 : 1)
