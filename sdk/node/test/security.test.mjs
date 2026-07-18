import assert from 'node:assert/strict'
import { EventEmitter, once } from 'node:events'
import http from 'node:http'
import https from 'node:https'
import net from 'node:net'
import tls from 'node:tls'
import test from 'node:test'
import { WebSocket } from 'ws'
import { resolve } from '../lib/discovery.mjs'
import { HopEndpoint, connectInProcess, raw } from '../lib/endpoint.mjs'
import { selfSignedTls } from '../lib/dev-tls.mjs'
import { listen, MAX_FRAME_BYTES } from '../lib/tcp-bearer.mjs'
import {
  HANDSHAKE_TIMEOUT_MS,
  MAX_HEADER_BYTES,
  MAX_MESSAGE_BYTES,
  MAX_PENDING_LINKS,
  asBuf,
  pendingSocketCount,
  serveWss,
  upgradeHeaderBytes,
} from '../lib/wss-bearer.mjs'

class FakeWssEndpoint extends EventEmitter {
  constructor() {
    super()
    this.closers = []
    this.deliveries = []
    this.links = new Set()
  }

  _registerCloser(fn) { this.closers.push(fn) }
  _registerLink(link) { this.links.add(link) }
  _deliver(link, bytes) {
    this.deliveries.push([link, bytes])
    this.emit('delivery', bytes)
  }
  _linkDown(link) { this.links.delete(link) }
  close() {
    for (const closer of this.closers.splice(0)) closer()
  }
}

async function wssFixture({ secure = false, maxPendingSockets, handshakeTimeoutMs } = {}) {
  const endpoint = new FakeWssEndpoint()
  const server = secure ? https.createServer(selfSignedTls()) : http.createServer()
  serveWss(endpoint, server, { maxPendingSockets, handshakeTimeoutMs })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const { port } = server.address()
  return {
    endpoint,
    server,
    url: `${secure ? 'wss' : 'ws'}://127.0.0.1:${port}/_hop`,
    async close() {
      endpoint.close()
      if (server.listening) await new Promise((resolveClose) => server.close(resolveClose))
    },
  }
}

async function openWs(url) {
  const ws = new WebSocket(url, {
    handshakeTimeout: HANDSHAKE_TIMEOUT_MS,
    rejectUnauthorized: false,
  })
  await once(ws, 'open')
  return ws
}

async function waitFor(predicate, message) {
  const deadline = Date.now() + 2_000
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(message)
    await new Promise((resolveWait) => setTimeout(resolveWait, 5))
  }
}

async function waitForSocketClose(socket) {
  if (socket.destroyed) return
  await new Promise((resolveClose) => {
    socket.once('close', resolveClose)
    socket.once('error', () => {})
  })
}

async function rawRequest(port, request) {
  const socket = net.createConnection({ host: '127.0.0.1', port })
  socket.end(request)
  let response = ''
  socket.setEncoding('latin1')
  socket.on('data', (chunk) => { response += chunk })
  await once(socket, 'close')
  return response
}

test('discovery rejects plaintext before fetching', async () => {
  let fetched = false
  await assert.rejects(resolve('http://example.com', { fetch: async () => { fetched = true } }))
  assert.equal(fetched, false)
})

test('TCP listener closes on an oversized header without a body', async () => {
  const closers = []
  const endpoint = {
    _registerCloser: (fn) => closers.push(fn),
    _registerLink() {},
    _deliver() { assert.fail('oversized frame was delivered') },
    _linkDown() {},
  }
  const server = await listen(endpoint, 0, { host: '127.0.0.1' })
  const socket = net.connect(server.address().port, '127.0.0.1')
  await new Promise((resolveConnect) => socket.once('connect', resolveConnect))
  const header = Buffer.alloc(4)
  header.writeUInt32BE(MAX_FRAME_BYTES + 1)
  socket.write(header)
  await new Promise((resolveClose, reject) => {
    const timer = setTimeout(() => reject(new Error('oversized connection remained open')), 1000)
    socket.once('close', () => { clearTimeout(timer); resolveClose() })
  })
  for (const close of closers) close()
})

test('WSS rejects oversized single and fragmented messages before delivery, then recovers', async () => {
  const fixture = await wssFixture()
  try {
    const single = await openWs(fixture.url)
    single.send(Buffer.alloc(MAX_MESSAGE_BYTES + 1))
    await once(single, 'close')

    const fragmented = await openWs(fixture.url)
    fragmented.send(Buffer.alloc(MAX_MESSAGE_BYTES / 2 + 1), { binary: true, fin: false })
    fragmented.send(Buffer.alloc(MAX_MESSAGE_BYTES / 2), { binary: true, fin: true })
    await once(fragmented, 'close')
    assert.equal(fixture.endpoint.deliveries.length, 0)

    const valid = await openWs(fixture.url)
    const delivered = once(fixture.endpoint, 'delivery')
    valid.send(Buffer.from('valid-after-hostile'))
    const [payload] = await delivered
    assert.equal(payload.toString(), 'valid-after-hostile')
    valid.close()
    await once(valid, 'close')
  } finally {
    await fixture.close()
  }
})

test('WSS bounds external-server upgrade headers before handleUpgrade', async () => {
  const fixture = await wssFixture()
  try {
    const { port } = fixture.server.address()
    const response = await rawRequest(
      port,
      `GET /_hop HTTP/1.1\r\nHost: localhost\r\nX-Fill: ${'x'.repeat(MAX_HEADER_BYTES)}\r\n` +
        'Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n' +
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n',
    )
    assert.match(response, /^HTTP\/1\.1 431 /)
    assert.equal(fixture.endpoint.links.size, 0)
    assert.ok(upgradeHeaderBytes({ method: 'GET', url: '/_hop', rawHeaders: ['x', 'y'] }) < MAX_HEADER_BYTES)
  } finally {
    await fixture.close()
  }
})

test('WSS rejects unsafe parser configuration and attachment after listen', async () => {
  const endpoint = new FakeWssEndpoint()
  const oversized = http.createServer({ maxHeaderSize: MAX_HEADER_BYTES + 1 })
  assert.throws(() => serveWss(endpoint, oversized), /maxHeaderSize/)

  const running = http.createServer()
  running.listen(0, '127.0.0.1')
  await once(running, 'listening')
  try {
    assert.throws(() => serveWss(endpoint, running), /before server\.listen/)
  } finally {
    await new Promise((resolveClose) => running.close(resolveClose))
  }
})

test('WSS raw admission releases ordinary HTTP traffic without intercepting it', async () => {
  const endpoint = new FakeWssEndpoint()
  const server = http.createServer((_req, res) => res.end('ordinary-app-response'))
  serveWss(endpoint, server)
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  try {
    const response = await rawRequest(
      server.address().port,
      'GET /ordinary HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
    )
    assert.match(response, /ordinary-app-response$/)
    assert.equal(pendingSocketCount(server), 0)
  } finally {
    endpoint.close()
    if (server.listening) await new Promise((resolveClose) => server.close(resolveClose))
  }
})

test('WSS admits at raw TLS acceptance, rejects cap plus one, and recovers', async () => {
  const fixture = await wssFixture({ secure: true, maxPendingSockets: 2 })
  const port = fixture.server.address().port
  const first = net.createConnection({ host: '127.0.0.1', port })
  const second = net.createConnection({ host: '127.0.0.1', port })
  await Promise.all([once(first, 'connect'), once(second, 'connect')])
  try {
    await waitFor(
      () => pendingSocketCount(fixture.server) === 2,
      'raw accepted sockets were not admitted before TLS',
    )
    assert.equal(fixture.endpoint.links.size, 0, 'admission incorrectly waited for handler entry')

    const rejected = net.createConnection({ host: '127.0.0.1', port })
    rejected.on('error', () => {})
    await waitForSocketClose(rejected)
    assert.equal(pendingSocketCount(fixture.server), 2)

    first.destroy()
    await waitFor(() => pendingSocketCount(fixture.server) === 1, 'closed TLS stall leaked a permit')
    const valid = await openWs(fixture.url)
    valid.close()
    await once(valid, 'close')
    assert.equal(pendingSocketCount(fixture.server), 1, 'successful upgrade leaked raw admission')
  } finally {
    first.destroy()
    second.destroy()
    await fixture.close()
  }
})

test('WSS absolute acceptance deadline stops slow headers and permits a valid second client', async () => {
  const fixture = await wssFixture({ secure: true, handshakeTimeoutMs: 300 })
  const socket = tls.connect({
    host: '127.0.0.1',
    port: fixture.server.address().port,
    rejectUnauthorized: false,
  })
  socket.on('error', () => {})
  await once(socket, 'secureConnect')
  const trickle = setInterval(() => {
    if (!socket.destroyed) socket.write('X-Slow: x\r\n')
  }, 50)
  trickle.unref?.()
  socket.write('GET /_hop HTTP/1.1\r\nHost: localhost\r\n')
  try {
    await waitForSocketClose(socket)
    assert.equal(pendingSocketCount(fixture.server), 0)
    const valid = await openWs(fixture.url)
    valid.close()
    await once(valid, 'close')
  } finally {
    clearInterval(trickle)
    socket.destroy()
    await fixture.close()
  }
})

test('WSS accepts a valid client after stalled and malformed handshakes', async () => {
  const fixture = await wssFixture()
  const stalled = net.createConnection({ host: '127.0.0.1', port: fixture.server.address().port })
  try {
    stalled.write('GET /_hop HTTP/1.1\r\nHost: stalled')

    const firstValid = await openWs(fixture.url)
    firstValid.close()
    await once(firstValid, 'close')

    const malformed = await rawRequest(
      fixture.server.address().port,
      'GET /_hop HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n',
    )
    assert.match(malformed, /^HTTP\/1\.1 400 /)

    const secondValid = await openWs(fixture.url)
    secondValid.close()
    await once(secondValid, 'close')
  } finally {
    stalled.destroy()
    await fixture.close()
  }
})

test('WSS pending-link cap rejects cap plus one and releases capacity on close', async () => {
  const fixture = await wssFixture()
  const clients = []
  try {
    for (let i = 0; i < MAX_PENDING_LINKS; i += 1) clients.push(await openWs(fixture.url))

    const rejected = new WebSocket(fixture.url)
    rejected.on('error', () => {})
    const [, response] = await once(rejected, 'unexpected-response')
    assert.equal(response.statusCode, 503)
    response.destroy()

    clients.pop().terminate()
    while (fixture.endpoint.links.size === MAX_PENDING_LINKS) await new Promise((resolveWait) => setImmediate(resolveWait))
    const recovered = await openWs(fixture.url)
    clients.push(recovered)
  } finally {
    for (const ws of clients) ws.terminate()
    await fixture.close()
  }
})

test('WSS buffer adapter checks fragmented totals before concatenation', () => {
  assert.equal(asBuf([Buffer.alloc(MAX_MESSAGE_BYTES / 2), Buffer.alloc(MAX_MESSAGE_BYTES / 2)]).length, MAX_MESSAGE_BYTES)
  assert.throws(
    () => asBuf([Buffer.alloc(MAX_MESSAGE_BYTES / 2 + 1), Buffer.alloc(MAX_MESSAGE_BYTES / 2)]),
    /exceeds 1 MiB/,
  )
})

test('inbox acceptance requires an exact stable id and fails closed for unknown ids', () => {
  const endpoint = new HopEndpoint({ tickMs: 1000 })
  try {
    assert.throws(() => endpoint.acceptInbox(Buffer.alloc(31)), /exactly 32 bytes/)
    assert.throws(() => endpoint.acceptInbox(Buffer.alloc(33)), /exactly 32 bytes/)
    assert.throws(() => endpoint.acceptInbox('00'), /64-character hex string/)
    assert.equal(endpoint.acceptInbox(Buffer.alloc(32)), false)
    assert.equal(endpoint.acceptInbox(new Uint8Array(32)), false)
    assert.equal(endpoint.acceptInbox('00'.repeat(32)), false)
  } finally {
    endpoint.close()
  }
})

test('every fixed-width raw FFI argument rejects 0, 1, 31, and 33 bytes', () => {
  const exact = Buffer.alloc(32)
  const calls = [
    (value) => raw.node_address(null, value),
    (value) => raw.node_secret(null, value),
    (value) => raw.accept_inbox(null, value),
    (value) => raw.send_message(null, value, 'text/plain', null, 0, false, null),
    (value) => raw.send_message(null, exact, 'text/plain', null, 0, false, value),
    (value) => raw.send_service_request(null, value, 'svc', 'get', null, 0, null),
    (value) => raw.send_service_request(null, exact, 'svc', 'get', null, 0, value),
    (value) => raw.send_service_response(null, value, exact, 200, null, 0),
    (value) => raw.send_service_response(null, exact, value, 200, null, 0),
    (value) => raw.address_to_base58(value, Buffer.alloc(64), 64),
    (value) => raw.address_from_base58('invalid', value),
    (value) => raw.cluster_join(null, value),
    (value) => raw.cluster_mark_done(null, value, exact),
    (value) => raw.cluster_mark_done(null, exact, value),
    (value) => raw.cluster_would_drop(null, value, exact),
    (value) => raw.cluster_would_drop(null, exact, value),
  ]

  for (const size of [0, 1, 31, 33]) {
    for (const call of calls) {
      assert.throws(() => call(Buffer.alloc(size)), /exactly 32 bytes/)
    }
    assert.throws(() => new HopEndpoint({ key: Buffer.alloc(size), tickMs: 1000 }), /exactly 32 bytes/)
  }

  const node = raw.node_new()
  try {
    assert.equal(raw.node_address(node, exact), true)
    assert.equal(Number(raw.node_secret(node, exact)), 32)
    raw.accept_inbox(node, exact)
    raw.send_message(node, exact, 'text/plain', null, 0, false, exact)
    raw.send_service_request(node, exact, 'svc', 'get', null, 0, exact)
    raw.send_service_response(node, exact, exact, 200, null, 0)
    assert.ok(Number(raw.address_to_base58(exact, Buffer.alloc(64), 64)) > 0)
    raw.address_from_base58('invalid', exact)
    raw.cluster_join(node, exact)
    raw.cluster_mark_done(node, exact, exact)
    raw.cluster_would_drop(node, exact, exact)
  } finally {
    raw.node_free(node)
  }

  const keyed = new HopEndpoint({ key: exact, tickMs: 1000 })
  keyed.close()
})

test('close from a synchronous native poll callback defers free until poll returns', async () => {
  const server = new HopEndpoint({ tickMs: 1 })
  const client = new HopEndpoint({ tickMs: 1 })
  connectInProcess(server, client)
  let handled
  const handlerRan = new Promise((resolve) => { handled = resolve })
  server.on('close-during-poll', () => {
    server.close()
    handled()
  })

  const pending = client.request(server.addressBytes, 'close-during-poll', 'run', Buffer.alloc(0), {
    timeoutMs: 1000,
  })
  try {
    await handlerRan
    assert.throws(() => server.address, /endpoint is closed/)
  } finally {
    client.close()
  }
  await assert.rejects(pending, /endpoint closed/)
})

function decodedInbox(byte = 0x41) {
  return {
    idBytes: Buffer.alloc(32, byte),
    from: 'test-sender',
    fromBytes: Buffer.alloc(32, 0x52),
    contentType: 'text/plain',
    body: Buffer.from('durable payload'),
    hops: 2,
    createdAt: 1234,
  }
}

test('an inbox item with no message listener is not accepted or ACKed', () => {
  const emitter = new EventEmitter()
  const accepted = []
  const returned = HopEndpoint.prototype._emitInbox.call(
    emitter,
    decodedInbox(),
    (id) => accepted.push(id),
  )

  assert.equal(returned, false, 'the native poll item remains pending')
  assert.deepEqual(accepted, [])
})

test('an async message listener does not auto-accept after it resolves', async () => {
  const emitter = new EventEmitter()
  const accepted = []
  let finishListener
  const listenerFinished = new Promise((resolveFinished) => { finishListener = resolveFinished })
  emitter.on('message', async () => {
    await Promise.resolve()
    finishListener()
  })

  HopEndpoint.prototype._emitInbox.call(emitter, decodedInbox(0x42), (id) => accepted.push(id))
  await listenerFinished

  assert.deepEqual(accepted, [], 'listener completion alone cannot release the durable inbox item')
})

test('message.accept performs the distinct exact-id acceptance after durable work', async () => {
  const emitter = new EventEmitter()
  const accepted = []
  let finishDurableWork
  const durableWork = new Promise((resolveWork) => { finishDurableWork = resolveWork })
  let finishListener
  const listenerFinished = new Promise((resolveFinished) => { finishListener = resolveFinished })
  let acceptanceResult
  emitter.on('message', async (message) => {
    await durableWork
    acceptanceResult = message.accept()
    finishListener()
  })
  const item = decodedInbox(0x43)

  HopEndpoint.prototype._emitInbox.call(emitter, item, (id) => {
    accepted.push(id)
    return true
  })
  assert.deepEqual(accepted, [], 'acceptance waits for the application persistence boundary')
  finishDurableWork()
  await listenerFinished

  assert.equal(acceptanceResult, true)
  assert.equal(accepted.length, 1)
  assert.deepEqual(accepted[0], item.idBytes)
})
