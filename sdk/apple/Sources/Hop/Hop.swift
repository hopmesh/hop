// Hop, the thin idiomatic Swift wrapper over libhop's C ABI (CHop / hop.h).
//
// Every method is a direct, type-safe shim over a `hop_*` C call; the cross-language contract lives
// in the generated header, so this layer can't diverge from it semantically; it only adds Swift
// ergonomics (Data, String, closures, an owning class). Bearers and apps use THIS, never raw C.

import CHop
import Foundation
import HopContract   // HopRole + the Bearer contract (pure Swift, no libhop)

/// A decrypted message delivered to this node.
public struct HopMessage {
    public let id: Data            // stable 32-byte inbox id
    public let from: Data          // sender's 32-byte address
    public let contentType: String
    public let body: Data
    public let hops: UInt8         // forward-path length A→B
    public let createdAt: UInt64   // sender clock (ms) at creation
}

/// Delivery status of a message we sent.
public struct HopStatus {
    public let relayed: UInt32     // distinct peers handed a copy
    public let delivered: Bool     // destination confirmed
    public let forwardHops: UInt8  // forward-path length the destination reported
    public let forwardMs: UInt32   // forward-path latency (ms) the destination reported
}

/// An hops:// request delivered to this node acting as a service.
public struct HopServiceRequest {
    public let from: Data
    public let requestId: Data
    public let service: String
    public let method: String
    public let args: Data
}

/// An hops:// response delivered to this node acting as a caller.
public struct HopServiceResponse {
    public let from: Data
    public let forRequestId: Data
    public let status: UInt16
    public let body: Data
}

// MARK: - hps:// pub/sub types (DESIGN.md section 32)
//
// A publication on a topic is ONE bundle: encrypted once to the topic's content key, signed by its
// writer, flooded once. It is not one-to-one fan-out and not a multicast bundle, so there is no
// per-recipient copy and no per-recipient receipt. Membership, invites and revocation are all
// properties of that content key's handoff, which is why the calls below are about keys and topics
// rather than about recipient lists.

/// Whether a topic's writers are its members (a channel) or only its owner (a service).
///
/// The raw values mirror the `HopHpsKind` discriminants in hop.h and cross the ABI as a plain
/// `uint32_t`. Swift requires enum raw values to be literals, so the tie to the C enum is by
/// contract; hop.h is the source of truth, and libhop REJECTS a discriminant it does not know
/// rather than defaulting one, which is what keeps a garbage int from reading as a permissive mode.
public enum HpsKind: UInt32 {
    /// Anyone holding the content key reads AND writes; each publication is signed by its writer.
    case channel = 0
    /// Only the owner broadcasts (signed by the service key); subscribers read.
    case service = 1
}

/// Who may obtain a topic's content key.
public enum HpsAccess: UInt32 {
    /// Keys handed to anyone who asks (anonymous membership).
    case open = 0
    /// The requester asks and the host approves before keys are handed off.
    case requestToJoin = 1
    /// The host invites a destination, which accepts, and only then receives keys.
    case invite = 2
}

/// Whether a topic announces itself for discovery.
public enum HpsVisibility: UInt32 {
    /// Reachable only by a known address plus path, or by an invite.
    ///
    /// Spelled `topicPrivate` because `private` is a Swift keyword: a `.private` case would have to
    /// be written with backticks at every single call site.
    case topicPrivate = 0
    /// The host broadcasts an app-encrypted discovery advert, so same-app peers can browse it.
    case discoverable = 1
}

/// An hps:// publication delivered to this node.
public struct HopHpsMessage {
    public let id: Data       // stable 32-byte publication id; the handle `acceptHpsMessage` takes
    public let path: String
    public let sender: Data   // the VERIFIED writer for a channel, the host for a service
    public let body: Data
}

/// An invite to a topic, received from its host.
public struct HopHpsInvite {
    public let host: Data
    public let path: String
    public let kind: HpsKind
}

/// A topic this node hosts or follows, as the node persisted it.
public struct HopHpsTopic {
    public let host: Data
    public let path: String
    public let kind: HpsKind
    public let hosting: Bool
    public let access: HpsAccess
}

/// A discoverable topic seen on the mesh: the descriptor a `discoverable` host broadcasts.
public struct HopHpsTopicInfo {
    public let host: Data
    public let path: String
    public let kind: HpsKind
    public let title: String
    public let summary: String
    public let access: HpsAccess
}

/// A running Hop node. Owns the underlying `libhop` handle; thread-safe inside (interior mutex).
public final class HopNode {
    /// Expected libhop ABI version (mirrors HOP_ABI_VERSION in hop.h). Asserted once on first use so a
    /// wrapper built against a newer header fails loudly instead of drifting (F-28).
    public static let expectedABIVersion: UInt32 = 6
    private static let abiChecked: Bool = {
        precondition(hop_abi_version() == HopNode.expectedABIVersion,
                     "libhop ABI mismatch: wrapper expects \(HopNode.expectedABIVersion), library is \(hop_abi_version())")
        return true
    }()

    private let raw: OpaquePointer   // const HopNode* from libhop

    private init(raw: OpaquePointer) {
        _ = HopNode.abiChecked   // trigger the one-time ABI check
        self.raw = raw
    }

    /// A fresh identity with ephemeral (in-memory) storage.
    ///
    /// Returns nil only if the C constructor caught a panic and handed back NULL (F-26); the host
    /// can surface that as a recoverable failure instead of trapping. On a healthy build this never
    /// fails, but the wrapper honors the ABI's NULL-on-panic contract rather than force-unwrapping.
    public static func ephemeral() -> HopNode? { hop_node_new().map { HopNode(raw: $0) } }

    /// Restore from a saved 32-byte identity `secret` (empty = fresh) with ephemeral storage.
    ///
    /// Returns nil only on the ABI's NULL-on-panic path (F-26), mirroring `open`/`openKeyed`.
    public static func with(secret: Data) -> HopNode? {
        let p: OpaquePointer? = secret.withUnsafeBytes {
            hop_node_with_secret($0.bindMemory(to: UInt8.self).baseAddress, UInt($0.count))
        }
        return p.map { HopNode(raw: $0) }
    }

    /// Open with persistent storage at `dbPath`, a saved identity `secret` (empty = fresh), and an
    /// `appSecret` (empty = open fabric). Returns nil only on a NULL/invalid path.
    public static func open(dbPath: String, secret: Data = Data(), appSecret: Data = Data()) -> HopNode? {
        let p: OpaquePointer? = dbPath.withCString { db in
            secret.withUnsafeBytes { s in
                appSecret.withUnsafeBytes { a in
                    hop_node_open(db,
                                  s.bindMemory(to: UInt8.self).baseAddress, UInt(s.count),
                                  a.bindMemory(to: UInt8.self).baseAddress, UInt(a.count))
                }
            }
        }
        return p.map { HopNode(raw: $0) }
    }

    /// Like `open`, but ENCRYPTS the store at rest (SQLCipher) with a raw `key` from the Keychain (F-25).
    public static func openKeyed(dbPath: String, key: Data, secret: Data = Data(), appSecret: Data = Data()) -> HopNode? {
        let p: OpaquePointer? = dbPath.withCString { db in
            secret.withUnsafeBytes { s in
                appSecret.withUnsafeBytes { a in
                    key.withUnsafeBytes { k in
                        hop_node_open_keyed(db,
                                            s.bindMemory(to: UInt8.self).baseAddress, UInt(s.count),
                                            a.bindMemory(to: UInt8.self).baseAddress, UInt(a.count),
                                            k.bindMemory(to: UInt8.self).baseAddress, UInt(k.count))
                    }
                }
            }
        }
        return p.map { HopNode(raw: $0) }
    }

    deinit { hop_node_free(raw) }

    // MARK: identity

    /// This node's 32-byte address.
    public var address: Data {
        var out = Data(count: 32)
        out.withUnsafeMutableBytes { _ = hop_node_address(raw, $0.bindMemory(to: UInt8.self).baseAddress) }
        return out
    }

    /// This node's 32-byte identity secret; persist it to restore the node later.
    public var secret: Data {
        var out = Data(count: 32)
        let n = out.withUnsafeMutableBytes { hop_node_secret(raw, $0.bindMemory(to: UInt8.self).baseAddress) }
        return out.prefix(Int(n))
    }

    public func setName(_ name: String) { name.withCString { hop_node_set_name(raw, $0) } }

    // MARK: relay pool (DESIGN.md §19)

    // PLAT-003: these four were the whole stated reason for the v4 -> v5 ABI bump and no C-ABI
    // wrapper bound them, so an SDK-only integrator could reach the pool through nothing and was
    // stuck with a single fixed relay URL: exactly the failure §19 exists to remove. The wrapper
    // now exposes them, and tools/codegen/check-abi-version.sh fails if a wrapper pinned to an ABI
    // level stops binding the calls that level's bump note names.

    /// Offer a relay endpoint to the pool. `configured` marks an operator/user choice, which a
    /// gossiped endpoint can never demote. Returns true if the endpoint is now pooled.
    @discardableResult
    public func relayAdd(_ url: String, configured: Bool = true) -> Bool {
        url.withCString { hop_relay_add(raw, $0, configured) }
    }

    /// The relay to dial right now, or nil when there is nothing dialable.
    ///
    /// nil with a non-zero `relayPool().total` is the degraded "every candidate is backed off"
    /// state: WAIT and retry, do not report the node offline. nil with a zero total is an empty
    /// pool. The 2 KiB buffer is far past any real endpoint URL; the C call writes nothing and
    /// returns 0 if a URL would not fit, which this reports as "nothing to dial".
    public func relayNext() -> String? {
        var buf = [CChar](repeating: 0, count: 2048)
        let n = hop_relay_next(raw, &buf, UInt(buf.count))
        return n == 0 ? nil : String(cString: buf)
    }

    /// Report a dial outcome so the pool can score it. A success clears that endpoint's failure
    /// history; failures back it off exponentially and always eventually recover.
    public func relayReport(_ url: String, ok: Bool) {
        url.withCString { hop_relay_report(raw, $0, ok) }
    }

    /// Pooled endpoints: `total` known, `available` dialable right now.
    public func relayPool() -> (total: Int, available: Int) {
        var available: UInt = 0
        let total = hop_relay_pool_size(raw, &available)
        return (Int(total), Int(available))
    }

    // MARK: clock + directory

    public func tick(nowMs: UInt64) { hop_node_tick(raw, nowMs) }
    @discardableResult public func publishPrekey() -> Bool { hop_publish_prekey(raw) }
    public func subscribe(_ topic: String) { topic.withCString { hop_subscribe(raw, $0) } }

    // MARK: bearer seam (the part a Bearer drives)

    public func linkUp(_ link: UInt64, role: HopRole) {
        // core-ffi-05: hop_link_up takes the role as a plain uint32_t (the HopLinkRole discriminant),
        // so pass the enum's rawValue rather than the HopLinkRole enum value itself.
        hop_link_up(raw, link, (role == .dialer ? HopLinkRole_Dialer : HopLinkRole_Acceptor).rawValue)
    }
    public func linkDown(_ link: UInt64) { hop_link_down(raw, link) }

    public func bytesReceived(_ link: UInt64, _ bytes: Data) {
        bytes.withUnsafeBytes { hop_bytes_received(raw, link, $0.bindMemory(to: UInt8.self).baseAddress, UInt($0.count)) }
    }

    /// Drain queued outbound packets; `sink(link, bytes)` is called once per packet, synchronously.
    public func drainOutgoing(_ sink: (UInt64, Data) -> Void) {
        withoutActuallyEscaping(sink) { escaping in
            var local = escaping
            withUnsafeMutablePointer(to: &local) { ctx in
                hop_drain_outgoing(raw, { rawCtx, link, bytes, len in
                    let cb = rawCtx!.assumingMemoryBound(to: ((UInt64, Data) -> Void).self).pointee
                    cb(link, len == 0 ? Data() : Data(bytes: bytes!, count: Int(len)))
                }, UnsafeMutableRawPointer(ctx))
            }
        }
    }

    // MARK: messaging

    /// Send an untraceable (§39) message to a 32-byte `dst`. Returns the bundle id, or nil on error.
    @discardableResult
    public func send(to dst: Data, contentType: String = "text/plain", body: Data, requestAck: Bool = false) -> Data? {
        send(dst: dst, contentType: contentType, body: body, requestAck: requestAck, direct: false)
    }

    /// Send to a directly-connected peer (the directed §27 path). Returns the bundle id, or nil.
    @discardableResult
    public func sendTo(peer dst: Data, contentType: String = "text/plain", body: Data, requestAck: Bool = false) -> Data? {
        send(dst: dst, contentType: contentType, body: body, requestAck: requestAck, direct: true)
    }

    private func send(dst: Data, contentType: String, body: Data, requestAck: Bool, direct: Bool) -> Data? {
        guard dst.count == 32 else { return nil }
        var id = Data(count: 32)
        let ok: Bool = dst.withUnsafeBytes { d in
            body.withUnsafeBytes { b in
                id.withUnsafeMutableBytes { out in
                    contentType.withCString { ct in
                        let dPtr = d.bindMemory(to: UInt8.self).baseAddress
                        let bPtr = b.bindMemory(to: UInt8.self).baseAddress
                        let oPtr = out.bindMemory(to: UInt8.self).baseAddress
                        return direct
                            ? hop_send_to(raw, dPtr, ct, bPtr, UInt(b.count), requestAck, oPtr)
                            : hop_send_message(raw, dPtr, ct, bPtr, UInt(b.count), requestAck, oPtr)
                    }
                }
            }
        }
        return ok ? id : nil
    }

    /// Poll durable messages without accepting them. Items repeat until `acceptInbox` succeeds.
    public func pollInbox(_ sink: (HopMessage) -> Void) {
        pollInboxAccepting { message in
            sink(message)
            return false
        }
    }

    /// Poll durable inbox items, accepting each only when `sink(message)` returns true.
    public func pollInboxAccepting(_ sink: (HopMessage) -> Bool) {
        withoutActuallyEscaping(sink) { escaping in
            var local = escaping
            withUnsafeMutablePointer(to: &local) { ctx in
                hop_poll_inbox(raw, { rawCtx, inboxId, from, ct, body, blen, hops, created in
                    let cb = rawCtx!.assumingMemoryBound(to: ((HopMessage) -> Bool).self).pointee
                    return cb(HopMessage(id: Data(bytes: inboxId!, count: 32),
                                         from: Data(bytes: from!, count: 32),
                                         contentType: ct != nil ? String(cString: ct!) : "",
                                         body: blen == 0 ? Data() : Data(bytes: body!, count: Int(blen)),
                                         hops: hops, createdAt: created))
                }, UnsafeMutableRawPointer(ctx))
            }
        }
    }

    /// Durably accept one item returned by `pollInbox`. IDs other than exactly 32 bytes are rejected.
    @discardableResult
    public func acceptInbox(_ id: Data) -> Bool {
        guard id.count == 32 else { return false }
        return id.withUnsafeBytes {
            hop_accept_inbox(raw, $0.bindMemory(to: UInt8.self).baseAddress)
        }
    }

    public func status(of id: Data) -> HopStatus {
        guard id.count == 32 else {
            return HopStatus(relayed: 0, delivered: false, forwardHops: 0, forwardMs: 0)
        }
        var relayed: UInt32 = 0, ms: UInt32 = 0
        var delivered = false
        var hops: UInt8 = 0
        _ = id.withUnsafeBytes { hop_message_status(raw, $0.bindMemory(to: UInt8.self).baseAddress, &relayed, &delivered, &hops, &ms) }
        return HopStatus(relayed: relayed, delivered: delivered, forwardHops: hops, forwardMs: ms)
    }

    public func isSecured(_ addr: Data) -> Bool {
        guard addr.count == 32 else { return false }
        return addr.withUnsafeBytes { hop_is_secured(raw, $0.bindMemory(to: UInt8.self).baseAddress) }
    }

    // MARK: persistence signals (D-wrappers / hop.h parity)

    /// False ⇒ the db path was unusable and the node is running ephemerally (state won't survive a
    /// restart); surface a warning rather than treat the db as ground truth (F-26).
    public var isPersistent: Bool { hop_node_is_persistent(raw) }

    /// How many persisted records failed to decode on startup (F-03); non-zero ⇒ state lost on upgrade.
    public var rehydrateDropped: UInt32 { hop_node_rehydrate_dropped(raw) }

    // MARK: hops:// request/response (D-wrappers)

    /// Send an hops:// service request to `dst`. Returns the request id, or nil on error.
    @discardableResult
    public func sendServiceRequest(to dst: Data, service: String, method: String, args: Data) -> Data? {
        guard dst.count == 32 else { return nil }
        var id = Data(count: 32)
        let ok: Bool = dst.withUnsafeBytes { d in
            args.withUnsafeBytes { a in
                id.withUnsafeMutableBytes { o in
                    service.withCString { s in
                        method.withCString { m in
                            hop_send_service_request(raw, d.bindMemory(to: UInt8.self).baseAddress, s, m,
                                                     a.bindMemory(to: UInt8.self).baseAddress, UInt(a.count),
                                                     o.bindMemory(to: UInt8.self).baseAddress)
                        }
                    }
                }
            }
        }
        return ok ? id : nil
    }

    /// Reply to an hops:// service request.
    @discardableResult
    public func sendServiceResponse(to: Data, forRequestId: Data, status: UInt16, body: Data) -> Bool {
        guard to.count == 32, forRequestId.count == 32 else { return false }
        return to.withUnsafeBytes { t in
            forRequestId.withUnsafeBytes { r in
                body.withUnsafeBytes { b in
                    hop_send_service_response(raw, t.bindMemory(to: UInt8.self).baseAddress,
                                              r.bindMemory(to: UInt8.self).baseAddress, status,
                                              b.bindMemory(to: UInt8.self).baseAddress, UInt(b.count))
                }
            }
        }
    }

    /// Drain inbound hops:// requests addressed to this node (acting as a service).
    public func pollServiceRequests(_ sink: (HopServiceRequest) -> Void) {
        withoutActuallyEscaping(sink) { escaping in
            var local = escaping
            withUnsafeMutablePointer(to: &local) { ctx in
                hop_poll_service_requests(raw, { rawCtx, from, reqId, service, method, args, alen in
                    let cb = rawCtx!.assumingMemoryBound(to: ((HopServiceRequest) -> Void).self).pointee
                    cb(HopServiceRequest(from: Data(bytes: from!, count: 32),
                                         requestId: Data(bytes: reqId!, count: 32),
                                         service: service != nil ? String(cString: service!) : "",
                                         method: method != nil ? String(cString: method!) : "",
                                         args: alen == 0 ? Data() : Data(bytes: args!, count: Int(alen))))
                }, UnsafeMutableRawPointer(ctx))
            }
        }
    }

    /// Poll inbound hops:// responses without accepting them.
    public func pollServiceResponses(_ sink: (HopServiceResponse) -> Void) {
        pollServiceResponsesAccepting { response in
            sink(response)
            return false
        }
    }

    /// Poll responses, accepting each only when `sink(response)` returns true synchronously.
    public func pollServiceResponsesAccepting(_ sink: (HopServiceResponse) -> Bool) {
        withoutActuallyEscaping(sink) { escaping in
            var local = escaping
            withUnsafeMutablePointer(to: &local) { ctx in
                hop_poll_service_responses(raw, { rawCtx, from, forId, status, body, blen in
                    let cb = rawCtx!.assumingMemoryBound(to: ((HopServiceResponse) -> Bool).self).pointee
                    return cb(HopServiceResponse(from: Data(bytes: from!, count: 32),
                                                 forRequestId: Data(bytes: forId!, count: 32),
                                                 status: status,
                                                 body: blen == 0 ? Data() : Data(bytes: body!, count: Int(blen))))
                }, UnsafeMutableRawPointer(ctx))
            }
        }
    }

    /// Durably accept a previously-polled response by its 32-byte correlation request id.
    @discardableResult
    public func acceptServiceResponse(forRequestId: Data) -> Bool {
        guard forRequestId.count == 32 else { return false }
        return forRequestId.withUnsafeBytes {
            hop_accept_service_response(raw, $0.bindMemory(to: UInt8.self).baseAddress)
        }
    }

    // MARK: hps:// pub/sub (DESIGN.md section 32)

    // The C ABI had NO hps exports before v6, so every wrapper sitting on it (this one, Kotlin, and
    // the React Native bridge above them) could not reach channels or group chat at all, while the
    // two native UniFFI drivers have had the surface for as long as the protocol has existed. These
    // calls close that gap, and tools/codegen/check-abi-version.sh fails if this wrapper pins the
    // level while leaving any of them unbound: a version integer confers no capability, binding does.
    //
    // Two queue shapes live here and they are NOT interchangeable. Publications are
    // accept-to-remove, the same contract as the inbox: an item repeats until `acceptHpsMessage`
    // (or a `true` from the accepting poll) succeeds, so a host that cannot persist one gets it
    // again. Invites are take-and-clear: draining one destroys it, so a host MUST persist what it
    // surfaces or the user never sees that invite again.

    /// Host a topic at `path`, minting and persisting its keys. Returns the topic's public key, or
    /// nil if registration failed.
    ///
    /// A service has a public key (only the owner broadcasts, signed by it); a channel has none,
    /// because its writers sign with their own identities. So EMPTY data is the correct, successful
    /// answer for a channel and is deliberately not collapsed into nil: the C call reports success
    /// through its bool and the length separately for exactly that reason, and a wrapper that folded
    /// the two together would report every channel it just created as a failure.
    @discardableResult
    public func hpsRegister(path: String, kind: HpsKind, access: HpsAccess, visibility: HpsVisibility) -> Data? {
        var key = Data(count: 32)
        var keyLen: UInt = 0
        let ok: Bool = path.withCString { p in
            key.withUnsafeMutableBytes { k in
                hop_hps_register(raw, p, kind.rawValue, access.rawValue, visibility.rawValue,
                                 k.bindMemory(to: UInt8.self).baseAddress, UInt(k.count), &keyLen)
            }
        }
        return ok ? key.prefix(Int(keyLen)) : nil
    }

    /// Subscribe to `hps://{host}/{path}`: seal a keys request to `host`, which an open topic
    /// answers with the keys, a request-to-join topic queues for approval, and an invite-only topic
    /// ignores. Returns the subscribe bundle id, or nil.
    @discardableResult
    public func hpsSubscribe(host: Data, path: String) -> Data? {
        guard host.count == 32 else { return nil }
        var id = Data(count: 32)
        let ok: Bool = host.withUnsafeBytes { h in
            id.withUnsafeMutableBytes { o in
                path.withCString { p in
                    hop_hps_subscribe(raw, h.bindMemory(to: UInt8.self).baseAddress, p,
                                      o.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        return ok ? id : nil
    }

    /// Publish to a topic we host or (for a channel) belong to: encrypted once to the content key,
    /// signed by the service key for a service or by our own identity for a channel, flooded once.
    /// Returns the bundle id, or nil for an unknown path or no write access.
    @discardableResult
    public func hpsPublish(path: String, body: Data) -> Data? {
        var id = Data(count: 32)
        let ok: Bool = body.withUnsafeBytes { b in
            id.withUnsafeMutableBytes { o in
                path.withCString { p in
                    hop_hps_publish(raw, p, b.bindMemory(to: UInt8.self).baseAddress, UInt(b.count),
                                    o.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        return ok ? id : nil
    }

    /// Poll received publications without accepting them. Items repeat until acceptance succeeds.
    public func pollHpsMessages(_ sink: (HopHpsMessage) -> Void) {
        pollHpsMessagesAccepting { message in
            sink(message)
            return false
        }
    }

    /// Poll received publications, accepting each only when `sink(message)` returns true. Returning
    /// true IS the durable acceptance, so a host that persists inside the sink never loses a row to
    /// a crash between the poll and a separate accept.
    public func pollHpsMessagesAccepting(_ sink: (HopHpsMessage) -> Bool) {
        withoutActuallyEscaping(sink) { escaping in
            var local = escaping
            withUnsafeMutablePointer(to: &local) { ctx in
                hop_poll_hps_messages(raw, { rawCtx, id, path, sender, body, blen in
                    let cb = rawCtx!.assumingMemoryBound(to: ((HopHpsMessage) -> Bool).self).pointee
                    return cb(HopHpsMessage(id: Data(bytes: id!, count: 32),
                                            path: path != nil ? String(cString: path!) : "",
                                            sender: Data(bytes: sender!, count: 32),
                                            body: blen == 0 ? Data() : Data(bytes: body!, count: Int(blen))))
                }, UnsafeMutableRawPointer(ctx))
            }
        }
    }

    /// Durably accept one publication returned by `pollHpsMessages`, by its 32-byte id.
    @discardableResult
    public func acceptHpsMessage(_ id: Data) -> Bool {
        guard id.count == 32 else { return false }
        return id.withUnsafeBytes {
            hop_accept_hps_message(raw, $0.bindMemory(to: UInt8.self).baseAddress)
        }
    }

    /// Host to destination: invite `dest` to a topic we host. Keys are sealed only once the
    /// destination accepts, so an invite hands out nothing by itself. Returns the invite bundle id.
    @discardableResult
    public func hpsInvite(path: String, dest: Data) -> Data? {
        guard dest.count == 32 else { return nil }
        var id = Data(count: 32)
        let ok: Bool = dest.withUnsafeBytes { d in
            id.withUnsafeMutableBytes { o in
                path.withCString { p in
                    hop_hps_invite(raw, p, d.bindMemory(to: UInt8.self).baseAddress,
                                   o.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        return ok ? id : nil
    }

    /// Member to host: accept an invite we received, after which the host seals us the keys.
    @discardableResult
    public func hpsAcceptInvite(host: Data, path: String) -> Data? {
        guard host.count == 32 else { return nil }
        var id = Data(count: 32)
        let ok: Bool = host.withUnsafeBytes { h in
            id.withUnsafeMutableBytes { o in
                path.withCString { p in
                    hop_hps_accept_invite(raw, h.bindMemory(to: UInt8.self).baseAddress, p,
                                          o.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        return ok ? id : nil
    }

    /// Decline a received invite. DURABLE: the invite is dropped from storage, so it does not
    /// reappear after a restart.
    @discardableResult
    public func hpsDeclineInvite(host: Data, path: String) -> Bool {
        guard host.count == 32 else { return false }
        return host.withUnsafeBytes { h in
            path.withCString { p in
                hop_hps_decline_invite(raw, h.bindMemory(to: UInt8.self).baseAddress, p)
            }
        }
    }

    /// Drain received invites, CLEARING them. This is take-and-clear, not accept-to-remove: an
    /// invite the host does not persist here is gone, so write it down inside the sink.
    public func pollHpsInvites(_ sink: (HopHpsInvite) -> Void) {
        withoutActuallyEscaping(sink) { escaping in
            var local = escaping
            withUnsafeMutablePointer(to: &local) { ctx in
                hop_poll_hps_invites(raw, { rawCtx, host, path, kind in
                    let cb = rawCtx!.assumingMemoryBound(to: ((HopHpsInvite) -> Void).self).pointee
                    // Decoding a discriminant the LIBRARY produced, for display of a topic we already
                    // hold: an unknown value can only mean a newer core, so falling back keeps the row
                    // visible. On the way IN an unknown value must FAIL instead, because reading a
                    // garbage int as an open access mode would hand a topic's keys to anyone asking.
                    cb(HopHpsInvite(host: Data(bytes: host!, count: 32),
                                    path: path != nil ? String(cString: path!) : "",
                                    kind: HpsKind(rawValue: kind) ?? .channel))
                }, UnsafeMutableRawPointer(ctx))
            }
        }
    }

    /// Leave a topic, so its host stops re-keying us on rotation.
    ///
    /// `(ok: true, id: nil)` is a SUCCESS: leaving a topic we host sends no bundle, so there is no
    /// id to report. Only `ok == false` is a failure, which is why the id is not the return value.
    @discardableResult
    public func hpsLeave(path: String) -> (ok: Bool, id: Data?) {
        var id = Data(count: 32)
        var hasId = false
        let ok: Bool = id.withUnsafeMutableBytes { o in
            path.withCString { p in
                hop_hps_leave(raw, p, o.bindMemory(to: UInt8.self).baseAddress, &hasId)
            }
        }
        return (ok, (ok && hasId) ? id : nil)
    }

    /// Host: the join requests queued on a request-to-join topic, each a requester address.
    public func hpsPending(path: String) -> [Data] {
        addressList(path: path) { node, p, sink, ctx in hop_hps_pending(node, p, sink, ctx) }
    }

    /// Host: approve a pending requester, sealing them the topic keys. Returns the keys bundle id.
    @discardableResult
    public func hpsApprove(path: String, requester: Data) -> Data? {
        guard requester.count == 32 else { return nil }
        var id = Data(count: 32)
        let ok: Bool = requester.withUnsafeBytes { r in
            id.withUnsafeMutableBytes { o in
                path.withCString { p in
                    hop_hps_approve(raw, p, r.bindMemory(to: UInt8.self).baseAddress,
                                    o.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        return ok ? id : nil
    }

    /// Host: deny a pending requester and drop the request. No keys are sealed.
    @discardableResult
    public func hpsDeny(path: String, requester: Data) -> Bool {
        guard requester.count == 32 else { return false }
        return requester.withUnsafeBytes { r in
            path.withCString { p in
                hop_hps_deny(raw, p, r.bindMemory(to: UInt8.self).baseAddress)
            }
        }
    }

    /// Host: forward rotation, which is how a member is REVOKED. Mints a new content key and seals
    /// it to every retained member except `remove`; a removed member keeps only the dead key, so it
    /// can still read the history it already holds and nothing published afterwards. An empty
    /// `newPath` keeps the path; a non-empty one moves the topic. Returns the rekey bundle ids.
    @discardableResult
    public func hpsRekey(path: String, newPath: String = "", remove: [Data] = []) -> [Data] {
        // The C call takes a COUNT and reads count * 32 bytes from one contiguous buffer, so pack the
        // removals back to back. A mis-sized entry is DROPPED rather than padded or sent as-is:
        // a short address would slide every later one and revoke a member nobody named.
        var packed = Data()
        for addr in remove where addr.count == 32 { packed.append(addr) }
        var ids: [Data] = []
        withoutActuallyEscaping({ (id: Data) in ids.append(id) }) { escaping in
            var local = escaping
            withUnsafeMutablePointer(to: &local) { ctx in
                _ = path.withCString { p in
                    newPath.withCString { np in
                        packed.withUnsafeBytes { r in
                            hop_hps_rekey(raw, p, np, r.bindMemory(to: UInt8.self).baseAddress,
                                          UInt(r.count / 32), { rawCtx, id in
                                guard let id else { return }
                                rawCtx!.assumingMemoryBound(to: ((Data) -> Void).self)
                                    .pointee(Data(bytes: id, count: 32))
                            }, UnsafeMutableRawPointer(ctx))
                        }
                    }
                }
            }
        }
        return ids
    }

    /// Host: a topic's reach, the count of distinct addresses that have acked a publication on it.
    /// A flood has no per-recipient receipt, so this is the only delivery sense a UI can honestly
    /// show for a topic.
    public func hpsReach(path: String) -> UInt32 { path.withCString { hop_hps_reach(raw, $0) } }

    /// Host: the retained-member set for a topic, which is who the next rotation re-keys.
    public func hpsMembers(path: String) -> [Data] {
        addressList(path: path) { node, p, sink, ctx in hop_hps_members(node, p, sink, ctx) }
    }

    /// Every topic this node hosts or follows, so an app can rebuild its channel list after a
    /// restart: the node persists topics, an in-memory list does not.
    public func hpsMyTopics() -> [HopHpsTopic] {
        var topics: [HopHpsTopic] = []
        withoutActuallyEscaping({ (topic: HopHpsTopic) in topics.append(topic) }) { escaping in
            var local = escaping
            withUnsafeMutablePointer(to: &local) { ctx in
                _ = hop_hps_my_topics(raw, { rawCtx, host, path, kind, hosting, access in
                    // Discriminants the LIBRARY produced, for topics this node already holds keys to,
                    // so an unrecognized value means a newer core and the fallback only affects how the
                    // row reads. An inbound access mode gets no such default: defaulting there would
                    // turn a garbage int into "hand the keys to anyone who asks".
                    rawCtx!.assumingMemoryBound(to: ((HopHpsTopic) -> Void).self).pointee(
                        HopHpsTopic(host: Data(bytes: host!, count: 32),
                                    path: path != nil ? String(cString: path!) : "",
                                    kind: HpsKind(rawValue: kind) ?? .channel,
                                    hosting: hosting,
                                    access: HpsAccess(rawValue: access) ?? .open))
                }, UnsafeMutableRawPointer(ctx))
            }
        }
        return topics
    }

    /// Discoverable topics seen on the mesh: descriptors a discoverable host broadcasts, decrypted
    /// with the app secret, so this only ever surfaces topics from the same app fabric.
    public func hpsBrowse() -> [HopHpsTopicInfo] {
        var found: [HopHpsTopicInfo] = []
        withoutActuallyEscaping({ (info: HopHpsTopicInfo) in found.append(info) }) { escaping in
            var local = escaping
            withUnsafeMutablePointer(to: &local) { ctx in
                _ = hop_hps_browse(raw, { rawCtx, host, path, kind, title, summary, access in
                    // Same reasoning as hpsMyTopics: these discriminants came OUT of the library, and
                    // the access mode shown here is a label on a browse row, never a decision to admit
                    // anyone. The host's own access check is what actually gates the key handoff.
                    rawCtx!.assumingMemoryBound(to: ((HopHpsTopicInfo) -> Void).self).pointee(
                        HopHpsTopicInfo(host: Data(bytes: host!, count: 32),
                                        path: path != nil ? String(cString: path!) : "",
                                        kind: HpsKind(rawValue: kind) ?? .channel,
                                        title: title != nil ? String(cString: title!) : "",
                                        summary: summary != nil ? String(cString: summary!) : "",
                                        access: HpsAccess(rawValue: access) ?? .open))
                }, UnsafeMutableRawPointer(ctx))
            }
        }
        return found
    }

    /// Shared plumbing for the two address-set reads (`hpsPending` and `hpsMembers`): both are
    /// `count = call(node, path, sink(ctx, addr32), ctx)`, so the trampoline is written once instead
    /// of twice. The returned count is redundant with the array built here and is discarded; the C
    /// side also accepts a NULL sink to count without collecting, which neither caller wants.
    private func addressList(
        path: String,
        _ call: (OpaquePointer,
                 UnsafePointer<CChar>,
                 @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?) -> Void,
                 UnsafeMutableRawPointer) -> UInt
    ) -> [Data] {
        var addresses: [Data] = []
        withoutActuallyEscaping({ (addr: Data) in addresses.append(addr) }) { escaping in
            var local = escaping
            withUnsafeMutablePointer(to: &local) { ctx in
                _ = path.withCString { p in
                    call(raw, p, { rawCtx, addr in
                        guard let addr else { return }
                        rawCtx!.assumingMemoryBound(to: ((Data) -> Void).self)
                            .pointee(Data(bytes: addr, count: 32))
                    }, UnsafeMutableRawPointer(ctx))
                }
            }
        }
        return addresses
    }
}

// MARK: - address base58 helpers

public enum HopAddress {
    public static func base58(_ addr: Data) -> String {
        guard addr.count == 32 else { return "" }
        var buf = [CChar](repeating: 0, count: 64)
        let n = addr.withUnsafeBytes { hop_address_to_base58($0.bindMemory(to: UInt8.self).baseAddress, &buf, UInt(buf.count)) }
        return n > 0 ? String(cString: buf) : ""
    }

    public static func fromBase58(_ text: String) -> Data? {
        var out = Data(count: 32)
        let ok = out.withUnsafeMutableBytes { o in
            text.withCString { hop_address_from_base58($0, o.bindMemory(to: UInt8.self).baseAddress) }
        }
        return ok ? out : nil
    }
}
