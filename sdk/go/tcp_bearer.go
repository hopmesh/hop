package hop

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync/atomic"
)

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
	defer e.linkDown(link)
	hdr := make([]byte, 4)
	for {
		if _, err := io.ReadFull(conn, hdr); err != nil {
			return
		}
		frame := make([]byte, binary.BigEndian.Uint32(hdr))
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
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			link := nextLink()
			c := conn
			e.registerLink(link, "acceptor", func(b []byte) { sendFramed(c, b) })
			go recvLoop(e, conn, link)
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
	a.registerLink(11, "dialer", func(buf []byte) { b.deliver(22, buf) })
	b.registerLink(22, "acceptor", func(buf []byte) { a.deliver(11, buf) })
}
