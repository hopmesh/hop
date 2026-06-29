// Hop — the thin idiomatic Swift wrapper over libhop's C ABI (CHop / hop.h).
//
// Every method is a direct, type-safe shim over a `hop_*` C call; the cross-language contract lives
// in the generated header, so this layer can't diverge from it semantically — it only adds Swift
// ergonomics (Data, String, closures, an owning class). Bearers and apps use THIS, never raw C.

import CHop
import Foundation

/// Which side opened a bearer link (the Noise role).
public enum HopRole {
    case dialer    // we dialed out → Noise initiator
    case acceptor  // a peer connected in → Noise responder

    fileprivate var c: HopLinkRole { self == .dialer ? HopLinkRole_Dialer : HopLinkRole_Acceptor }
}

/// A decrypted message delivered to this node.
public struct HopMessage {
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

/// A running Hop node. Owns the underlying `libhop` handle; thread-safe inside (interior mutex).
public final class HopNode {
    private let raw: OpaquePointer   // const HopNode* from libhop

    private init(raw: OpaquePointer) { self.raw = raw }

    /// A fresh identity with ephemeral (in-memory) storage.
    public static func ephemeral() -> HopNode { HopNode(raw: hop_node_new()) }

    /// Restore from a saved 32-byte identity `secret` (empty = fresh) with ephemeral storage.
    public static func with(secret: Data) -> HopNode {
        HopNode(raw: secret.withUnsafeBytes { hop_node_with_secret($0.bindMemory(to: UInt8.self).baseAddress, UInt($0.count)) })
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

    public func linkUp(_ link: UInt64, role: HopRole) { hop_link_up(raw, link, role.c) }
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

    /// Drain newly-received messages; `sink(message)` is called once per message, synchronously.
    public func pollInbox(_ sink: (HopMessage) -> Void) {
        withoutActuallyEscaping(sink) { escaping in
            var local = escaping
            withUnsafeMutablePointer(to: &local) { ctx in
                hop_poll_inbox(raw, { rawCtx, from, ct, body, blen, hops, created in
                    let cb = rawCtx!.assumingMemoryBound(to: ((HopMessage) -> Void).self).pointee
                    cb(HopMessage(from: Data(bytes: from!, count: 32),
                                  contentType: ct != nil ? String(cString: ct!) : "",
                                  body: blen == 0 ? Data() : Data(bytes: body!, count: Int(blen)),
                                  hops: hops, createdAt: created))
                }, UnsafeMutableRawPointer(ctx))
            }
        }
    }

    public func status(of id: Data) -> HopStatus {
        var relayed: UInt32 = 0, ms: UInt32 = 0
        var delivered = false
        var hops: UInt8 = 0
        _ = id.withUnsafeBytes { hop_message_status(raw, $0.bindMemory(to: UInt8.self).baseAddress, &relayed, &delivered, &hops, &ms) }
        return HopStatus(relayed: relayed, delivered: delivered, forwardHops: hops, forwardMs: ms)
    }

    public func isSecured(_ addr: Data) -> Bool {
        addr.withUnsafeBytes { hop_is_secured(raw, $0.bindMemory(to: UInt8.self).baseAddress) }
    }
}

// MARK: - address base58 helpers

public enum HopAddress {
    public static func base58(_ addr: Data) -> String {
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
