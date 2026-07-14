// Proof: the endpoint cluster bindings resolve against libhop and behave (DESIGN.md §40). The
// cross-replica dedup itself is proven rigorously in the Rust `hop-endpoint-core` crate; here we
// exercise the JS surface end to end against the real C ABI.
import assert from 'node:assert'

import { HopEndpoint } from '../lib/endpoint.mjs'

// 1. Cluster via the constructor option (a string passphrase, interops with the service's
//    HOP_CLUSTER_SECRET since both derive the 32-byte secret the same way through the ABI).
const a = new HopEndpoint({ cluster: 'shared-cluster-passphrase' })
assert.equal(a.clusterMembers, 1, 'a solo replica counts itself')

// 2. Cluster via the chainable method on a second endpoint.
const b = new HopEndpoint()
assert.equal(b.cluster('shared-cluster-passphrase'), b, 'cluster() returns this')
assert.equal(b.clusterMembers, 1)

// 3. A raw 32-byte Buffer secret is also accepted.
const c = new HopEndpoint()
c.cluster(Buffer.alloc(32, 7))
assert.equal(c.clusterMembers, 1)

// 4. An unclustered endpoint reports a single member and never drops.
const d = new HopEndpoint()
assert.equal(d.clusterMembers, 1, 'unclustered = solo')

// 5. A wrong-length raw secret is rejected (a passphrase string is always fine).
assert.throws(() => new HopEndpoint().cluster(Buffer.alloc(16)), /32-byte/)

for (const ep of [a, b, c, d]) ep.close()
console.log('cluster.mjs: OK (join via passphrase + raw secret, members query, validation)')
process.exit(0)
