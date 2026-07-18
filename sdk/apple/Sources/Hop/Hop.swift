// Hop — the thin idiomatic Swift wrapper over libhop's C ABI (CHop / hop.h).
//
// Every method is a direct, type-safe shim over a `hop_*` C call; the cross-language contract lives
// in the generated header, so this layer can't diverge from it semantically — it only adds Swift
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

/// A running Hop node. Owns the underlying `libhop` handle; thread-safe inside (interior mutex).
public final class HopNode {
    /// Expected libhop ABI version (mirrors HOP_ABI_VERSION in hop.h). Asserted once on first use so a
    /// wrapper built against a newer header fails loudly instead of drifting (F-28).
    public static let expectedABIVersion: UInt32 = 4
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

    /// This node's 32-byte identity secret — persist it to restore the node later.
    public var secret: Data {
        var out = Data(count: 32)
        let n = out.withUnsafeMutableBytes { hop_node_secret(raw, $0.bindMemory(to: UInt8.self).baseAddress) }
        return out.prefix(Int(n))
    }

    public func setName(_ name: String) { name.withCString { hop_node_set_name(raw, $0) } }

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
