// The WSS Internet bearer: Hop's Noise transport ridden over a WebSocket, so an endpoint is reachable
// on 443 under a route (e.g. /_hop) with no new port for the operator to open. WebSocket messages
// preserve frame boundaries, so unlike the raw-TCP bearer there is no length-prefixing: one drained
// packet is one WS message. core still does the Noise handshake and all crypto over these bytes.
import { WebSocketServer, WebSocket } from 'ws'
import http from 'node:http'

const DIALER = 0
const ACCEPTOR = 1

export const MAX_MESSAGE_BYTES = 1 << 20
export const MAX_HEADER_BYTES = 16 << 10
export const MAX_PENDING_LINKS = 64
export const HANDSHAKE_TIMEOUT_MS = 5_000
export const READ_TIMEOUT_MS = 15_000

const admissionByServer = new WeakMap()
const leaseSymbol = Symbol('hop-wss-admission')

let seq = 50000
const nextLink = () => ++seq

export function asBuf(data) {
  if (Buffer.isBuffer(data)) {
    if (data.length > MAX_MESSAGE_BYTES) throw new RangeError('WebSocket message exceeds 1 MiB')
    return data
  }
  if (Array.isArray(data)) {
    let size = 0
    const parts = data.map((part) => {
      const buf = asBuf(part)
      size += buf.length
      if (size > MAX_MESSAGE_BYTES) throw new RangeError('WebSocket message exceeds 1 MiB')
      return buf
    })
    return Buffer.concat(parts, size)
  }
  const buf = Buffer.from(data)
  if (buf.length > MAX_MESSAGE_BYTES) throw new RangeError('WebSocket message exceeds 1 MiB')
  return buf
}

export function upgradeHeaderBytes(req) {
  let size = Buffer.byteLength(`${req.method ?? ''} ${req.url ?? ''} HTTP/${req.httpVersion ?? '1.1'}\r\n`)
  const raw = Array.isArray(req.rawHeaders) ? req.rawHeaders : []
  for (let i = 0; i < raw.length; i += 2) {
    size += Buffer.byteLength(String(raw[i] ?? '')) + 2
    size += Buffer.byteLength(String(raw[i + 1] ?? '')) + 2
    if (size > MAX_HEADER_BYTES) return size
  }
  return size + 2
}

function rejectUpgrade(socket, status, reason) {
  if (socket.writable) {
    socket.write(
      `HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`,
    )
  }
  socket.destroy()
}

function socketKey(socket) {
  const { localAddress, localPort, remoteAddress, remotePort } = socket
  if (!localAddress || !remoteAddress || localPort == null || remotePort == null) return null
  return `${localAddress}\0${localPort}\0${remoteAddress}\0${remotePort}`
}

function installAdmission(server, { maxPendingSockets, handshakeTimeoutMs }) {
  if (server.listening) throw new Error('Hop WSS must attach before server.listen()')
  if (admissionByServer.has(server)) throw new Error('Hop WSS is already attached to this server')
  const parserCap = server.maxHeaderSize ?? http.maxHeaderSize
  if (!Number.isInteger(parserCap) || parserCap <= 0 || parserCap > MAX_HEADER_BYTES) {
    throw new Error(`server maxHeaderSize must be configured at or below ${MAX_HEADER_BYTES} bytes`)
  }

  const pending = new Set()
  const leasesByKey = new Map()
  let closed = false

  const findLease = (socket) => {
    if (socket?.[leaseSymbol]) return socket[leaseSymbol]
    const key = socketKey(socket)
    return key == null ? undefined : leasesByKey.get(key)
  }
  const bind = (lease, socket) => {
    if (!socket || lease.released) return
    socket[leaseSymbol] = lease
    lease.sockets.add(socket)
    socket.once('error', lease.release)
    socket.once('close', lease.release)
  }
  const onConnection = (socket) => {
    if (closed || pending.size >= maxPendingSockets) {
      socket.destroy()
      return
    }
    const key = socketKey(socket)
    const lease = {
      key,
      sockets: new Set(),
      released: false,
      timer: null,
      release: null,
      close: null,
    }
    lease.release = () => {
      if (lease.released) return
      lease.released = true
      clearTimeout(lease.timer)
      pending.delete(lease)
      if (lease.key != null && leasesByKey.get(lease.key) === lease) leasesByKey.delete(lease.key)
      for (const owned of lease.sockets) {
        if (owned[leaseSymbol] === lease) delete owned[leaseSymbol]
      }
      lease.sockets.clear()
    }
    lease.close = () => {
      for (const owned of lease.sockets) owned.destroy()
      lease.release()
    }
    pending.add(lease)
    if (key != null) leasesByKey.set(key, lease)
    bind(lease, socket)
    lease.timer = setTimeout(lease.close, handshakeTimeoutMs)
    lease.timer.unref?.()
  }
  const onSecureConnection = (socket) => {
    const lease = findLease(socket)
    if (lease) bind(lease, socket)
    else socket.destroy()
  }
  const complete = (socket) => findLease(socket)?.release()
  const onRequest = (req) => complete(req.socket)
  const onUpgrade = (req) => complete(req.socket)
  const close = () => {
    if (closed) return
    closed = true
    server.off('connection', onConnection)
    server.off('secureConnection', onSecureConnection)
    server.off('request', onRequest)
    server.off('upgrade', onUpgrade)
    server.off('close', close)
    for (const lease of [...pending]) lease.close()
  }

  // prependListener runs admission before net/http or TLS starts work on the newly accepted socket.
  server.prependListener('connection', onConnection)
  server.on('secureConnection', onSecureConnection)
  server.prependListener('request', onRequest)
  server.prependListener('upgrade', onUpgrade)
  server.on('close', close)
  const admission = { pending, close }
  admissionByServer.set(server, admission)
  return admission
}

export function pendingSocketCount(server) {
  return admissionByServer.get(server)?.pending.size ?? 0
}

function bindSocket(endpoint, ws, role, release = () => {}) {
  const link = nextLink()
  let registered = false
  let finished = false
  let readTimer

  const armReadDeadline = () => {
    clearTimeout(readTimer)
    readTimer = setTimeout(() => ws.terminate(), READ_TIMEOUT_MS)
    readTimer.unref?.()
  }
  const finish = () => {
    if (finished) return
    finished = true
    clearTimeout(readTimer)
    release()
    if (registered) endpoint._linkDown(link)
  }
  const send = (buf) => {
    if (buf.length > MAX_MESSAGE_BYTES) {
      ws.terminate()
      return
    }
    if (ws.readyState === WebSocket.OPEN) ws.send(buf, { binary: true })
  }
  const register = () => {
    if (registered) return
    registered = true
    endpoint._registerLink(link, role, send)
    armReadDeadline()
  }

  ws.on('message', (data, isBinary) => {
    if (!isBinary) {
      ws.terminate()
      return
    }
    try {
      endpoint._deliver(link, asBuf(data))
      armReadDeadline()
    } catch {
      ws.terminate()
    }
  })
  ws.once('close', finish)
  ws.once('error', finish)
  return { register, finish }
}

// Hook the WebSocket upgrade on an http/https server for `path`; each accepted socket is one bearer
// link (we are the Noise acceptor). Upgrades to other paths are left for other handlers.
export function serveWss(
  endpoint,
  server,
  {
    path = '/_hop',
    maxPendingSockets = MAX_PENDING_LINKS,
    handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS,
  } = {},
) {
  if (!Number.isInteger(maxPendingSockets) || maxPendingSockets < 1) {
    throw new RangeError('maxPendingSockets must be a positive integer')
  }
  if (!Number.isFinite(handshakeTimeoutMs) || handshakeTimeoutMs <= 0) {
    throw new RangeError('handshakeTimeoutMs must be positive')
  }
  const admission = installAdmission(server, { maxPendingSockets, handshakeTimeoutMs })
  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: MAX_MESSAGE_BYTES,
    perMessageDeflate: false,
  })
  const active = new Set()
  const onUpgrade = (req, socket, head) => {
    let pathname
    try {
      pathname = new URL(req.url, 'http://x').pathname
    } catch {
      pathname = req.url
    }
    if (pathname !== path) return
    if (upgradeHeaderBytes(req) > MAX_HEADER_BYTES) {
      rejectUpgrade(socket, 431, 'Request Header Fields Too Large')
      return
    }
    if (active.size >= MAX_PENDING_LINKS) {
      rejectUpgrade(socket, 503, 'Service Unavailable')
      return
    }

    try {
      wss.handleUpgrade(req, socket, head, (ws) => {
        active.add(ws)
        const bound = bindSocket(endpoint, ws, ACCEPTOR, () => active.delete(ws))
        bound.register()
      })
    } catch {
      socket.destroy()
    }
  }
  server.on('upgrade', onUpgrade)
  endpoint._registerCloser(() => {
    admission.close()
    server.off('upgrade', onUpgrade)
    for (const ws of active) ws.terminate()
    wss.close()
  })
  return wss
}

// Dial a reachable endpoint over WSS (we are the Noise initiator). Set rejectUnauthorized:false only
// for a self-signed/dev cert; production leaves it true so WebPKI authenticates the domain.
export function dialWss(endpoint, url, { rejectUnauthorized = true } = {}) {
  const ws = new WebSocket(url, {
    rejectUnauthorized,
    maxPayload: MAX_MESSAGE_BYTES,
    maxHeaderSize: MAX_HEADER_BYTES,
    handshakeTimeout: HANDSHAKE_TIMEOUT_MS,
    perMessageDeflate: false,
  })
  const bound = bindSocket(endpoint, ws, DIALER)
  endpoint._registerCloser(() => ws.terminate())
  ws.once('open', bound.register)
  ws.on('error', (e) => endpoint.emit('error', e))
  return ws
}
