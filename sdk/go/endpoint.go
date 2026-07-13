package hop

import (
	"fmt"
	"sync"
	"time"
)

// Request is an inbound service request. From is the cryptographically verified sender identity.
type Request struct {
	From      string // base58
	FromBytes []byte
	Service   string
	Method    string
	Args      []byte
}

// Reply seals a hops:// response back to the request's caller. status is a uint16 (HTTP-shaped).
type Reply func(status uint16, body []byte) bool

// Handler receives an inbound request. Delivery is durable store-and-forward; a reply may arrive
// later. Treat it like a queue consumer, not a synchronous HTTP handler.
type Handler func(req *Request, reply Reply)

type config struct {
	key    []byte
	tickMs int
}

// Option configures New.
type Option func(*config)

// WithKey opens the endpoint with a saved 32-byte identity secret (a stable address).
func WithKey(k []byte) Option { return func(c *config) { c.key = k } }

// WithTickMs sets the pump interval (default 50ms).
func WithTickMs(ms int) Option { return func(c *config) { c.tickMs = ms } }

// Endpoint receives Hop messages with an net/http-shaped surface, over hop-core.
type Endpoint struct {
	n        *node
	mu       sync.Mutex
	nodeMu   sync.Mutex // serializes every libhop call on n vs. Close so a late bearer goroutine
	handlers map[string]Handler
	links    map[uint64]func([]byte)
	pending  map[string]chan [2]interface{} // reqID -> {status, body}
	done     chan struct{}
	closers  []func() // bearer teardown hooks (listeners/conns), run by Close before freeing n
	closed   bool
}

// withNode runs a libhop call on the node under nodeMu, unless the endpoint has been closed (in which
// case n may already be freed, so we must not touch it). Returns false when closed. Never held across a
// handler or bearer IO, so a reply issued from a handler can re-enter via its own withNode.
func (e *Endpoint) withNode(fn func(n *node)) bool {
	e.nodeMu.Lock()
	defer e.nodeMu.Unlock()
	if e.closed {
		return false
	}
	fn(e.n)
	return true
}

// registerCloser records a bearer teardown hook. If already closed, it fires immediately.
func (e *Endpoint) registerCloser(c func()) {
	e.nodeMu.Lock()
	closed := e.closed
	if !closed {
		e.closers = append(e.closers, c)
	}
	e.nodeMu.Unlock()
	if closed {
		c()
	}
}

// New starts an endpoint and its pump loop.
func New(opts ...Option) (*Endpoint, error) {
	if err := assertABI(); err != nil {
		return nil, err
	}
	cfg := config{tickMs: 50}
	for _, o := range opts {
		o(&cfg)
	}
	var n *node
	if cfg.key != nil {
		n = nodeWithSecret(cfg.key)
	} else {
		n = nodeNew()
	}
	e := &Endpoint{
		n:        n,
		handlers: map[string]Handler{},
		links:    map[uint64]func([]byte){},
		pending:  map[string]chan [2]interface{}{},
		done:     make(chan struct{}),
	}
	n.tick(nowMs())
	n.publishPrekey()
	go e.pumpLoop(time.Duration(cfg.tickMs) * time.Millisecond)
	return e, nil
}

// On registers a receiver for a hops:// service.
func (e *Endpoint) On(service string, h Handler) {
	e.mu.Lock()
	e.handlers[service] = h
	e.mu.Unlock()
	e.withNode(func(n *node) { n.subscribe(service) })
}

// Address is this endpoint's base58 address (publish it, or its HNS name).
func (e *Endpoint) Address() string {
	var s string
	e.withNode(func(n *node) { s = toB58(n.address()) })
	return s
}

// DefaultRequestTimeout bounds Request when no explicit timeout is given (aligns with the other SDKs,
// which default the timeout too).
const DefaultRequestTimeout = 15 * time.Second

// Request calls a service on a remote endpoint (dst is a base58 address). Blocks until the response
// returns (delay-tolerant) or DefaultRequestTimeout elapses. Use RequestTimeout to override.
func (e *Endpoint) Request(dst, service, method string, args []byte) (uint16, []byte, error) {
	return e.RequestTimeout(dst, service, method, args, DefaultRequestTimeout)
}

// RequestTimeout is Request with an explicit timeout.
func (e *Endpoint) RequestTimeout(dst, service, method string, args []byte, timeout time.Duration) (uint16, []byte, error) {
	dstBytes, err := fromB58(dst)
	if err != nil {
		return 0, nil, err
	}
	var reqID []byte
	var sErr error
	if !e.withNode(func(n *node) { reqID, sErr = n.sendServiceRequest(dstBytes, service, method, args) }) {
		return 0, nil, fmt.Errorf("endpoint is closed")
	}
	if sErr != nil {
		return 0, nil, sErr
	}
	ch := make(chan [2]interface{}, 1)
	key := string(reqID)
	e.mu.Lock()
	e.pending[key] = ch
	e.mu.Unlock()
	select {
	case r := <-ch:
		return r[0].(uint16), r[1].([]byte), nil
	case <-time.After(timeout):
		e.mu.Lock()
		delete(e.pending, key)
		e.mu.Unlock()
		return 0, nil, fmt.Errorf("hops://%s/%s timed out after %s", service, method, timeout)
	}
}

// ---- bearer seam (used by the TCP bearer) ----
func (e *Endpoint) registerLink(link uint64, role string, send func([]byte)) {
	e.mu.Lock()
	e.links[link] = send
	e.mu.Unlock()
	e.withNode(func(n *node) { n.connected(link, role == "dialer") })
}

func (e *Endpoint) deliver(link uint64, data []byte) {
	e.withNode(func(n *node) { n.received(link, data) })
}

func (e *Endpoint) linkDown(link uint64) {
	e.mu.Lock()
	delete(e.links, link)
	e.mu.Unlock()
	e.withNode(func(n *node) { n.disconnected(link) })
}

func (e *Endpoint) pumpLoop(dt time.Duration) {
	t := time.NewTicker(dt)
	defer t.Stop()
	for {
		select {
		case <-e.done:
			return
		case <-t.C:
			e.pump()
		}
	}
}

func (e *Endpoint) pump() {
	// Each node call is its own withNode; the lock is never held across a bearer send or a handler, so
	// a reply issued from a handler re-enters via its own withNode without deadlocking.
	var out []OutPacket
	if !e.withNode(func(n *node) {
		n.tick(nowMs())
		out = n.drainOutgoing()
	}) {
		return // closed
	}
	for _, p := range out {
		e.mu.Lock()
		send := e.links[p.Link]
		e.mu.Unlock()
		if send != nil {
			send(p.Bytes)
		}
	}
	var reqs []ServiceReq
	e.withNode(func(n *node) { reqs = n.takeServiceRequests() })
	for _, r := range reqs {
		e.mu.Lock()
		h := e.handlers[r.Service]
		e.mu.Unlock()
		if h != nil {
			req := &Request{From: toB58(r.From), FromBytes: r.From, Service: r.Service, Method: r.Method, Args: r.Args}
			to, rid := r.From, r.RequestID
			reply := Reply(func(status uint16, body []byte) bool {
				ok := false
				e.withNode(func(n *node) { ok = n.sendServiceResponse(to, rid, status, body) })
				return ok
			})
			h(req, reply)
		}
	}
	var resps []ServiceResp
	e.withNode(func(n *node) { resps = n.takeServiceResponses() })
	for _, r := range resps {
		key := string(r.ForRequestID)
		e.mu.Lock()
		ch := e.pending[key]
		delete(e.pending, key)
		e.mu.Unlock()
		if ch != nil {
			ch <- [2]interface{}{r.Status, r.Body}
		}
	}
}

// Close stops the pump, shuts the bearers, and frees the node. Safe against a late bearer goroutine:
// once closed is set, every withNode call short-circuits, so a recvLoop firing linkDown as its socket
// closes cannot dereference a freed node.
func (e *Endpoint) Close() {
	e.nodeMu.Lock()
	if e.closed {
		e.nodeMu.Unlock()
		return
	}
	e.closed = true
	closers := e.closers
	e.closers = nil
	e.nodeMu.Unlock()

	close(e.done)               // stop the pump loop
	for _, c := range closers { // stop bearer accept/recv goroutines so they exit
		func() { defer func() { _ = recover() }(); c() }()
	}
	// Free under nodeMu: any in-flight withNode has released it, and new ones see closed and skip.
	e.nodeMu.Lock()
	e.n.free()
	e.nodeMu.Unlock()
}

func nowMs() uint64 { return uint64(time.Now().UnixMilli()) }
