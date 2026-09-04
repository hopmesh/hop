// Package hop is the Go server-side endpoint SDK: receive Hop messages with an net/http-shaped
// surface, over the libhop C ABI via cgo. This file is the thin cgo layer; endpoint.go has the
// ergonomics. libhop is found via -L below; build it with `cargo build -p hop`.
package hop

/*
#cgo CFLAGS: -I${SRCDIR}/..
#cgo LDFLAGS: -L${SRCDIR}/../../target/debug -lhop -Wl,-rpath,${SRCDIR}/../../target/debug -Wl,-rpath,${SRCDIR}/../../target/debug/deps
#include <stdlib.h>
#include <string.h>
#include <hop.h>

// core's drain/poll take C function pointers. cgo can't pass a Go func as one directly, so we use
// tiny C trampolines that call back into exported Go functions, carrying the collector as a
// uintptr-encoded cgo.Handle in ctx.
extern void goDrainSink(uintptr_t ctx, uint64_t link, uint8_t *bytes, size_t len);
extern void goSvcReqSink(uintptr_t ctx, uint8_t *from, uint8_t *rid, char *service, char *method, uint8_t *args, size_t arglen);
extern bool goSvcRespSink(uintptr_t ctx, uint8_t *from, uint8_t *forid, uint16_t status, uint8_t *body, size_t bodylen);

static void drain_tramp(void *ctx, uint64_t link, const uint8_t *b, size_t n) {
    goDrainSink((uintptr_t)ctx, link, (uint8_t *)b, n);
}
static bool svcreq_tramp(void *ctx, const uint8_t *f, const uint8_t *r, const char *s, const char *m, const uint8_t *a, uintptr_t n) {
    goSvcReqSink((uintptr_t)ctx, (uint8_t *)f, (uint8_t *)r, (char *)s, (char *)m, (uint8_t *)a, n);
    return true;
}
static bool svcresp_tramp(void *ctx, const uint8_t *f, const uint8_t *r, uint16_t st, const uint8_t *b, size_t n) {
    return goSvcRespSink((uintptr_t)ctx, (uint8_t *)f, (uint8_t *)r, st, (uint8_t *)b, n);
}

static void call_drain(const HopNode *node, uintptr_t ctx) { hop_drain_outgoing(node, drain_tramp, (void *)ctx); }
static void call_poll_reqs(const HopNode *node, uintptr_t ctx) { hop_poll_service_requests(node, svcreq_tramp, (void *)ctx); }
static void call_poll_resps(const HopNode *node, uintptr_t ctx) { hop_poll_service_responses(node, svcresp_tramp, (void *)ctx); }

extern void goReachSignSink(uintptr_t ctx, uint8_t *bytes, size_t len);
extern void goReachVerifySink(uintptr_t ctx, uint8_t *addr, char *endpoint, uint64_t issued_at, uint32_t ttl_secs);
static void reach_sign_tramp(void *ctx, const uint8_t *b, size_t n) { goReachSignSink((uintptr_t)ctx, (uint8_t *)b, n); }
static void reach_verify_tramp(void *ctx, const uint8_t *a, const char *e, uint64_t i, uint32_t t) {
    goReachVerifySink((uintptr_t)ctx, (uint8_t *)a, (char *)e, i, t);
}
static void call_sign_reach(const HopNode *node, const char *endpoint, uint32_t ttl, uintptr_t ctx) {
    hop_sign_reach_record(node, endpoint, ttl, reach_sign_tramp, (void *)ctx);
}
static bool call_verify_reach(const uint8_t *bytes, size_t len, uint64_t now, uintptr_t ctx) {
    return hop_verify_reach_record(bytes, len, now, reach_verify_tramp, (void *)ctx);
}

// §32 hps:// pub/sub. Five more sink shapes, same trampoline + cgo.Handle mechanism as above: the
// publication sink is the only one that RETURNS a bool, because that return is the accept-to-remove
// decision core acts on (true drops the row, false leaves it queued), exactly like hop_poll_inbox.
extern bool goHpsMsgSink(uintptr_t ctx, uint8_t *id, char *path, uint8_t *sender, uint8_t *body, size_t len);
extern void goHpsInviteSink(uintptr_t ctx, uint8_t *host, char *path, uint32_t kind);
extern void goHpsAddrSink(uintptr_t ctx, uint8_t *addr);
extern void goHpsTopicSink(uintptr_t ctx, uint8_t *host, char *path, uint32_t kind, bool hosting, uint32_t access);
extern void goHpsBrowseSink(uintptr_t ctx, uint8_t *host, char *path, uint32_t kind, char *title, char *summary, uint32_t access);

static bool hpsmsg_tramp(void *ctx, const uint8_t *i, const char *p, const uint8_t *s, const uint8_t *b, uintptr_t n) {
    return goHpsMsgSink((uintptr_t)ctx, (uint8_t *)i, (char *)p, (uint8_t *)s, (uint8_t *)b, (size_t)n);
}
static void hpsinv_tramp(void *ctx, const uint8_t *h, const char *p, uint32_t k) {
    goHpsInviteSink((uintptr_t)ctx, (uint8_t *)h, (char *)p, k);
}
// One trampoline serves hop_hps_pending, hop_hps_members and hop_hps_rekey: all three hand back a
// bare 32-byte blob per row (an address, an address, a bundle id), so the C function-pointer type is
// the same and a second copy would only be a second thing to keep in step.
static void hpsaddr_tramp(void *ctx, const uint8_t *a) { goHpsAddrSink((uintptr_t)ctx, (uint8_t *)a); }
static void hpstopic_tramp(void *ctx, const uint8_t *h, const char *p, uint32_t k, bool hosting, uint32_t a) {
    goHpsTopicSink((uintptr_t)ctx, (uint8_t *)h, (char *)p, k, hosting, a);
}
static void hpsbrowse_tramp(void *ctx, const uint8_t *h, const char *p, uint32_t k, const char *t, const char *s, uint32_t a) {
    goHpsBrowseSink((uintptr_t)ctx, (uint8_t *)h, (char *)p, k, (char *)t, (char *)s, a);
}

static void call_poll_hps_messages(const HopNode *node, uintptr_t ctx) { hop_poll_hps_messages(node, hpsmsg_tramp, (void *)ctx); }
static void call_poll_hps_invites(const HopNode *node, uintptr_t ctx) { hop_poll_hps_invites(node, hpsinv_tramp, (void *)ctx); }
static uintptr_t call_hps_pending(const HopNode *node, const char *path, uintptr_t ctx) {
    return hop_hps_pending(node, path, hpsaddr_tramp, (void *)ctx);
}
static uintptr_t call_hps_members(const HopNode *node, const char *path, uintptr_t ctx) {
    return hop_hps_members(node, path, hpsaddr_tramp, (void *)ctx);
}
static intptr_t call_hps_rekey(const HopNode *node, const char *path, const char *new_path,
                               const uint8_t *remove, uintptr_t remove_count, uintptr_t ctx) {
    return hop_hps_rekey(node, path, new_path, remove, remove_count, hpsaddr_tramp, (void *)ctx);
}
static uintptr_t call_hps_my_topics(const HopNode *node, uintptr_t ctx) { return hop_hps_my_topics(node, hpstopic_tramp, (void *)ctx); }
static uintptr_t call_hps_browse(const HopNode *node, uintptr_t ctx) { return hop_hps_browse(node, hpsbrowse_tramp, (void *)ctx); }
*/
import "C"

import (
	"fmt"
	"runtime"
	"runtime/cgo"
	"unsafe"
)

const abiExpected = 7

// OutPacket is one drained outbound frame for a link.
type OutPacket struct {
	Link  uint64
	Bytes []byte
}

// ServiceReq is an inbound hops:// service request.
type ServiceReq struct {
	From      []byte
	RequestID []byte
	Service   string
	Method    string
	Args      []byte
}

// ServiceResp is an inbound hops:// service response.
type ServiceResp struct {
	From         []byte
	ForRequestID []byte
	Status       uint16
	Body         []byte
}

// node wraps the opaque C handle.
type node struct{ p *C.HopNode }

func assertABI() error {
	if got := uint32(C.hop_abi_version()); got != abiExpected {
		return fmt.Errorf("libhop ABI mismatch: header expects %d, library reports %d", abiExpected, got)
	}
	return nil
}

func require32(value []byte, name string) error {
	if len(value) != 32 {
		return fmt.Errorf("%s must be exactly 32 bytes, got %d", name, len(value))
	}
	return nil
}

func nodeNew() *node { return &node{p: (*C.HopNode)(C.hop_node_new())} }

func nodeWithSecret(secret []byte) *node {
	cb := C.CBytes(secret)
	defer C.free(cb)
	return &node{p: (*C.HopNode)(C.hop_node_with_secret((*C.uint8_t)(cb), C.size_t(len(secret))))}
}

func (n *node) free()             { C.hop_node_free(n.p) }
func (n *node) tick(nowMs uint64) { C.hop_node_tick(n.p, C.uint64_t(nowMs)) }

func (n *node) address() []byte {
	out := make([]byte, 32)
	C.hop_node_address(n.p, (*C.uint8_t)(unsafe.Pointer(&out[0])))
	runtime.KeepAlive(out)
	return out
}

func (n *node) connected(link uint64, initiator bool) {
	role := C.uint32_t(1)
	if initiator {
		role = 0
	}
	C.hop_link_up(n.p, C.uint64_t(link), role)
}

func (n *node) disconnected(link uint64) { C.hop_link_down(n.p, C.uint64_t(link)) }

func (n *node) received(link uint64, data []byte) {
	if len(data) == 0 {
		return
	}
	cb := C.CBytes(data)
	defer C.free(cb)
	C.hop_bytes_received(n.p, C.uint64_t(link), (*C.uint8_t)(cb), C.size_t(len(data)))
}

func (n *node) subscribe(topic string) {
	cs := C.CString(topic)
	defer C.free(unsafe.Pointer(cs))
	C.hop_subscribe(n.p, cs)
}

func (n *node) publishPrekey() bool { return bool(C.hop_publish_prekey(n.p)) }

func (n *node) acceptInbox(id []byte) (bool, error) {
	if err := require32(id, "inbox id"); err != nil {
		return false, err
	}
	cid := C.CBytes(id)
	defer C.free(cid)
	return bool(C.hop_accept_inbox(n.p, (*C.uint8_t)(cid))), nil
}

// Endpoint clustering (DESIGN.md §40): join a cluster and dedup applies transparently to the poll.
func (n *node) clusterJoin(secret []byte) error {
	if err := require32(secret, "cluster secret"); err != nil {
		return err
	}
	cb := C.CBytes(secret)
	defer C.free(cb)
	C.hop_cluster_join(n.p, (*C.uint8_t)(cb))
	return nil
}

func (n *node) clusterJoinPassphrase(pass []byte) {
	cb := C.CBytes(pass)
	defer C.free(cb)
	C.hop_cluster_join_passphrase(n.p, (*C.uint8_t)(cb), C.size_t(len(pass)))
}

func (n *node) clusterMembers() uint32 { return uint32(C.hop_cluster_members(n.p)) }

func (n *node) clusterSetQuorum(min uint32) { C.hop_cluster_set_quorum(n.p, C.uint32_t(min)) }

// §19 relay pool. PLAT-003: these four calls are the whole stated reason for the v4 -> v5 ABI bump,
// and no C-ABI wrapper bound them, so an SDK-only host had no way to fail over off a dead relay.

func (n *node) relayAdd(url string, configured bool) bool {
	cs := C.CString(url)
	defer C.free(unsafe.Pointer(cs))
	return bool(C.hop_relay_add(n.p, cs, C.bool(configured)))
}

// relayNext returns the relay to dial right now and whether there is one at all. The 2 KiB buffer is
// far past any real endpoint URL; the C call writes nothing and returns 0 if a URL would not fit,
// which surfaces here as "nothing to dial".
func (n *node) relayNext() (string, bool) {
	buf := make([]byte, 2048)
	got := C.hop_relay_next(n.p, (*C.char)(unsafe.Pointer(&buf[0])), C.size_t(len(buf)))
	runtime.KeepAlive(buf)
	if got == 0 {
		return "", false
	}
	return string(buf[:int(got)]), true
}

func (n *node) relayReport(url string, ok bool) {
	cs := C.CString(url)
	defer C.free(unsafe.Pointer(cs))
	C.hop_relay_report(n.p, cs, C.bool(ok))
}

func (n *node) relayPool() (total, available int) {
	var avail C.size_t
	t := C.hop_relay_pool_size(n.p, &avail)
	return int(t), int(avail)
}

func (n *node) drainOutgoing() []OutPacket {
	var out []OutPacket
	h := cgo.NewHandle(&out)
	defer h.Delete()
	C.call_drain(n.p, C.uintptr_t(h))
	return out
}

func (n *node) sendServiceRequest(dst []byte, service, method string, args []byte) ([]byte, error) {
	if err := require32(dst, "destination"); err != nil {
		return nil, err
	}
	cdst, cargs := C.CBytes(dst), C.CBytes(args)
	cs, cm := C.CString(service), C.CString(method)
	defer func() { C.free(cdst); C.free(cargs); C.free(unsafe.Pointer(cs)); C.free(unsafe.Pointer(cm)) }()
	outID := make([]byte, 32)
	ok := C.hop_send_service_request(n.p, (*C.uint8_t)(cdst), cs, cm, (*C.uint8_t)(cargs), C.size_t(len(args)), (*C.uint8_t)(unsafe.Pointer(&outID[0])))
	runtime.KeepAlive(outID)
	if !bool(ok) {
		return nil, fmt.Errorf("hop_send_service_request failed")
	}
	return outID, nil
}

func (n *node) sendServiceResponse(to, forRequestID []byte, status uint16, body []byte) bool {
	if require32(to, "response destination") != nil || require32(forRequestID, "request id") != nil {
		return false
	}
	cto, cfor, cbody := C.CBytes(to), C.CBytes(forRequestID), C.CBytes(body)
	defer func() { C.free(cto); C.free(cfor); C.free(cbody) }()
	return bool(C.hop_send_service_response(n.p, (*C.uint8_t)(cto), (*C.uint8_t)(cfor), C.uint16_t(status), (*C.uint8_t)(cbody), C.size_t(len(body))))
}

func (n *node) takeServiceRequests() []ServiceReq {
	var out []ServiceReq
	h := cgo.NewHandle(&out)
	defer h.Delete()
	C.call_poll_reqs(n.p, C.uintptr_t(h))
	return out
}

func (n *node) takeServiceResponses() []ServiceResp {
	var out []ServiceResp
	h := cgo.NewHandle(&out)
	defer h.Delete()
	C.call_poll_resps(n.p, C.uintptr_t(h))
	return out
}

func (n *node) acceptServiceResponse(requestID []byte) (bool, error) {
	if err := require32(requestID, "request id"); err != nil {
		return false, err
	}
	id := C.CBytes(requestID)
	defer C.free(id)
	return bool(C.hop_accept_service_response(n.p, (*C.uint8_t)(id))), nil
}

func (n *node) isEncrypted() bool {
	return bool(C.hop_node_is_encrypted(n.p))
}

func (n *node) acceptServiceRequest(requestID []byte) (bool, error) {
	if err := require32(requestID, "request id"); err != nil {
		return false, err
	}
	id := C.CBytes(requestID)
	defer C.free(id)
	return bool(C.hop_accept_service_request(n.p, (*C.uint8_t)(id))), nil
}

func (n *node) rejectServiceRequest(requestID []byte) (bool, error) {
	if err := require32(requestID, "request id"); err != nil {
		return false, err
	}
	id := C.CBytes(requestID)
	defer C.free(id)
	return bool(C.hop_reject_service_request(n.p, (*C.uint8_t)(id))), nil
}

// §32 hps:// pub/sub, the surface the v5 -> v6 ABI bump added: the C ABI had no hps exports at all,
// so nothing sitting on it could host, join or post to a channel. A Hop group message is NOT
// one-to-one fan-out and NOT a multicast bundle: it is a single content-key-encrypted,
// per-writer-signed publication, flooded once. Membership, invites and revocation are properties of
// the topic's KEY HANDOFF, which is why the calls below talk about keys rather than about
// recipients: approve seals keys, rekey mints a new content key for the members it keeps, and a
// removed member keeps only the dead key.

// HpsKind is which shape of topic is hosted at a path: a channel every member writes to (each
// publication signed by its writer) or a service only the owner broadcasts on (signed by the
// service key). Crosses the C ABI as a plain uint32 discriminant.
type HpsKind uint32

const (
	HpsKindChannel HpsKind = 0
	HpsKindService HpsKind = 1
)

// HpsAccess is how a topic's keys are obtained: handed to anyone who asks, handed over after the
// host approves a queued request, or only after the host invites a destination and it accepts.
type HpsAccess uint32

const (
	HpsAccessOpen          HpsAccess = 0
	HpsAccessRequestToJoin HpsAccess = 1
	HpsAccessInvite        HpsAccess = 2
)

// HpsVisibility is whether the host broadcasts an app-encrypted discovery advert for the topic, so
// same-app peers can browse it, or keeps it reachable only by a known address plus path or an invite.
type HpsVisibility uint32

const (
	HpsVisibilityPrivate      HpsVisibility = 0
	HpsVisibilityDiscoverable HpsVisibility = 1
)

// HpsMessage is one received publication. Sender is the VERIFIED writer for a channel and the host
// for a service; ID is what acceptHpsMessage takes.
type HpsMessage struct {
	ID     []byte
	Path   string
	Sender []byte
	Body   []byte
}

// HpsInvite is an invite this node received to a topic hosted elsewhere.
type HpsInvite struct {
	Host []byte
	Path string
	Kind HpsKind
}

// HpsTopic is one topic this node hosts or follows, as persisted by the node: an app rebuilds its
// channel list from these after a restart, because the node persists topics and the app's in-memory
// list does not.
type HpsTopic struct {
	Host    []byte
	Path    string
	Kind    HpsKind
	Hosting bool
	Access  HpsAccess
}

// HpsTopicInfo is a discoverable topic seen on the mesh: a descriptor a Discoverable host broadcast,
// decrypted with the app secret, so it only ever surfaces topics from the same app fabric.
type HpsTopicInfo struct {
	Host    []byte
	Path    string
	Kind    HpsKind
	Title   string
	Summary string
	Access  HpsAccess
}

// hpsRegister hosts a topic at path, minting and persisting its keys. The returned key is the
// service pubkey for a service topic and EMPTY for a channel, whose writers sign with their own
// identity. That is why the error, not the length, reports failure: a zero-length key is a channel
// registered successfully, and conflating the two would report every channel as a failure.
//
// kind, access and visibility cross as uint32 discriminants, and an out-of-range value FAILS the
// call rather than being defaulted. Never coerce one back into range: reading a garbage int as
// HpsAccessOpen would hand a topic's content key to anyone who asks for it.
func (n *node) hpsRegister(path string, kind HpsKind, access HpsAccess, visibility HpsVisibility) ([]byte, error) {
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	// A service key is 32 bytes. The spare capacity means a longer key would still be returned
	// rather than turning into a false "did not register", which is what a too-small buffer produces.
	buf := make([]byte, 64)
	var got C.uintptr_t
	ok := C.hop_hps_register(n.p, cp, C.uint32_t(kind), C.uint32_t(access), C.uint32_t(visibility),
		(*C.uint8_t)(unsafe.Pointer(&buf[0])), C.uintptr_t(len(buf)), &got)
	runtime.KeepAlive(buf)
	if !bool(ok) {
		return nil, fmt.Errorf("hop_hps_register(%q) failed", path)
	}
	return buf[:int(got)], nil
}

// hpsSubscribe seals a keys request to host for hps://{host}/{path}. Open access replies with the
// keys, RequestToJoin queues us for approval, Invite ignores us: a subscribe id is proof the request
// went out, never proof of membership.
func (n *node) hpsSubscribe(host []byte, path string) ([]byte, error) {
	if err := require32(host, "hps host"); err != nil {
		return nil, err
	}
	chost, cp := C.CBytes(host), C.CString(path)
	defer func() { C.free(chost); C.free(unsafe.Pointer(cp)) }()
	out := make([]byte, 32)
	ok := C.hop_hps_subscribe(n.p, (*C.uint8_t)(chost), cp, (*C.uint8_t)(unsafe.Pointer(&out[0])))
	runtime.KeepAlive(out)
	if !bool(ok) {
		return nil, fmt.Errorf("hop_hps_subscribe(%q) failed", path)
	}
	return out, nil
}

// hpsPublish encrypts body once to the topic's content key, signs it (service key for a service, our
// own identity for a channel), and floods it once. One publication, not one per member.
func (n *node) hpsPublish(path string, body []byte) ([]byte, error) {
	cp, cb := C.CString(path), C.CBytes(body)
	defer func() { C.free(unsafe.Pointer(cp)); C.free(cb) }()
	out := make([]byte, 32)
	ok := C.hop_hps_publish(n.p, cp, (*C.uint8_t)(cb), C.uintptr_t(len(body)), (*C.uint8_t)(unsafe.Pointer(&out[0])))
	runtime.KeepAlive(out)
	if !bool(ok) {
		return nil, fmt.Errorf("hop_hps_publish(%q) failed", path)
	}
	return out, nil
}

// pollHpsMessages drains received publications. The sink's return is host acceptance, the same
// accept-to-remove contract as hop_poll_inbox: true and core durably removes that publication now,
// false and it stays queued for redelivery until acceptHpsMessage clears it. A host that persists
// asynchronously returns false here and accepts by id once its own write landed.
func (n *node) pollHpsMessages(sink func(HpsMessage) bool) {
	h := cgo.NewHandle(sink)
	defer h.Delete()
	C.call_poll_hps_messages(n.p, C.uintptr_t(h))
}

// acceptHpsMessage durably accepts one publication by id, for a host that refused it at poll time.
func (n *node) acceptHpsMessage(id []byte) (bool, error) {
	if err := require32(id, "hps message id"); err != nil {
		return false, err
	}
	cid := C.CBytes(id)
	defer C.free(cid)
	return bool(C.hop_accept_hps_message(n.p, (*C.uint8_t)(cid))), nil
}

// hpsInvite invites dest to a topic we host. Keys are sealed only once dest accepts, so the returned
// id is the invite bundle, not a key handoff.
func (n *node) hpsInvite(path string, dest []byte) ([]byte, error) {
	if err := require32(dest, "invite destination"); err != nil {
		return nil, err
	}
	cp, cd := C.CString(path), C.CBytes(dest)
	defer func() { C.free(unsafe.Pointer(cp)); C.free(cd) }()
	out := make([]byte, 32)
	ok := C.hop_hps_invite(n.p, cp, (*C.uint8_t)(cd), (*C.uint8_t)(unsafe.Pointer(&out[0])))
	runtime.KeepAlive(out)
	if !bool(ok) {
		return nil, fmt.Errorf("hop_hps_invite(%q) failed", path)
	}
	return out, nil
}

// hpsAcceptInvite accepts an invite we received, after which the host seals us the topic keys.
func (n *node) hpsAcceptInvite(host []byte, path string) ([]byte, error) {
	if err := require32(host, "invite host"); err != nil {
		return nil, err
	}
	chost, cp := C.CBytes(host), C.CString(path)
	defer func() { C.free(chost); C.free(unsafe.Pointer(cp)) }()
	out := make([]byte, 32)
	ok := C.hop_hps_accept_invite(n.p, (*C.uint8_t)(chost), cp, (*C.uint8_t)(unsafe.Pointer(&out[0])))
	runtime.KeepAlive(out)
	if !bool(ok) {
		return nil, fmt.Errorf("hop_hps_accept_invite(%q) failed", path)
	}
	return out, nil
}

// hpsDeclineInvite drops a received invite DURABLY, so it does not reappear after a restart.
func (n *node) hpsDeclineInvite(host []byte, path string) bool {
	if require32(host, "invite host") != nil {
		return false
	}
	chost, cp := C.CBytes(host), C.CString(path)
	defer func() { C.free(chost); C.free(unsafe.Pointer(cp)) }()
	return bool(C.hop_hps_decline_invite(n.p, (*C.uint8_t)(chost), cp))
}

// pollHpsInvites drains received invites, CLEARING them. Unlike the publication queue this is
// take-and-clear, not accept-to-remove: an invite the host does not act on is gone, so a host must
// persist what it surfaces.
func (n *node) pollHpsInvites() []HpsInvite {
	var out []HpsInvite
	h := cgo.NewHandle(&out)
	defer h.Delete()
	C.call_poll_hps_invites(n.p, C.uintptr_t(h))
	return out
}

// hpsLeave leaves a topic so its host stops re-keying us on rotation. The second return is whether
// there was a bundle at all: leaving a topic we HOST sends nothing, which is a success with no id
// rather than a failure, and only a false error return means the call failed.
func (n *node) hpsLeave(path string) ([]byte, bool, error) {
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	out := make([]byte, 32)
	var hasID C.bool
	ok := C.hop_hps_leave(n.p, cp, (*C.uint8_t)(unsafe.Pointer(&out[0])), &hasID)
	runtime.KeepAlive(out)
	if !bool(ok) {
		return nil, false, fmt.Errorf("hop_hps_leave(%q) failed", path)
	}
	if !bool(hasID) {
		return nil, false, nil
	}
	return out, true, nil
}

// hpsPending lists the join requests queued on a RequestToJoin topic we host, each a requester
// address awaiting hpsApprove or hpsDeny.
func (n *node) hpsPending(path string) [][]byte {
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	var out [][]byte
	h := cgo.NewHandle(&out)
	defer h.Delete()
	C.call_hps_pending(n.p, cp, C.uintptr_t(h))
	return out
}

// hpsApprove seals the topic keys to a pending requester: this, not the subscribe, is the moment
// membership happens.
func (n *node) hpsApprove(path string, requester []byte) ([]byte, error) {
	if err := require32(requester, "requester"); err != nil {
		return nil, err
	}
	cp, cr := C.CString(path), C.CBytes(requester)
	defer func() { C.free(unsafe.Pointer(cp)); C.free(cr) }()
	out := make([]byte, 32)
	ok := C.hop_hps_approve(n.p, cp, (*C.uint8_t)(cr), (*C.uint8_t)(unsafe.Pointer(&out[0])))
	runtime.KeepAlive(out)
	if !bool(ok) {
		return nil, fmt.Errorf("hop_hps_approve(%q) failed", path)
	}
	return out, nil
}

// hpsDeny drops a pending request without sealing any keys.
func (n *node) hpsDeny(path string, requester []byte) bool {
	if require32(requester, "requester") != nil {
		return false
	}
	cp, cr := C.CString(path), C.CBytes(requester)
	defer func() { C.free(unsafe.Pointer(cp)); C.free(cr) }()
	return bool(C.hop_hps_deny(n.p, cp, (*C.uint8_t)(cr)))
}

// hpsRekey is selective forward rotation, which is how a member is REVOKED: a new content key sealed
// to every retained member, so a removed address keeps only the dead key and can still read the
// history it already has and nothing published afterwards. An empty newPath keeps the path; a
// non-empty one moves the topic. Returns the rekey bundle ids.
//
// The C call takes a COUNT of 32-byte addresses packed back to back, not a byte length, so remove is
// flattened here and the count passed separately.
func (n *node) hpsRekey(path, newPath string, remove [][]byte) ([][]byte, error) {
	packed := make([]byte, 0, len(remove)*32)
	for _, addr := range remove {
		if err := require32(addr, "revoked member"); err != nil {
			return nil, err
		}
		packed = append(packed, addr...)
	}
	cp, cn := C.CString(path), C.CString(newPath)
	defer func() { C.free(unsafe.Pointer(cp)); C.free(unsafe.Pointer(cn)) }()
	var removed *C.uint8_t
	if len(packed) > 0 {
		removed = (*C.uint8_t)(unsafe.Pointer(&packed[0]))
	}
	var out [][]byte
	h := cgo.NewHandle(&out)
	defer h.Delete()
	res := C.call_hps_rekey(n.p, cp, cn, removed, C.uintptr_t(len(remove)), C.uintptr_t(h))
	runtime.KeepAlive(packed)
	if res < 0 {
		return nil, fmt.Errorf("hop_hps_rekey(%q) failed", path)
	}
	return out, nil
}

// hpsReach is how many distinct addresses have acked a publication on a topic. A flood has no
// per-recipient receipt, so this is the only delivery sense a UI can honestly show.
func (n *node) hpsReach(path string) uint32 {
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	return uint32(C.hop_hps_reach(n.p, cp))
}

// hpsMembers is the retained-member set for a topic we host, the addresses a rekey would seal to.
func (n *node) hpsMembers(path string) [][]byte {
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	var out [][]byte
	h := cgo.NewHandle(&out)
	defer h.Delete()
	C.call_hps_members(n.p, cp, C.uintptr_t(h))
	return out
}

// hpsMyTopics is every topic this node hosts or follows, from the node's own persisted state.
func (n *node) hpsMyTopics() []HpsTopic {
	var out []HpsTopic
	h := cgo.NewHandle(&out)
	defer h.Delete()
	C.call_hps_my_topics(n.p, C.uintptr_t(h))
	return out
}

// hpsBrowse is the discoverable topics seen on the mesh, decrypted with the app secret, so a foreign
// app's topics are not merely filtered out here but unreadable.
func (n *node) hpsBrowse() []HpsTopicInfo {
	var out []HpsTopicInfo
	h := cgo.NewHandle(&out)
	defer h.Delete()
	C.call_hps_browse(n.p, C.uintptr_t(h))
	return out
}

func toB58(addr []byte) string {
	if require32(addr, "address") != nil {
		return ""
	}
	cb := C.CBytes(addr)
	defer C.free(cb)
	out := make([]byte, 64)
	nn := C.hop_address_to_base58((*C.uint8_t)(cb), (*C.char)(unsafe.Pointer(&out[0])), 64)
	runtime.KeepAlive(out)
	return string(out[:nn])
}

func fromB58(text string) ([]byte, error) {
	cs := C.CString(text)
	defer C.free(unsafe.Pointer(cs))
	out := make([]byte, 32)
	if !bool(C.hop_address_from_base58(cs, (*C.uint8_t)(unsafe.Pointer(&out[0])))) {
		return nil, fmt.Errorf("not a valid Hop address: %s", text)
	}
	runtime.KeepAlive(out)
	return out, nil
}

// ReachInfo is a verified reachability record: which Address is reachable at which Endpoint.
type ReachInfo struct {
	Address  []byte
	Endpoint string
	IssuedAt uint64
	TtlSecs  uint32
}

func signReach(n *node, endpoint string, ttlSecs uint32) []byte {
	ce := C.CString(endpoint)
	defer C.free(unsafe.Pointer(ce))
	var out []byte
	h := cgo.NewHandle(&out)
	defer h.Delete()
	C.call_sign_reach(n.p, ce, C.uint32_t(ttlSecs), C.uintptr_t(h))
	return out
}

func verifyReach(record []byte, nowSecs uint64) (ReachInfo, bool) {
	var info ReachInfo
	h := cgo.NewHandle(&info)
	defer h.Delete()
	var ptr *C.uint8_t
	if len(record) > 0 {
		ptr = (*C.uint8_t)(unsafe.Pointer(&record[0]))
	}
	ok := bool(C.call_verify_reach(ptr, C.size_t(len(record)), C.uint64_t(nowSecs), C.uintptr_t(h)))
	runtime.KeepAlive(record)
	return info, ok
}

//export goReachSignSink
func goReachSignSink(ctx C.uintptr_t, bytes *C.uint8_t, length C.size_t) {
	out := cgo.Handle(ctx).Value().(*[]byte)
	*out = C.GoBytes(unsafe.Pointer(bytes), C.int(length))
}

//export goReachVerifySink
func goReachVerifySink(ctx C.uintptr_t, addr *C.uint8_t, endpoint *C.char, issuedAt C.uint64_t, ttlSecs C.uint32_t) {
	info := cgo.Handle(ctx).Value().(*ReachInfo)
	info.Address = C.GoBytes(unsafe.Pointer(addr), 32)
	info.Endpoint = C.GoString(endpoint)
	info.IssuedAt = uint64(issuedAt)
	info.TtlSecs = uint32(ttlSecs)
}

//export goDrainSink
func goDrainSink(ctx C.uintptr_t, link C.uint64_t, bytes *C.uint8_t, length C.size_t) {
	out := cgo.Handle(ctx).Value().(*[]OutPacket)
	*out = append(*out, OutPacket{Link: uint64(link), Bytes: C.GoBytes(unsafe.Pointer(bytes), C.int(length))})
}

//export goSvcReqSink
func goSvcReqSink(ctx C.uintptr_t, from, rid *C.uint8_t, service, method *C.char, args *C.uint8_t, arglen C.size_t) {
	out := cgo.Handle(ctx).Value().(*[]ServiceReq)
	*out = append(*out, ServiceReq{
		From:      C.GoBytes(unsafe.Pointer(from), 32),
		RequestID: C.GoBytes(unsafe.Pointer(rid), 32),
		Service:   C.GoString(service),
		Method:    C.GoString(method),
		Args:      C.GoBytes(unsafe.Pointer(args), C.int(arglen)),
	})
}

//export goSvcRespSink
func goSvcRespSink(ctx C.uintptr_t, from, forid *C.uint8_t, status C.uint16_t, body *C.uint8_t, bodylen C.size_t) C.bool {
	out := cgo.Handle(ctx).Value().(*[]ServiceResp)
	*out = append(*out, ServiceResp{
		From:         C.GoBytes(unsafe.Pointer(from), 32),
		ForRequestID: C.GoBytes(unsafe.Pointer(forid), 32),
		Status:       uint16(status),
		Body:         C.GoBytes(unsafe.Pointer(body), C.int(bodylen)),
	})
	return C.bool(false)
}

// goHpsMsgSink is the one sink whose RETURN matters: it is the host's accept-to-remove decision,
// handed straight back to core, so the Go closure decides whether the publication is dropped now or
// stays queued.
//
//export goHpsMsgSink
func goHpsMsgSink(ctx C.uintptr_t, id *C.uint8_t, path *C.char, sender, body *C.uint8_t, bodylen C.size_t) C.bool {
	accept := cgo.Handle(ctx).Value().(func(HpsMessage) bool)
	return C.bool(accept(HpsMessage{
		ID:     C.GoBytes(unsafe.Pointer(id), 32),
		Path:   C.GoString(path),
		Sender: C.GoBytes(unsafe.Pointer(sender), 32),
		Body:   C.GoBytes(unsafe.Pointer(body), C.int(bodylen)),
	}))
}

//export goHpsInviteSink
func goHpsInviteSink(ctx C.uintptr_t, host *C.uint8_t, path *C.char, kind C.uint32_t) {
	out := cgo.Handle(ctx).Value().(*[]HpsInvite)
	*out = append(*out, HpsInvite{
		Host: C.GoBytes(unsafe.Pointer(host), 32),
		Path: C.GoString(path),
		Kind: HpsKind(kind),
	})
}

// goHpsAddrSink collects the bare 32-byte rows: pending requesters, retained members, and rekey
// bundle ids all arrive through this one shape.
//
//export goHpsAddrSink
func goHpsAddrSink(ctx C.uintptr_t, addr *C.uint8_t) {
	out := cgo.Handle(ctx).Value().(*[][]byte)
	*out = append(*out, C.GoBytes(unsafe.Pointer(addr), 32))
}

//export goHpsTopicSink
func goHpsTopicSink(ctx C.uintptr_t, host *C.uint8_t, path *C.char, kind C.uint32_t, hosting C.bool, access C.uint32_t) {
	out := cgo.Handle(ctx).Value().(*[]HpsTopic)
	*out = append(*out, HpsTopic{
		Host:    C.GoBytes(unsafe.Pointer(host), 32),
		Path:    C.GoString(path),
		Kind:    HpsKind(kind),
		Hosting: bool(hosting),
		Access:  HpsAccess(access),
	})
}

//export goHpsBrowseSink
func goHpsBrowseSink(ctx C.uintptr_t, host *C.uint8_t, path *C.char, kind C.uint32_t, title, summary *C.char, access C.uint32_t) {
	out := cgo.Handle(ctx).Value().(*[]HpsTopicInfo)
	*out = append(*out, HpsTopicInfo{
		Host:    C.GoBytes(unsafe.Pointer(host), 32),
		Path:    C.GoString(path),
		Kind:    HpsKind(kind),
		Title:   C.GoString(title),
		Summary: C.GoString(summary),
		Access:  HpsAccess(access),
	})
}
