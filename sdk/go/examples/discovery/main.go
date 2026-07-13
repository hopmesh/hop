// Proves the full DNS-free discovery chain: a client resolves a domain by name, the TLS cert proves the
// domain (WebPKI), the served reach record self-certifies the address, and the WSS handshake confirms
// it, then a hops:// round trip runs over the WebSocket. One process, a real self-signed HTTPS server
// (production uses a real cert; here we accept the in-process self-signed one with insecureTLS).
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"os"
	"time"

	hop "github.com/hopmesh/hop/sdk/go"
)

const port = 8443

// A self-signed cert for localhost, generated IN-PROCESS (no openssl CLI); production has a real WebPKI cert.
func selfSignedCert() tls.Certificate {
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		panic(err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "localhost"},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &priv.PublicKey, priv)
	if err != nil {
		panic(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}
}

func main() {
	publicURL := fmt.Sprintf("wss://localhost:%d/_hop", port)

	// --- the server: an https.Server, wired in ONE call (wss /_hop + GET /.well-known/hop) ---
	server, err := hop.New()
	if err != nil {
		fmt.Println("open server:", err)
		os.Exit(1)
	}
	server.On("acme/orders", func(req *hop.Request, reply hop.Reply) {
		fmt.Printf("  [server] %s/%s from %s: %s\n", req.Service, req.Method, req.From[:10], req.Args)
		reply(201, req.Args)
	})
	mux := http.NewServeMux()
	server.Attach(mux, publicURL)

	ln, err := tls.Listen("tcp", fmt.Sprintf(":%d", port), &tls.Config{Certificates: []tls.Certificate{selfSignedCert()}})
	if err != nil {
		fmt.Println("listen tls:", err)
		os.Exit(1)
	}
	httpsSrv := &http.Server{Handler: mux}
	go httpsSrv.Serve(ln) //nolint:errcheck
	defer httpsSrv.Close()
	fmt.Printf("endpoint on https://localhost:%d (well-known + wss)  addr=%s\n", port, server.Address()[:12])

	// --- the client: resolve by NAME, verifying the record, then round-trip over WSS ---
	client, err := hop.New()
	if err != nil {
		fmt.Println("open client:", err)
		os.Exit(1)
	}
	address, err := client.DialByName(fmt.Sprintf("https://localhost:%d", port), true)
	if err != nil {
		fmt.Println("dialByName:", err)
		os.Exit(1)
	}
	fmt.Printf("  [client] resolved the domain -> %s (reach record verified)\n", address[:12])

	status, body, err := client.Request(address, "acme/orders", "create", []byte("widget"))
	if err != nil {
		fmt.Println("request:", err)
		os.Exit(1)
	}
	fmt.Printf("  [client] <- %d %s\n", status, body)

	passed := status == 201 && string(body) == "widget"
	server.Close()
	client.Close()
	if passed {
		fmt.Println("\nPASS: name -> verified address -> WSS hops:// round trip.")
	} else {
		fmt.Println("\nFAIL")
		os.Exit(1)
	}
}
