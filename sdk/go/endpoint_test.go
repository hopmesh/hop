package hop

import (
	"testing"
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
	// DESIGN.md §40: cluster join + CP quorum bindings resolve against libhop and behave. The
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
