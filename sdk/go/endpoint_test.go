package hop

import (
	"path/filepath"
	"testing"
	"time"
)

func TestInProcessRoundTrip(t *testing.T) {
	server, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	server.On("acme/orders", func(req *Request, reply Reply) {
		reply(200, append([]byte("got:"), req.Args...))
	})
	client, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	ConnectInProcess(server, client)

	status, body, err := client.Request(server.Address(), "acme/orders", "create", []byte("temp=21"))
	if err != nil {
		t.Fatal(err)
	}
	if status != 200 || string(body) != "got:temp=21" {
		t.Fatalf("status=%d body=%q", status, body)
	}
}

func TestTCPRoundTrip(t *testing.T) {
	server, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	server.On("acme/orders", func(req *Request, reply Reply) { reply(201, req.Args) })
	if _, err := Listen(server, 9951); err != nil {
		t.Fatal(err)
	}
	client, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if _, err := Dial(client, "localhost", 9951); err != nil {
		t.Fatal(err)
	}

	status, body, err := client.Request(server.Address(), "acme/orders", "create", []byte("widget"))
	if err != nil {
		t.Fatal(err)
	}
	if status != 201 || string(body) != "widget" {
		t.Fatalf("status=%d body=%q", status, body)
	}
}

func TestClusterAndQuorum(t *testing.T) {
	// Cluster join + TTL visibility threshold bindings resolve against libhop and behave. The
	// cross-replica dedup + hold are proven in the Rust crate; here we exercise the Go surface.
	e, err := New(WithCluster("shared-cluster-passphrase"), WithQuorum(3))
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	if m := e.ClusterMembers(); m != 1 {
		t.Fatalf("solo replica should count itself, got %d", m)
	}
	e.ClusterQuorum(2) // settable at runtime too
}

func TestServiceRequestThrowingHandlerLeavesRequestQueued(t *testing.T) {
	server, err := New(WithTickMs(10))
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	attempts := 0
	firstAttemptDone := make(chan struct{})

	server.On("flaky", func(req *Request, reply Reply) {
		attempts++
		if attempts == 1 {
			close(firstAttemptDone)
			panic("handler failed attempt 1")
		}
		reply(200, []byte("recovered"))
	})

	client, err := New(WithTickMs(10))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	ConnectInProcess(server, client)

	resCh := make(chan struct {
		status uint16
		body   []byte
		err    error
	}, 1)
	go func() {
		st, b, reqErr := client.Request(server.Address(), "flaky", "call", []byte("test"))
		resCh <- struct {
			status uint16
			body   []byte
			err    error
		}{st, b, reqErr}
	}()

	select {
	case <-firstAttemptDone:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for first attempt")
	}

	select {
	case res := <-resCh:
		if res.err != nil {
			t.Fatalf("request failed: %v", res.err)
		}
		if attempts != 2 {
			t.Fatalf("expected 2 attempts (redelivery), got %d", attempts)
		}
		if res.status != 200 || string(res.body) != "recovered" {
			t.Fatalf("unexpected response: status=%d body=%q", res.status, res.body)
		}
	case <-time.After(3 * time.Second):
		t.Fatalf("timed out waiting for redelivery, attempts=%d", attempts)
	}
}

func TestEndpointPersistsStateAcrossRestart(t *testing.T) {
	dbFile := filepath.Join(t.TempDir(), "test-restart.db")
	secret := make([]byte, 32)
	for i := range secret {
		secret[i] = byte(i + 1)
	}

	// 1. Open with WithDBPath
	e1, err := New(WithDBPath(dbFile), WithKey(secret), WithCluster("shared-cluster-passphrase"))
	if err != nil {
		t.Fatal(err)
	}
	if !e1.IsPersistent() {
		t.Fatal("expected e1 to be persistent")
	}

	from := make([]byte, 32)
	from[0] = 0xAA
	rid := make([]byte, 32)
	rid[0] = 0xBB

	e1.withNode(func(n *node) {
		n.clusterMarkDone(from, rid)
		if !n.clusterWouldDrop(from, rid) {
			t.Fatal("clusterWouldDrop should be true before restart")
		}
	})
	e1.Close()

	// 2. Reopen same DB path with same key
	e2, err := New(WithDBPath(dbFile), WithKey(secret), WithCluster("shared-cluster-passphrase"))
	if err != nil {
		t.Fatal(err)
	}
	defer e2.Close()

	if !e2.IsPersistent() {
		t.Fatal("expected e2 to be persistent")
	}

	e2.withNode(func(n *node) {
		if !n.clusterWouldDrop(from, rid) {
			t.Fatal("persisted handled claim was not recovered after restart")
		}
	})
}
