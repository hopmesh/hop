package hop

import (
	"crypto/tls"
	"net/http"

	"github.com/gorilla/websocket"
)

// The WSS Internet bearer: Hop's Noise transport ridden over a WebSocket, so an endpoint is reachable
// on 443 under a route (e.g. /_hop) with no new port. In Go a WS upgrade is a normal http.Handler, so
// the bearer and the well-known are both mux routes (see Attach). One WS message per drained packet,
// no length-prefix; core does the Noise handshake and all crypto over these bytes.

var upgrader = websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}

func pumpConn(e *Endpoint, conn *websocket.Conn, role string) {
	link := nextLink()
	// Only the pump goroutine writes a given conn (drain is single-threaded per endpoint), so a lone
	// read goroutine + pump writes is gorilla's supported one-reader-one-writer pattern.
	e.registerLink(link, role, func(b []byte) { _ = conn.WriteMessage(websocket.BinaryMessage, b) })
	go func() {
		defer e.linkDown(link)
		defer conn.Close()
		for {
			_, msg, err := conn.ReadMessage()
			if err != nil {
				return
			}
			e.deliver(link, msg)
		}
	}()
}

// wssHandler upgrades an inbound HTTP request to a WSS bearer link (we are the Noise acceptor).
func (e *Endpoint) wssHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		pumpConn(e, conn, "acceptor")
	})
}

// dialWss connects to a reachable endpoint over WSS (we are the Noise initiator).
func (e *Endpoint) dialWss(url string, tlsConfig *tls.Config) error {
	dialer := websocket.Dialer{TLSClientConfig: tlsConfig}
	conn, _, err := dialer.Dial(url, nil)
	if err != nil {
		return err
	}
	pumpConn(e, conn, "dialer")
	return nil
}
