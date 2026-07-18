// A standalone, self-hostable Hop endpoint (the two-process deployment shape). Run this, then run
// examples/client with the address it prints. In production HNS would resolve a name to this
// host/port/key, and you would persist the key so the address is stable across restarts.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"

	hop "github.com/hopmesh/hop-sdk-go"
)

func main() {
	port := 9944
	if p := os.Getenv("PORT"); p != "" {
		port, _ = strconv.Atoi(p)
	}

	server, err := hop.New()
	if err != nil {
		fmt.Println("open:", err)
		os.Exit(1)
	}
	server.On("acme/orders", func(req *hop.Request, reply hop.Reply) {
		// req.From is the cryptographically VERIFIED sender, not a spoofable header. No auth middleware.
		fmt.Printf("[server] %s/%s from %s: %s\n", req.Service, req.Method, req.From[:12], req.Args)
		var received any
		_ = json.Unmarshal(req.Args, &received)
		body, _ := json.Marshal(map[string]any{"ok": true, "received": received})
		reply(201, body)
	})

	if _, err := hop.Listen(server, port); err != nil {
		fmt.Println("listen:", err)
		os.Exit(1)
	}
	fmt.Printf("hop endpoint listening on tcp://0.0.0.0:%d\n", port)
	fmt.Println("address:", server.Address())
	fmt.Printf("\ntry it:\n  go run ./examples/client %s localhost %d\n", server.Address(), port)

	select {} // keep the endpoint (and its pump goroutine) alive
}
