package hop

import (
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// Discovery: bind a human name to a Hop address without DNSSEC, using the domain's TLS cert (WebPKI)
// plus a self-certifying reachability record served at /.well-known/hop. See docs/endpoint-sdk.md.

const wellKnownPath = "/.well-known/hop"

// SignReach signs a self-certifying reachability record for this endpoint's address bound to endpoint
// (e.g. "wss://myaddress.com/_hop"), valid ttlSecs from now.
func (e *Endpoint) SignReach(endpoint string, ttlSecs uint32) []byte {
	var rec []byte
	e.withNode(func(n *node) { rec = signReach(n, endpoint, ttlSecs) })
	return rec
}

// VerifyReach verifies a reachability record (0 nowSecs skips the expiry check).
func VerifyReach(record []byte, nowSecs uint64) (ReachInfo, bool) {
	return verifyReach(record, nowSecs)
}

func (e *Endpoint) wellKnownBody(publicURL string, ttlSecs uint32) []byte {
	rec := e.SignReach(publicURL, ttlSecs)
	b, _ := json.Marshal(map[string]string{
		"address":  e.Address(),
		"endpoint": publicURL,
		"reach":    base64.StdEncoding.EncodeToString(rec),
	})
	return b
}

// WellKnownHandler serves the /.well-known/hop discovery body (mount it in any mux).
func (e *Endpoint) WellKnownHandler(publicURL string, ttlSecs uint32) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write(e.wellKnownBody(publicURL, ttlSecs))
	})
}

// Attach wires this endpoint into a mux IN ONE CALL: the WSS bearer at /_hop and the /.well-known/hop
// discovery responder. publicURL is where senders reach the endpoint, e.g. "wss://myaddress.com/_hop".
func (e *Endpoint) Attach(mux *http.ServeMux, publicURL string) {
	mux.Handle("/_hop", e.wssHandler())
	mux.Handle(wellKnownPath, e.WellKnownHandler(publicURL, 3600))
}

// Resolve fetches + verifies baseURL's well-known, returning the reachable address (base58) + wss URL.
func Resolve(client *http.Client, baseURL string) (address, wssURL string, err error) {
	res, err := client.Get(strings.TrimRight(baseURL, "/") + wellKnownPath)
	if err != nil {
		return "", "", err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("well-known fetch failed: HTTP %d", res.StatusCode)
	}
	var body struct {
		Reach string `json:"reach"`
	}
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		return "", "", err
	}
	rec, err := base64.StdEncoding.DecodeString(body.Reach)
	if err != nil {
		return "", "", err
	}
	info, ok := verifyReach(rec, uint64(time.Now().Unix()))
	if !ok {
		return "", "", fmt.Errorf("reach record failed verification (bad signature or expired)")
	}
	return toB58(info.Address), info.Endpoint, nil
}

// DialByName resolves a base HTTPS URL to a verified endpoint, dials its WSS, and returns the reachable
// address (then use Request). Set insecureTLS only for a dev/self-signed cert.
func (e *Endpoint) DialByName(baseURL string, insecureTLS bool) (string, error) {
	client := http.DefaultClient
	var tlsConfig *tls.Config
	if insecureTLS {
		tlsConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec // dev/self-signed only
		client = &http.Client{Transport: &http.Transport{TLSClientConfig: tlsConfig}}
	}
	address, wssURL, err := Resolve(client, baseURL)
	if err != nil {
		return "", err
	}
	if err := e.dialWss(wssURL, tlsConfig); err != nil {
		return "", err
	}
	return address, nil
}
