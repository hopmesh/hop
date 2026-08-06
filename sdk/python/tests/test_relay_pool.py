"""PLAT-003: sdk/hop.h justified the v4 -> v5 ABI bump with the §19 relay-pool calls, and this SDK
asserts ABI 5 at import while binding none of them, so an SDK-only host could not fail over: the only
reachable behavior was retrying one configured URL forever. This drives the failover the header
describes through the published HopEndpoint surface, on ONE endpoint that is never restarted."""
import unittest

from hop_endpoint import HopEndpoint


class RelayPool(unittest.TestCase):
    def test_pool_fails_over_without_restarting_the_endpoint(self):
        endpoint = HopEndpoint(tick_ms=1000)
        try:
            # An empty pool is distinguishable from a backed-off one: nothing to dial, nothing pooled.
            self.assertIsNone(endpoint.relay_next())
            self.assertEqual(endpoint.relay_pool(), (0, 0))

            a, b = "wss://relay-a.example/_hop", "wss://relay-b.example/_hop"
            self.assertTrue(endpoint.relay_add(a))
            self.assertTrue(endpoint.relay_add(b))
            self.assertEqual(endpoint.relay_pool(), (2, 2))

            first = endpoint.relay_next()
            self.assertIn(first, (a, b))

            # A working relay is kept: no needless churn between two healthy candidates.
            endpoint.relay_report(first, True)
            self.assertEqual(endpoint.relay_next(), first)

            # It goes dark. THIS is the case the header promised and the SDK could not reach: the same
            # live endpoint must hand back the other candidate, with no restart and no new node.
            endpoint.relay_report(first, False)
            second = endpoint.relay_next()
            self.assertIsNotNone(second, "failover target missing after the configured relay died")
            self.assertNotEqual(second, first, f"no failover: still dialing the dead relay {first}")

            # Everything down is WAIT, not offline, and the SDK can tell the two apart.
            for url in (first, first, second, second):
                endpoint.relay_report(url, False)
            self.assertIsNone(endpoint.relay_next())
            self.assertEqual(endpoint.relay_pool(), (2, 0))
        finally:
            endpoint.close()


if __name__ == "__main__":
    unittest.main()
