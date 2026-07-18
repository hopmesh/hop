// The net/http-shaped DX, running on real hop-core over the C ABI. A server endpoint registers a
// receiver; a client calls it and gets a reply. Delivery is delay-tolerant underneath.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	hop "github.com/hopmesh/hop-sdk-go"
)

func main() {
	server, err := hop.New()
	if err != nil {
		fmt.Println("open server:", err)
		os.Exit(1)
	}
	client, err := hop.New()
	if err != nil {
		fmt.Println("open client:", err)
		os.Exit(1)
	}

	// --- this is the whole server: mount a receiver, reply with a status + body ---
	server.On("acme/orders", func(req *hop.Request, reply hop.Reply) {
		fmt.Printf("  [server] %s/%s from %s body=%s\n", req.Service, req.Method, req.From[:10], req.Args)
		var order map[string]any
		_ = json.Unmarshal(req.Args, &order)
		body, _ := json.Marshal(map[string]any{"ok": true, "id": 42, "item": order["item"]})
		reply(200, body) // uint16 status, JSON body
	})

	// wire the two endpoints together (in-process bearer; swap for TCP to make it reachable by any device)
	hop.ConnectInProcess(server, client)

	fmt.Println("server address:", server.Address())
	fmt.Println("client address:", client.Address())

	// --- client calls the service, like an HTTP request, but forward-secret + delay-tolerant ---
	status, body, err := client.Request(server.Address(), "acme/orders", "create", []byte(`{"item":"widget"}`))
	if err != nil {
		fmt.Println("request:", err)
		os.Exit(1)
	}
	fmt.Printf("  [client] <- %d %s\n", status, body)

	var parsed map[string]any
	_ = json.Unmarshal(body, &parsed)
	passed := status == 200 && parsed["ok"] == true && parsed["item"] == "widget"
	server.Close()
	client.Close()
	if passed {
		fmt.Println("\nPASS: On(service, handler) + reply(status, body) over real hop-core.")
	} else {
		fmt.Println("\nFAIL")
		os.Exit(1)
	}
}
