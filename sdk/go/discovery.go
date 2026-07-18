package hop

import (
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

// Discovery: bind a human name to a Hop address using the domain's TLS cert (WebPKI)
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

// Attach wires the WSS bearer and discovery responder into an unstarted HTTPServer and atomically
// installs acceptance-time admission, TLS/header deadlines, parser caps, and worker limits.
func (e *Endpoint) Attach(server *HTTPServer, publicURL string) error {
	if server == nil {
		return fmt.Errorf("Hop HTTP server is nil")
	}
	return server.attach(e, publicURL)
}

// Resolve fetches + verifies baseURL's well-known, returning the reachable address (base58) + wss URL.
func Resolve(client *http.Client, baseURL string) (address, wssURL string, err error) {
	base, err := url.Parse(baseURL)
	if err != nil || base.Scheme != "https" || base.Host == "" || base.User != nil {
		return "", "", fmt.Errorf("discovery base URL must be an HTTPS origin without credentials")
	}
	base.Path = wellKnownPath
	base.RawPath = ""
	base.RawQuery = ""
	base.Fragment = ""
	if client == nil {
		client = http.DefaultClient
	}
	strictClient := *client
	strictClient.CheckRedirect = func(_ *http.Request, _ []*http.Request) error {
		return fmt.Errorf("well-known redirects are not allowed")
	}
	res, err := strictClient.Get(base.String())
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
