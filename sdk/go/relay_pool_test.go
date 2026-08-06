package hop

import "testing"

// PLAT-003: sdk/hop.h justified the v4 -> v5 ABI bump with the §19 relay-pool calls, and this SDK
// asserts ABI 5 at New() while binding none of them, so an SDK-only host could not fail over: the
// only reachable behavior was retrying one configured URL forever. This drives the failover the
// header describes entirely through the published Endpoint surface, on ONE endpoint that is never
// restarted. Revert the RelayAdd/RelayNext/RelayReport/RelayPool methods and this stops compiling,
// which is the point: the capability, not the version integer, is what closes the finding.
func TestRelayPoolFailsOverWithoutRestartingTheEndpoint(t *testing.T) {
	e, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()

	// An empty pool is distinguishable from a backed-off one: nothing to dial, nothing pooled.
	if url, ok := e.RelayNext(); ok {
		t.Fatalf("empty pool offered %q", url)
	}
	if total, available := e.RelayPool(); total != 0 || available != 0 {
		t.Fatalf("empty pool reported total=%d available=%d", total, available)
	}

	const a, b = "wss://relay-a.example/_hop", "wss://relay-b.example/_hop"
	if !e.RelayAdd(a, true) || !e.RelayAdd(b, true) {
		t.Fatal("configured endpoints were not pooled")
	}
	if total, available := e.RelayPool(); total != 2 || available != 2 {
		t.Fatalf("after two adds: total=%d available=%d, want 2/2", total, available)
	}

	first, ok := e.RelayNext()
	if !ok {
		t.Fatal("a pooled endpoint should be dialable")
	}
	// A working relay is kept: no needless churn between two healthy candidates.
	e.RelayReport(first, true)
	if again, _ := e.RelayNext(); again != first {
		t.Fatalf("a healthy relay was abandoned: %q then %q", first, again)
	}

	// It goes dark. THIS is the case the header promised and the SDK could not reach: the same live
	// endpoint must now hand back the other candidate, with no restart and no new node.
	e.RelayReport(first, false)
	second, ok := e.RelayNext()
	if !ok {
		t.Fatal("failover target missing after the configured relay died")
	}
	if second == first {
		t.Fatalf("no failover: still dialing the dead relay %q", first)
	}

	// Everything down is WAIT, not offline, and the SDK can tell the two apart.
	for _, url := range []string{first, first, second, second} {
		e.RelayReport(url, false)
	}
	if url, ok := e.RelayNext(); ok {
		t.Fatalf("every candidate is backed off yet %q was offered", url)
	}
	total, available := e.RelayPool()
	if total != 2 || available != 0 {
		t.Fatalf("degraded pool reported total=%d available=%d, want 2/0", total, available)
	}
}
