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
	handlers map[string]Handler
	links    map[uint64]func([]byte)
	pending  map[string]chan [2]interface{} // reqID -> {status, body}
	done     chan struct{}
	closed   bool
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
	e.n.subscribe(service)
}

// Address is this endpoint's base58 address (publish it, or its HNS name).
func (e *Endpoint) Address() string { return toB58(e.n.address()) }

// Request calls a service on a remote endpoint (dst is a base58 address). Blocks until the response
// returns (delay-tolerant), or the timeout elapses.
func (e *Endpoint) Request(dst, service, method string, args []byte, timeout time.Duration) (uint16, []byte, error) {
	dstBytes, err := fromB58(dst)
	if err != nil {
		return 0, nil, err
	}
	reqID, err := e.n.sendServiceRequest(dstBytes, service, method, args)
	if err != nil {
		return 0, nil, err
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
	e.n.connected(link, role == "dialer")
}

func (e *Endpoint) deliver(link uint64, data []byte) { e.n.received(link, data) }

func (e *Endpoint) linkDown(link uint64) {
	e.mu.Lock()
	delete(e.links, link)
	e.mu.Unlock()
	e.n.disconnected(link)
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
	e.n.tick(nowMs())
	for _, p := range e.n.drainOutgoing() {
		e.mu.Lock()
		send := e.links[p.Link]
		e.mu.Unlock()
		if send != nil {
			send(p.Bytes)
		}
	}
	for _, r := range e.n.takeServiceRequests() {
		e.mu.Lock()
		h := e.handlers[r.Service]
		e.mu.Unlock()
		if h != nil {
			req := &Request{From: toB58(r.From), FromBytes: r.From, Service: r.Service, Method: r.Method, Args: r.Args}
			to, rid := r.From, r.RequestID
			reply := Reply(func(status uint16, body []byte) bool { return e.n.sendServiceResponse(to, rid, status, body) })
			h(req, reply)
		}
	}
	for _, r := range e.n.takeServiceResponses() {
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

// Close stops the pump and frees the node.
func (e *Endpoint) Close() {
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return
	}
	e.closed = true
	e.mu.Unlock()
	close(e.done)
	e.n.free()
}

func nowMs() uint64 { return uint64(time.Now().UnixMilli()) }
