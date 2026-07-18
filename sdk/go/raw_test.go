package hop

import "testing"

func TestEveryFixedWidthArgumentRequiresExactly32Bytes(t *testing.T) {
	n := nodeNew()
	defer n.free()
	n.tick(1)
	exact := n.address()
	for _, size := range []int{0, 1, 31, 33} {
		invalid := make([]byte, size)
		if _, err := n.acceptInbox(make([]byte, size)); err == nil {
			t.Fatalf("acceptInbox accepted a %d-byte id", size)
		}
		if err := n.clusterJoin(invalid); err == nil {
			t.Fatalf("clusterJoin accepted a %d-byte secret", size)
		}
		if _, err := n.sendServiceRequest(invalid, "svc", "get", nil); err == nil {
			t.Fatalf("sendServiceRequest accepted a %d-byte destination", size)
		}
		if n.sendServiceResponse(invalid, exact, 200, nil) {
			t.Fatalf("sendServiceResponse accepted a %d-byte destination", size)
		}
		if n.sendServiceResponse(exact, invalid, 200, nil) {
			t.Fatalf("sendServiceResponse accepted a %d-byte request id", size)
		}
		if got := toB58(invalid); got != "" {
			t.Fatalf("toB58 accepted a %d-byte address", size)
		}
		e, err := New(WithKey(invalid))
		if err == nil {
			e.Close()
			t.Fatalf("WithKey accepted a %d-byte identity key", size)
		}
	}
	accepted, err := n.acceptInbox(exact)
	if err != nil || accepted {
		t.Fatalf("unknown exact id should fail closed: accepted=%v err=%v", accepted, err)
	}
	if err := n.clusterJoin(exact); err != nil {
		t.Fatal(err)
	}
	if _, err := n.sendServiceRequest(exact, "svc", "get", nil); err != nil {
		t.Fatal(err)
	}
	if !n.sendServiceResponse(exact, exact, 200, nil) {
		t.Fatal("exact response identifiers were rejected")
	}
	if toB58(exact) == "" {
		t.Fatal("exact address was rejected")
	}
	keyed, err := New(WithKey(exact))
	if err != nil {
		t.Fatal(err)
	}
	keyed.Close()
}

// Derisking proof: the hops:// service round trip through the raw cgo layer, mirroring
// core/hop/src/cabi.rs. Two nodes, a byte-pipe bearer, a request in, 200 + body back out.
func TestRawRoundTrip(t *testing.T) {
	if err := assertABI(); err != nil {
		t.Fatal(err)
	}
	const LA, LB = 11, 22
	a, b := nodeNew(), nodeNew()
	defer a.free()
	defer b.free()

	pump := func() {
		for i := 0; i < 1000; i++ {
			moved := false
			for _, p := range a.drainOutgoing() {
				moved = true
				b.received(LB, p.Bytes)
			}
			for _, p := range b.drainOutgoing() {
				moved = true
				a.received(LA, p.Bytes)
			}
			if !moved {
				break
			}
		}
	}

	a.tick(1000)
	b.tick(1000)
	a.connected(LA, true)
	b.connected(LB, false)
	pump()
	a.publishPrekey()
	b.publishPrekey()
	pump()

	reqID, err := a.sendServiceRequest(b.address(), "weather", "report", []byte("temp=21"))
	if err != nil {
		t.Fatal(err)
	}
	pump()

	reqs := b.takeServiceRequests()
	if len(reqs) != 1 || reqs[0].Service != "weather" || string(reqs[0].Args) != "temp=21" {
		t.Fatalf("bad request drain: %+v", reqs)
	}
	if !b.sendServiceResponse(reqs[0].From, reqs[0].RequestID, 200, []byte("stored")) {
		t.Fatal("send response failed")
	}
	pump()

	resps := a.takeServiceResponses()
	if len(resps) != 1 || resps[0].Status != 200 || string(resps[0].Body) != "stored" {
		t.Fatalf("bad response drain: %+v", resps)
	}
	if string(resps[0].ForRequestID) != string(reqID) {
		t.Fatal("for_request_id does not tie to the request id")
	}
	if len(a.takeServiceResponses()) != 1 {
		t.Fatal("an unaccepted response must be redelivered")
	}
	accepted, err := a.acceptServiceResponse(reqID)
	if err != nil || !accepted {
		t.Fatalf("explicit response acceptance failed: accepted=%v err=%v", accepted, err)
	}
	if len(a.takeServiceResponses()) != 0 {
		t.Fatal("an accepted response must not be redelivered")
	}
}
