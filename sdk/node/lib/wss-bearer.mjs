// The WSS Internet bearer: Hop's Noise transport ridden over a WebSocket, so an endpoint is reachable
// on 443 under a route (e.g. /_hop) with no new port for the operator to open. WebSocket messages
// preserve frame boundaries, so unlike the raw-TCP bearer there is no length-prefixing: one drained
// packet is one WS message. core still does the Noise handshake and all crypto over these bytes.
import { WebSocketServer, WebSocket } from 'ws'

const DIALER = 0
const ACCEPTOR = 1

let seq = 50000
const nextLink = () => ++seq

function asBuf(data, isBinary) {
  if (Buffer.isBuffer(data)) return data
  if (Array.isArray(data)) return Buffer.concat(data.map((d) => asBuf(d, isBinary)))
  return Buffer.from(data)
}

// Hook the WebSocket upgrade on an http/https server for `path`; each accepted socket is one bearer
// link (we are the Noise acceptor). Upgrades to other paths are left for other handlers.
export function serveWss(endpoint, server, { path = '/_hop' } = {}) {
  const wss = new WebSocketServer({ noServer: true })
  server.on('upgrade', (req, socket, head) => {
    let pathname
    try {
      pathname = new URL(req.url, 'http://x').pathname
    } catch {
      pathname = req.url
    }
    if (pathname !== path) return
    wss.handleUpgrade(req, socket, head, (ws) => {
      const link = nextLink()
      endpoint._registerLink(link, ACCEPTOR, (buf) => {
        if (ws.readyState === WebSocket.OPEN) ws.send(buf)
      })
      ws.on('message', (data, isBinary) => endpoint._deliver(link, asBuf(data, isBinary)))
      ws.on('close', () => endpoint._linkDown(link))
      ws.on('error', () => endpoint._linkDown(link))
    })
  })
  return wss
}

// Dial a reachable endpoint over WSS (we are the Noise initiator). Set rejectUnauthorized:false only
// for a self-signed/dev cert; production leaves it true so WebPKI authenticates the domain.
export function dialWss(endpoint, url, { rejectUnauthorized = true } = {}) {
  const ws = new WebSocket(url, { rejectUnauthorized })
  endpoint._registerCloser(() => ws.close()) // close() ends this dialed link
  const link = nextLink()
  ws.on('open', () =>
    endpoint._registerLink(link, DIALER, (buf) => {
      if (ws.readyState === WebSocket.OPEN) ws.send(buf)
    }),
  )
  ws.on('message', (data, isBinary) => endpoint._deliver(link, asBuf(data, isBinary)))
  ws.on('close', () => endpoint._linkDown(link))
  ws.on('error', (e) => endpoint.emit('error', e))
  return ws
}
