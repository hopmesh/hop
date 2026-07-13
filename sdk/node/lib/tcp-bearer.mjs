// The Internet bearer: makes an endpoint reachable by any device over TCP. This is all it takes to
// turn "opaque frames over a link" into a public transport, core still does the Noise handshake and
// all crypto over these bytes; TCP just moves them. HNS would resolve a name to {host, port, key};
// here you pass host/port directly.
//
// TCP is a stream, but hop_bytes_received wants whole frames, so we length-prefix (4-byte BE) each
// drained packet and reassemble on the far side.
import net from 'node:net'

const DIALER = 0
const ACCEPTOR = 1

const frame = (b) => {
  const h = Buffer.alloc(4)
  h.writeUInt32BE(b.length, 0)
  return Buffer.concat([h, b])
}
function deframer() {
  let buf = Buffer.alloc(0)
  return (chunk) => {
    buf = Buffer.concat([buf, chunk])
    const frames = []
    while (buf.length >= 4) {
      const len = buf.readUInt32BE(0)
      if (buf.length < 4 + len) break
      frames.push(buf.subarray(4, 4 + len))
      buf = buf.subarray(4 + len)
    }
    return frames
  }
}

let LINK_SEQ = 40000

// Listen for inbound Hop connections. Every accepted socket becomes one bearer link (we are the
// Noise responder). Returns the net.Server.
export function listen(endpoint, port, { host = '0.0.0.0' } = {}) {
  const server = net.createServer((socket) => {
    const link = LINK_SEQ++
    const deframe = deframer()
    endpoint._registerLink(link, ACCEPTOR, (buf) => socket.write(frame(buf)))
    socket.on('data', (chunk) => {
      for (const f of deframe(chunk)) endpoint._deliver(link, f)
    })
    socket.on('close', () => endpoint._linkDown(link))
    socket.on('error', () => endpoint._linkDown(link))
  })
  endpoint._registerCloser(() => server.close()) // close() stops accepting new connections
  return new Promise((resolve) => server.listen(port, host, () => resolve(server)))
}

// Dial a reachable endpoint (we are the Noise initiator). Returns the socket.
export function dial(endpoint, host, port) {
  const link = LINK_SEQ++
  const deframe = deframer()
  const socket = net.connect(port, host)
  endpoint._registerCloser(() => socket.destroy()) // close() ends this link's read side
  socket.on('connect', () => endpoint._registerLink(link, DIALER, (buf) => socket.write(frame(buf))))
  socket.on('data', (chunk) => {
    for (const f of deframe(chunk)) endpoint._deliver(link, f)
  })
  socket.on('close', () => endpoint._linkDown(link))
  socket.on('error', (e) => endpoint.emit('error', e))
  return socket
}
