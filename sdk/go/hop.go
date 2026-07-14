// Package hop is the Go server-side endpoint SDK: receive Hop messages with an net/http-shaped
// surface, over the libhop C ABI via cgo. This file is the thin cgo layer; endpoint.go has the
// ergonomics. libhop is found via -L below; build it with `cargo build -p hop`.
package hop

/*
#cgo CFLAGS: -I${SRCDIR}/..
#cgo LDFLAGS: -L${SRCDIR}/../../target/debug -lhop -Wl,-rpath,${SRCDIR}/../../target/debug -Wl,-rpath,${SRCDIR}/../../target/debug/deps
#include <stdlib.h>
#include <string.h>
#include "hop.h"

// core's drain/poll take C function pointers. cgo can't pass a Go func as one directly, so we use
// tiny C trampolines that call back into exported Go functions, carrying the collector as a
// uintptr-encoded cgo.Handle in ctx.
extern void goDrainSink(uintptr_t ctx, uint64_t link, uint8_t *bytes, size_t len);
extern void goSvcReqSink(uintptr_t ctx, uint8_t *from, uint8_t *rid, char *service, char *method, uint8_t *args, size_t arglen);
extern void goSvcRespSink(uintptr_t ctx, uint8_t *from, uint8_t *forid, uint16_t status, uint8_t *body, size_t bodylen);

static void drain_tramp(void *ctx, uint64_t link, const uint8_t *b, size_t n) {
    goDrainSink((uintptr_t)ctx, link, (uint8_t *)b, n);
}
static void svcreq_tramp(void *ctx, const uint8_t *f, const uint8_t *r, const char *s, const char *m, const uint8_t *a, size_t n) {
    goSvcReqSink((uintptr_t)ctx, (uint8_t *)f, (uint8_t *)r, (char *)s, (char *)m, (uint8_t *)a, n);
}
static void svcresp_tramp(void *ctx, const uint8_t *f, const uint8_t *r, uint16_t st, const uint8_t *b, size_t n) {
    goSvcRespSink((uintptr_t)ctx, (uint8_t *)f, (uint8_t *)r, st, (uint8_t *)b, n);
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
*/
import "C"

import (
	"fmt"
	"runtime"
	"runtime/cgo"
	"unsafe"
)

const abiExpected = 3

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

// Endpoint clustering (DESIGN.md §40): join a cluster and dedup applies transparently to the poll.
func (n *node) clusterJoin(secret []byte) {
	cb := C.CBytes(secret)
	defer C.free(cb)
	C.hop_cluster_join(n.p, (*C.uint8_t)(cb))
}

func (n *node) clusterJoinPassphrase(pass []byte) {
	cb := C.CBytes(pass)
	defer C.free(cb)
	C.hop_cluster_join_passphrase(n.p, (*C.uint8_t)(cb), C.size_t(len(pass)))
}

func (n *node) clusterMembers() uint32 { return uint32(C.hop_cluster_members(n.p)) }

func (n *node) drainOutgoing() []OutPacket {
	var out []OutPacket
	h := cgo.NewHandle(&out)
	defer h.Delete()
	C.call_drain(n.p, C.uintptr_t(h))
	return out
}

func (n *node) sendServiceRequest(dst []byte, service, method string, args []byte) ([]byte, error) {
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

func toB58(addr []byte) string {
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
func goSvcRespSink(ctx C.uintptr_t, from, forid *C.uint8_t, status C.uint16_t, body *C.uint8_t, bodylen C.size_t) {
	out := cgo.Handle(ctx).Value().(*[]ServiceResp)
	*out = append(*out, ServiceResp{
		From:         C.GoBytes(unsafe.Pointer(from), 32),
		ForRequestID: C.GoBytes(unsafe.Pointer(forid), 32),
		Status:       uint16(status),
		Body:         C.GoBytes(unsafe.Pointer(body), C.int(bodylen)),
	})
}
