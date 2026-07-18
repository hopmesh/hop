// Calls a self-hosted Hop endpoint over TCP. The address would normally come from an HNS lookup;
// here you paste the one server.mjs printed.
//   node examples/client.mjs <server-address> [host] [port]
import { HopEndpoint } from '../lib/endpoint.mjs'
import { dial } from '../lib/tcp-bearer.mjs'

const [address, host = 'localhost', port = '9944'] = process.argv.slice(2)
if (!address) {
  console.error('usage: node examples/client.mjs <server-address> [host] [port]')
  process.exit(2)
}

const client = new HopEndpoint({ name: 'client' })
dial(client, host, Number(port))

try {
  const res = await client.request(address, 'acme/orders', 'create', { item: 'widget', qty: 3 })
  console.log(`<- ${res.status}`, res.body.toString())
  res.accept()
} catch (e) {
  console.error('request failed:', e.message)
  process.exitCode = 1
} finally {
  client.close()
}
