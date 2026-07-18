// Proves the Internet bearer: a server endpoint LISTENS on TCP, a client DIALS it over a real socket,
// and the hops:// round trip completes over TCP with real Noise. One process, real loopback sockets.
package main

import (
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
	server.On("acme/orders", func(req *hop.Request, reply hop.Reply) {
		fmt.Printf("  [server] %s/%s from %s over TCP: %s\n", req.Service, req.Method, req.From[:10], req.Args)
		reply(201, req.Args)
	})
	if _, err := hop.Listen(server, 9952); err != nil {
		fmt.Println("listen:", err)
		os.Exit(1)
	}
	fmt.Printf("server listening on tcp://localhost:9952  addr=%s\n", server.Address()[:12])

	client, err := hop.New()
	if err != nil {
		fmt.Println("open client:", err)
		os.Exit(1)
	}
	if _, err := hop.Dial(client, "localhost", 9952); err != nil {
		fmt.Println("dial:", err)
		os.Exit(1)
	}

	status, body, err := client.Request(server.Address(), "acme/orders", "create", []byte(`{"item":"widget"}`))
	if err != nil {
		fmt.Println("request:", err)
		os.Exit(1)
	}
	fmt.Printf("  [client] <- %d %s\n", status, body)

	server.Close()
	client.Close()
	if status == 201 && string(body) == `{"item":"widget"}` {
		fmt.Println("\nPASS: hops:// round trip over a real TCP Internet bearer.")
	} else {
		fmt.Println("\nFAIL")
		os.Exit(1)
	}
}
