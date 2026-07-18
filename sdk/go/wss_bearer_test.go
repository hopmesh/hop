package hop

import (
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func wssTestServer(t *testing.T) (*Endpoint, *HTTPServer, string) {
	return wssTestServerWithLimits(t, false, MaxPendingHTTPSocks, WSSHandshakeTimeout)
}

func wssTestServerWithLimits(t *testing.T, secure bool, pending int, timeout time.Duration) (*Endpoint, *HTTPServer, string) {
	t.Helper()
	endpoint, err := New()
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	server := NewHTTPServer("", nil)
	server.maxPending = pending
	server.handshakeTimeout = timeout
	if err := endpoint.Attach(server, "wss://unused/_hop"); err != nil {
		t.Fatal(err)
	}
	if secure {
		listener = tls.NewListener(listener, &tls.Config{Certificates: []tls.Certificate{selfSignedCert(t)}})
	}
	go func() {
		if serveErr := server.Serve(listener); serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
			t.Errorf("HTTP server failed: %v", serveErr)
		}
	}()
	t.Cleanup(func() {
		_ = server.Close()
		endpoint.Close()
	})
	scheme := "ws"
	if secure {
		scheme = "wss"
	}
	return endpoint, server, scheme + "://" + address + "/_hop"
}

func dialTestWSS(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	dialer := websocket.Dialer{
		HandshakeTimeout: WSSHandshakeTimeout,
		TLSClientConfig:  &tls.Config{InsecureSkipVerify: true}, //nolint:gosec // in-process test certificate
	}
	conn, response, err := dialer.Dial(url, nil)
	if response != nil && response.Body != nil {
		defer response.Body.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	return conn
}

func expectWSSReadFailure(t *testing.T, conn *websocket.Conn) {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, err := conn.ReadMessage(); err == nil {
		t.Fatal("oversized WebSocket message remained connected")
	}
	_ = conn.Close()
}

func TestWSSRejectsOversizedSingleAndFragmentedMessagesThenRecovers(t *testing.T) {
	_, _, url := wssTestServer(t)

	single := dialTestWSS(t, url)
	if err := single.WriteMessage(websocket.BinaryMessage, make([]byte, MaxWSSMessageBytes+1)); err != nil {
		t.Fatal(err)
	}
	expectWSSReadFailure(t, single)

	fragmented := dialTestWSS(t, url)
	writer, err := fragmented.NextWriter(websocket.BinaryMessage)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(make([]byte, MaxWSSMessageBytes/2+1)); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(make([]byte, MaxWSSMessageBytes/2)); err != nil {
		t.Fatal(err)
	}
	_ = writer.Close()
	expectWSSReadFailure(t, fragmented)

	recovered := dialTestWSS(t, url)
	_ = recovered.Close()
}

func TestWSSHandlerRejectsOversizedMaterializedHeaders(t *testing.T) {
	endpoint, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer endpoint.Close()

	request := httptest.NewRequest(http.MethodGet, "http://example/_hop", nil)
	request.Header.Set("X-Fill", strings.Repeat("x", MaxWSSHeaderBytes))
	response := httptest.NewRecorder()
	endpoint.wssHandler().ServeHTTP(response, request)
	if response.Code != http.StatusRequestHeaderFieldsTooLarge {
		t.Fatalf("status=%d, want 431", response.Code)
	}
}

func TestHTTPServerRequiresAttachAndInstallsMandatoryBounds(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	unattached := NewHTTPServer("", nil)
	if err := unattached.Serve(listener); !errors.Is(err, ErrHTTPServerNotAttached) {
		t.Fatalf("unattached Serve error=%v", err)
	}

	endpoint, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer endpoint.Close()
	server := NewHTTPServer("", nil)
	server.server.MaxHeaderBytes = 1024
	server.server.ReadHeaderTimeout = time.Second
	server.server.ReadTimeout = 2 * time.Second
	server.server.WriteTimeout = time.Second
	if err := endpoint.Attach(server, "wss://unused/_hop"); err != nil {
		t.Fatal(err)
	}
	configured := server.server
	if configured.MaxHeaderBytes != 1024 || configured.ReadHeaderTimeout != time.Second ||
		configured.ReadTimeout != 2*time.Second || configured.WriteTimeout != time.Second ||
		configured.ConnState == nil || configured.ConnContext == nil {
		t.Fatal("Attach omitted admission or weakened stricter HTTP bounds")
	}
	runningListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go server.Serve(runningListener) //nolint:errcheck
	waitForCondition(t, func() bool {
		server.mu.Lock()
		defer server.mu.Unlock()
		return server.started
	}, "attached server did not start")
	other, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if err := other.Attach(server, "wss://other/_hop"); !errors.Is(err, ErrHTTPServerStarted) {
		t.Fatalf("attachment to running server error=%v", err)
	}
	_ = server.Close()
}

func waitForCondition(t *testing.T, condition func() bool, message string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal(message)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestHTTPAdmissionOccursAtAcceptanceBeforeHandlerAndRecovers(t *testing.T) {
	var handlers atomic.Int32
	app := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		handlers.Add(1)
		_, _ = io.WriteString(w, "ordinary")
	})
	endpoint, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer endpoint.Close()
	server := NewHTTPServer("", app)
	server.maxPending = 2
	if err := endpoint.Attach(server, "wss://unused/_hop"); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go server.Serve(listener) //nolint:errcheck
	defer server.Close()

	first, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	second, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	waitForCondition(t, func() bool { return server.admission.count() == 2 }, "accepted sockets were not admitted")
	if handlers.Load() != 0 {
		t.Fatal("admission waited until handler entry")
	}

	overflow, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	_ = overflow.SetReadDeadline(time.Now().Add(time.Second))
	if _, err := overflow.Read(make([]byte, 1)); err == nil {
		t.Fatal("cap plus one remained open")
	}
	_ = overflow.Close()
	if server.admission.count() != 2 {
		t.Fatal("rejected connection consumed an admission slot")
	}

	_ = first.Close()
	waitForCondition(t, func() bool { return server.admission.count() == 1 }, "closed connection leaked admission")
	response, err := http.Get("http://" + listener.Addr().String() + "/ordinary")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, response.Body)
	_ = response.Body.Close()
	if handlers.Load() != 1 {
		t.Fatal("valid client did not reach the application handler")
	}
	waitForCondition(t, func() bool { return server.admission.count() == 1 }, "ordinary HTTP request leaked admission")
}

func TestHTTPHeaderCapRejectsBeforeHandlerAllocation(t *testing.T) {
	var handlers atomic.Int32
	endpoint, err := New()
	if err != nil {
		t.Fatal(err)
	}
	defer endpoint.Close()
	server := NewHTTPServer("", http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		handlers.Add(1)
	}))
	if err := endpoint.Attach(server, "wss://unused/_hop"); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go server.Serve(listener) //nolint:errcheck
	defer server.Close()

	conn, err := net.Dial("tcp", listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	request := "GET /ordinary HTTP/1.1\r\nHost: localhost\r\nX-Fill: " +
		strings.Repeat("x", MaxWSSHeaderBytes+1) + "\r\n\r\n"
	_, _ = io.WriteString(conn, request)
	_ = conn.SetReadDeadline(time.Now().Add(time.Second))
	response, _ := io.ReadAll(conn)
	_ = conn.Close()
	if !strings.HasPrefix(string(response), "HTTP/1.1 431 ") {
		t.Fatalf("oversized header response=%q", response)
	}
	if handlers.Load() != 0 {
		t.Fatal("oversized headers reached the application handler")
	}
}

func TestTLSAndSlowHeadersShareOneAcceptanceDeadlineThenRecover(t *testing.T) {
	_, server, url := wssTestServerWithLimits(t, true, 2, 250*time.Millisecond)
	address := strings.TrimSuffix(strings.TrimPrefix(url, "wss://"), "/_hop")
	stalled, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer stalled.Close()
	waitForCondition(t, func() bool { return server.admission.count() == 1 }, "stalled TLS socket was not admitted")

	slow, err := tls.Dial("tcp", address, &tls.Config{InsecureSkipVerify: true}) //nolint:gosec // test cert
	if err != nil {
		t.Fatal(err)
	}
	defer slow.Close()
	if _, err := slow.Write([]byte("GET /_hop HTTP/1.1\r\nHost: localhost\r\n")); err != nil {
		t.Fatal(err)
	}
	ticker := time.NewTicker(40 * time.Millisecond)
	defer ticker.Stop()
	deadline := time.Now().Add(400 * time.Millisecond)
	for time.Now().Before(deadline) {
		<-ticker.C
		if _, err := slow.Write([]byte("X-Slow: x\r\n")); err != nil {
			break
		}
	}
	waitForCondition(t, func() bool { return server.admission.count() == 0 }, "absolute TLS/header deadline did not release sockets")

	recovered := dialTestWSS(t, url)
	_ = recovered.Close()
}

func TestWSSStalledAndMalformedClientsDoNotBlockNextUpgrade(t *testing.T) {
	_, _, url := wssTestServer(t)
	address := strings.TrimSuffix(strings.TrimPrefix(url, "ws://"), "/_hop")
	stalled, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer stalled.Close()
	_, _ = stalled.Write([]byte("GET /_hop HTTP/1.1\r\nHost: stalled"))

	valid := dialTestWSS(t, url)
	_ = valid.Close()

	malformed, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = malformed.Write([]byte("GET /_hop HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"))
	_ = malformed.SetReadDeadline(time.Now().Add(time.Second))
	buf := make([]byte, 256)
	_, _ = malformed.Read(buf)
	_ = malformed.Close()

	valid = dialTestWSS(t, url)
	_ = valid.Close()
}

func TestWSSPendingLinkCapRejectsCapPlusOneAndRecovers(t *testing.T) {
	_, _, url := wssTestServer(t)
	connections := make([]*websocket.Conn, 0, MaxPendingWSSLinks)
	defer func() {
		for _, conn := range connections {
			_ = conn.Close()
		}
	}()
	for i := 0; i < MaxPendingWSSLinks; i++ {
		connections = append(connections, dialTestWSS(t, url))
	}

	dialer := websocket.Dialer{HandshakeTimeout: WSSHandshakeTimeout}
	rejected, response, err := dialer.Dial(url, nil)
	if rejected != nil {
		_ = rejected.Close()
	}
	if response != nil && response.Body != nil {
		defer response.Body.Close()
	}
	if err == nil || response == nil || response.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("cap+1 err=%v status=%v", err, response)
	}

	_ = connections[len(connections)-1].Close()
	connections = connections[:len(connections)-1]
	deadline := time.Now().Add(time.Second)
	for {
		recovered, _, dialErr := dialer.Dial(url, nil)
		if dialErr == nil {
			connections = append(connections, recovered)
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("capacity was not released: %v", dialErr)
		}
		time.Sleep(time.Millisecond)
	}
}
