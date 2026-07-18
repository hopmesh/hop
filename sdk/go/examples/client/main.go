// Calls a self-hosted Hop endpoint over TCP. The address would normally come from an HNS lookup; here
// you paste the one examples/server printed.
//
//	go run ./examples/client <server-address> [host] [port]
package main

import (
	"fmt"
	"os"
	"strconv"

	hop "github.com/hopmesh/hop-sdk-go"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go run ./examples/client <server-address> [host] [port]")
		os.Exit(2)
	}
	address := os.Args[1]
	host := "localhost"
	if len(os.Args) > 2 {
		host = os.Args[2]
	}
	port := 9944
	if len(os.Args) > 3 {
		port, _ = strconv.Atoi(os.Args[3])
	}

	client, err := hop.New()
	if err != nil {
		fmt.Println("open:", err)
		os.Exit(1)
	}
	defer client.Close()
	if _, err := hop.Dial(client, host, port); err != nil {
		fmt.Println("dial:", err)
		os.Exit(1)
	}

	status, body, err := client.Request(address, "acme/orders", "create", []byte(`{"item":"widget","qty":3}`))
	if err != nil {
		fmt.Fprintln(os.Stderr, "request failed:", err)
		os.Exit(1)
	}
	fmt.Printf("<- %d %s\n", status, body)
}
