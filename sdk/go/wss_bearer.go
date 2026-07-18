package hop

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// The WSS Internet bearer: Hop's Noise transport ridden over a WebSocket, so an endpoint is reachable
// on 443 under a route (e.g. /_hop) with no new port. In Go a WS upgrade is a normal http.Handler, so
// the bearer and the well-known are both mux routes (see Attach). One WS message per drained packet,
// no length-prefix; core does the Noise handshake and all crypto over these bytes.

const (
	MaxWSSMessageBytes  = MaxFrameBytes
	MaxWSSHeaderBytes   = 16 << 10
	MaxPendingHTTPSocks = 64
	MaxPendingWSSLinks  = 64
	WSSHandshakeTimeout = 5 * time.Second
	WSSReadTimeout      = 15 * time.Second
	WSSWriteTimeout     = 5 * time.Second
	// net/http reserves an additional 4 KiB read buffer above Server.MaxHeaderBytes. Keeping the
	// configured budget at 12 KiB makes the parser's total pre-handler allocation cap exactly 16 KiB.
	netHTTPHeaderBudget = MaxWSSHeaderBytes - (4 << 10)
)

var (
	// ErrHTTPServerNotAttached prevents starting a server without Hop's pre-handler admission limits.
	ErrHTTPServerNotAttached = errors.New("Hop HTTP server must be attached before serving")
	// ErrHTTPServerStarted prevents changing admission after any socket could have been accepted.
	ErrHTTPServerStarted = errors.New("Hop HTTP server has already started")
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:    4096,
	WriteBufferSize:   4096,
	EnableCompression: false,
	CheckOrigin:       func(*http.Request) bool { return true },
}

// HTTPServer owns the only supported public serve path for an attached endpoint. It cannot start until
// Endpoint.Attach has installed raw-connection admission and all net/http limits.
type HTTPServer struct {
	server           *http.Server
	mu               sync.Mutex
	attached         bool
	started          bool
	admission        *httpAdmission
	maxPending       int
	handshakeTimeout time.Duration
}

// NewHTTPServer creates an unstarted server. handler receives every route except /_hop and
// /.well-known/hop; nil uses http.DefaultServeMux.
func NewHTTPServer(addr string, handler http.Handler) *HTTPServer {
	return &HTTPServer{
		server:           &http.Server{Addr: addr, Handler: handler},
		maxPending:       MaxPendingHTTPSocks,
		handshakeTimeout: WSSHandshakeTimeout,
	}
}

func configureHTTPServer(server *http.Server) {
	if server.MaxHeaderBytes <= 0 || server.MaxHeaderBytes > netHTTPHeaderBudget {
		server.MaxHeaderBytes = netHTTPHeaderBudget
	}
	if server.ReadHeaderTimeout <= 0 || server.ReadHeaderTimeout > WSSHandshakeTimeout {
		server.ReadHeaderTimeout = WSSHandshakeTimeout
	}
	if server.ReadTimeout <= 0 || server.ReadTimeout > WSSReadTimeout {
		server.ReadTimeout = WSSReadTimeout
	}
	if server.WriteTimeout <= 0 || server.WriteTimeout > WSSWriteTimeout {
		server.WriteTimeout = WSSWriteTimeout
	}
}

type admissionContextKey struct{}

type httpAdmission struct {
	mu      sync.Mutex
	slots   chan struct{}
	leases  map[net.Conn]*httpAdmissionLease
	timeout time.Duration
}

type httpAdmissionLease struct {
	once      sync.Once
	admission *httpAdmission
	conn      net.Conn
	timer     *time.Timer
}

func newHTTPAdmission(limit int, timeout time.Duration) *httpAdmission {
	return &httpAdmission{
		slots: make(chan struct{}, limit), leases: make(map[net.Conn]*httpAdmissionLease), timeout: timeout,
	}
}

func (a *httpAdmission) connState(conn net.Conn, state http.ConnState) {
	switch state {
	case http.StateNew:
		select {
		case a.slots <- struct{}{}:
			lease := &httpAdmissionLease{admission: a, conn: conn}
			a.mu.Lock()
			a.leases[conn] = lease
			a.mu.Unlock()
			lease.timer = time.AfterFunc(a.timeout, func() { _ = conn.Close() })
			if err := conn.SetDeadline(time.Now().Add(a.timeout)); err != nil {
				lease.release()
				_ = conn.Close()
			}
		default:
			// net/http invokes StateNew synchronously after Accept and before starting the
			// connection goroutine, so a rejected socket never reaches TLS or a handler.
			_ = conn.Close()
		}
	case http.StateHijacked, http.StateClosed:
		a.release(conn)
	}
}

func (a *httpAdmission) release(conn net.Conn) {
	a.mu.Lock()
	lease := a.leases[conn]
	a.mu.Unlock()
	if lease != nil {
		lease.release()
	}
}

func (a *httpAdmission) releaseRequest(request *http.Request) {
	if conn, ok := request.Context().Value(admissionContextKey{}).(net.Conn); ok {
		a.release(conn)
	}
}

func (a *httpAdmission) count() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.leases)
}

func (l *httpAdmissionLease) release() {
	l.once.Do(func() {
		if l.timer != nil {
			l.timer.Stop()
		}
		_ = l.conn.SetDeadline(time.Time{})
		l.admission.mu.Lock()
		delete(l.admission.leases, l.conn)
		l.admission.mu.Unlock()
		<-l.admission.slots
	})
}

func (s *HTTPServer) attach(endpoint *Endpoint, publicURL string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.started {
		return ErrHTTPServerStarted
	}
	if s.attached {
		return fmt.Errorf("Hop HTTP server is already attached")
	}

	configureHTTPServer(s.server)
	s.admission = newHTTPAdmission(s.maxPending, s.handshakeTimeout)
	previousState := s.server.ConnState
	s.server.ConnState = func(conn net.Conn, state http.ConnState) {
		s.admission.connState(conn, state)
		if previousState != nil {
			previousState(conn, state)
		}
	}
	previousContext := s.server.ConnContext
	s.server.ConnContext = func(ctx context.Context, conn net.Conn) context.Context {
		if previousContext != nil {
			ctx = previousContext(ctx, conn)
		}
		return context.WithValue(ctx, admissionContextKey{}, conn)
	}

	app := s.server.Handler
	if app == nil {
		app = http.DefaultServeMux
	}
	wss := endpoint.wssHandler()
	wellKnown := endpoint.WellKnownHandler(publicURL, 3600)
	s.server.Handler = http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/_hop":
			defer s.admission.releaseRequest(request)
			wss.ServeHTTP(writer, request)
		case wellKnownPath:
			s.admission.releaseRequest(request)
			wellKnown.ServeHTTP(writer, request)
		default:
			s.admission.releaseRequest(request)
			app.ServeHTTP(writer, request)
		}
	})
	s.attached = true
	return nil
}

func (s *HTTPServer) begin() (*http.Server, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.attached {
		return nil, ErrHTTPServerNotAttached
	}
	if s.started {
		return nil, ErrHTTPServerStarted
	}
	s.started = true
	return s.server, nil
}

// Serve starts an attached server on listener.
func (s *HTTPServer) Serve(listener net.Listener) error {
	server, err := s.begin()
	if err != nil {
		return err
	}
	return server.Serve(listener)
}

// ListenAndServe starts an attached plaintext server. Production WSS deployments should use TLS.
func (s *HTTPServer) ListenAndServe() error {
	server, err := s.begin()
	if err != nil {
		return err
	}
	return server.ListenAndServe()
}

// ListenAndServeTLS starts an attached TLS server with the configured absolute handshake deadline.
func (s *HTTPServer) ListenAndServeTLS(certFile, keyFile string) error {
	server, err := s.begin()
	if err != nil {
		return err
	}
	return server.ListenAndServeTLS(certFile, keyFile)
}

// Close immediately closes the listener and all accepted connections.
func (s *HTTPServer) Close() error { return s.server.Close() }

// Shutdown gracefully closes the server.
func (s *HTTPServer) Shutdown(ctx context.Context) error { return s.server.Shutdown(ctx) }

func wssHeaderBytes(r *http.Request) int {
	n := len(r.Method) + 1 + len(r.RequestURI) + 1 + len(r.Proto) + 2
	for name, values := range r.Header {
		for _, value := range values {
			n += len(name) + 2 + len(value) + 2
			if n > MaxWSSHeaderBytes {
				return n
			}
		}
	}
	return n + 2
}

func pumpConn(e *Endpoint, conn *websocket.Conn, role string, release func()) {
	link := nextLink()
	var closeOnce sync.Once
	closeLink := func() {
		closeOnce.Do(func() {
			_ = conn.Close()
			e.linkDown(link)
			release()
		})
	}
	// Only the pump goroutine writes a given conn (drain is single-threaded per endpoint), so a lone
	// read goroutine + pump writes is gorilla's supported one-reader-one-writer pattern.
	e.registerLink(link, role, func(b []byte) {
		if len(b) > MaxWSSMessageBytes {
			closeLink()
			return
		}
		_ = conn.SetWriteDeadline(time.Now().Add(WSSWriteTimeout))
		if err := conn.WriteMessage(websocket.BinaryMessage, b); err != nil {
			closeLink()
		}
	})
	e.registerCloser(closeLink)
	go func() {
		defer func() {
			_ = recover()
			closeLink()
		}()
		conn.SetReadLimit(MaxWSSMessageBytes)
		for {
			_ = conn.SetReadDeadline(time.Now().Add(WSSReadTimeout))
			messageType, msg, err := conn.ReadMessage()
			if err != nil {
				return
			}
			if messageType != websocket.BinaryMessage || len(msg) > MaxWSSMessageBytes {
				return
			}
			e.deliver(link, msg)
		}
	}()
}

// wssHandler upgrades an inbound HTTP request to a WSS bearer link (we are the Noise acceptor).
func (e *Endpoint) wssHandler() http.Handler {
	// The bearer cannot observe Noise completion, so a permit is retained until link teardown rather
	// than being released after the WebSocket upgrade.
	admission := make(chan struct{}, MaxPendingWSSLinks)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if wssHeaderBytes(r) > MaxWSSHeaderBytes {
			http.Error(w, "request headers too large", http.StatusRequestHeaderFieldsTooLarge)
			return
		}
		select {
		case admission <- struct{}{}:
		default:
			http.Error(w, "too many pending Hop links", http.StatusServiceUnavailable)
			return
		}
		var releaseOnce sync.Once
		release := func() { releaseOnce.Do(func() { <-admission }) }
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			release()
			return
		}
		pumpConn(e, conn, "acceptor", release)
	})
}

// dialWss connects to a reachable endpoint over WSS (we are the Noise initiator).
func (e *Endpoint) dialWss(url string, tlsConfig *tls.Config) error {
	dialer := websocket.Dialer{
		TLSClientConfig:  tlsConfig,
		HandshakeTimeout: WSSHandshakeTimeout,
		ReadBufferSize:   4096,
		WriteBufferSize:  4096,
	}
	conn, _, err := dialer.Dial(url, nil)
	if err != nil {
		return fmt.Errorf("WSS dial failed: %w", err)
	}
	pumpConn(e, conn, "dialer", func() {})
	return nil
}
