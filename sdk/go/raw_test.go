package hop

import "testing"

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
}
