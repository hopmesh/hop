package hop

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
)

const MaxFrameBytes = 1 << 20

func frameLenOK(n uint32) bool { return n <= MaxFrameBytes }

// The Internet bearer: opaque Hop frames over TCP, core does the Noise. TCP is a stream, so each
// drained packet is length-prefixed (4-byte big-endian) and reassembled on the far side. HNS would
// resolve a name to host/port/key; here you pass them directly.

var linkSeq uint64 = 40000

func nextLink() uint64 { return atomic.AddUint64(&linkSeq, 1) }

func sendFramed(conn net.Conn, buf []byte) {
	frame := make([]byte, 4+len(buf))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(buf)))
	copy(frame[4:], buf)
	_, _ = conn.Write(frame) // only the pump goroutine writes a given conn, so no concurrent writes
}

func recvLoop(e *Endpoint, conn net.Conn, link uint64) {
	defer conn.Close()
	defer e.linkDown(link)
	hdr := make([]byte, 4)
	for {
		if _, err := io.ReadFull(conn, hdr); err != nil {
			return
		}
		n := binary.BigEndian.Uint32(hdr)
		if !frameLenOK(n) {
			return
		}
		frame := make([]byte, int(n))
		if _, err := io.ReadFull(conn, frame); err != nil {
			return
		}
		e.deliver(link, frame)
	}
}

// Listen accepts inbound Hop connections; each accepted socket is one bearer link (we are acceptor).
func Listen(e *Endpoint, port int) (net.Listener, error) {
	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", port))
	if err != nil {
		return nil, err
	}
	e.registerCloser(func() { _ = ln.Close() }) // Close() stops the accept loop (Accept then errors)
	var connMu sync.Mutex
	conns := make(map[net.Conn]struct{})
	closing := false
	e.registerCloser(func() {
		connMu.Lock()
		closing = true
		for conn := range conns {
			_ = conn.Close()
		}
		connMu.Unlock()
	})
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			connMu.Lock()
			if closing {
				connMu.Unlock()
				_ = conn.Close()
				continue
			}
			conns[conn] = struct{}{}
			connMu.Unlock()
			link := nextLink()
			c := conn
			e.registerLink(link, "acceptor", func(b []byte) { sendFramed(c, b) })
			go func() {
				recvLoop(e, conn, link)
				connMu.Lock()
				delete(conns, conn)
				connMu.Unlock()
			}()
		}
	}()
	return ln, nil
}

// Dial connects to a reachable endpoint (we are the Noise initiator).
func Dial(e *Endpoint, host string, port int) (net.Conn, error) {
	conn, err := net.Dial("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err == nil {
		e.registerCloser(func() { _ = conn.Close() }) // Close() ends recvLoop's read
	}
	if err != nil {
		return nil, err
	}
	link := nextLink()
	e.registerLink(link, "dialer", func(b []byte) { sendFramed(conn, b) })
	go recvLoop(e, conn, link)
	return conn, nil
}

// ConnectInProcess wires two endpoints directly (in-process bearer), no sockets.
func ConnectInProcess(a, b *Endpoint) {
	// The dialer can emit Noise message 1 as soon as its link is registered.
	// Install the acceptor first so the direct callback cannot drop it.
	b.registerLink(22, "acceptor", func(buf []byte) { a.deliver(11, buf) })
	a.registerLink(11, "dialer", func(buf []byte) { b.deliver(22, buf) })
}
