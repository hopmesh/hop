// PLAT-003: sdk/hop.h justified the v4 -> v5 ABI bump with the §19 relay-pool calls, and this SDK
// asserts ABI 5 at load while binding none of them, so an SDK-only host could not fail over: the only
// reachable behavior was retrying one configured URL forever. This drives the failover the header
// describes through the published HopEndpoint surface, on ONE endpoint that is never restarted.
import assert from 'node:assert/strict'
import test from 'node:test'
import { HopEndpoint } from '../lib/endpoint.mjs'

test('the relay pool fails over to another endpoint without restarting the endpoint', () => {
  const endpoint = new HopEndpoint({ tickMs: 1000 })
  try {
    // An empty pool is distinguishable from a backed-off one: nothing to dial, nothing pooled.
    assert.equal(endpoint.relayNext(), null)
    assert.deepEqual(endpoint.relayPool(), { total: 0, available: 0 })

    const a = 'wss://relay-a.example/_hop'
    const b = 'wss://relay-b.example/_hop'
    assert.equal(endpoint.relayAdd(a), true)
    assert.equal(endpoint.relayAdd(b), true)
    assert.deepEqual(endpoint.relayPool(), { total: 2, available: 2 })

    const first = endpoint.relayNext()
    assert.ok(first === a || first === b, `unexpected first dial target ${first}`)

    // A working relay is kept: no needless churn between two healthy candidates.
    endpoint.relayReport(first, true)
    assert.equal(endpoint.relayNext(), first)

    // It goes dark. THIS is the case the header promised and the SDK could not reach: the same live
    // endpoint must hand back the other candidate, with no restart and no new node.
    endpoint.relayReport(first, false)
    const second = endpoint.relayNext()
    assert.ok(second, 'failover target missing after the configured relay died')
    assert.notEqual(second, first, `no failover: still dialing the dead relay ${first}`)

    // Everything down is WAIT, not offline, and the SDK can tell the two apart.
    for (const url of [first, first, second, second]) endpoint.relayReport(url, false)
    assert.equal(endpoint.relayNext(), null)
    assert.deepEqual(endpoint.relayPool(), { total: 2, available: 0 })
  } finally {
    endpoint.close()
  }
})
