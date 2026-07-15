package hop

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"testing"
	"time"
)

// A self-signed cert for localhost (dev only; production has a real WebPKI cert).
func selfSignedCert(t *testing.T) tls.Certificate {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
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
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: priv}
}

func TestReachRecordSignVerify(t *testing.T) {
	e, _ := New()
	defer e.Close()
	rec := e.SignReach("wss://myaddress.com/_hop", 3600)
	info, ok := VerifyReach(rec, uint64(time.Now().Unix()))
	if !ok || info.Endpoint != "wss://myaddress.com/_hop" || e.Address() != toB58(info.Address) {
		t.Fatalf("verify failed: ok=%v info=%+v", ok, info)
	}
	bad := append([]byte(nil), rec...)
	bad[len(bad)-1] ^= 0xff
	if _, ok := VerifyReach(bad, 0); ok {
		t.Fatal("tampered record must not verify")
	}
}

func TestResolveRejectsPlaintextBeforeFetch(t *testing.T) {
	client := &http.Client{Transport: roundTripperFunc(func(*http.Request) (*http.Response, error) {
		t.Fatal("plaintext discovery must be rejected before network I/O")
		return nil, nil
	})}
	if _, _, err := Resolve(client, "http://example.com"); err == nil {
		t.Fatal("expected plaintext discovery to fail")
	}
}

func TestResolveRejectsRedirect(t *testing.T) {
	requests := 0
	client := &http.Client{Transport: roundTripperFunc(func(r *http.Request) (*http.Response, error) {
		requests++
		return &http.Response{
			StatusCode: http.StatusFound,
			Header:     http.Header{"Location": []string{"http://attacker.example/.well-known/hop"}},
			Body:       io.NopCloser(&emptyReader{}),
			Request:    r,
		}, nil
	})}
	if _, _, err := Resolve(client, "https://example.com"); err == nil {
		t.Fatal("expected redirect to fail")
	}
	if requests != 1 {
		t.Fatalf("redirect followed: got %d requests", requests)
	}
}

type emptyReader struct{}

func (*emptyReader) Read([]byte) (int, error) { return 0, io.EOF }

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (f roundTripperFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestDiscoveryRoundTrip(t *testing.T) {
	const port = 8444
	publicURL := fmt.Sprintf("wss://localhost:%d/_hop", port)

	server, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	server.On("acme/orders", func(req *Request, reply Reply) { reply(201, req.Args) })

	mux := http.NewServeMux()
	server.Attach(mux, publicURL) // wires /_hop (WSS) + /.well-known/hop in one call

	ln, err := tls.Listen("tcp", fmt.Sprintf(":%d", port), &tls.Config{Certificates: []tls.Certificate{selfSignedCert(t)}})
	if err != nil {
		t.Fatal(err)
	}
	httpsSrv := &http.Server{Handler: mux}
	go httpsSrv.Serve(ln) //nolint:errcheck
	defer httpsSrv.Close()

	client, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()

	address, err := client.DialByName(fmt.Sprintf("https://localhost:%d", port), true)
	if err != nil {
		t.Fatalf("dialByName: %v", err)
	}
	if address != server.Address() {
		t.Fatalf("resolved %s, expected %s", address, server.Address())
	}

	status, body, err := client.Request(address, "acme/orders", "create", []byte("widget"))
	if err != nil {
		t.Fatal(err)
	}
	if status != 201 || string(body) != "widget" {
		t.Fatalf("status=%d body=%q", status, body)
	}
}
