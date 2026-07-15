import assert from 'node:assert/strict'
import net from 'node:net'
import test from 'node:test'
import { resolve } from '../lib/discovery.mjs'
import { listen, MAX_FRAME_BYTES } from '../lib/tcp-bearer.mjs'

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
