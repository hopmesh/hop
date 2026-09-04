import Foundation
import XCTest
import HopContract
@testable import HopBearerMeshtastic

/// A fake Meshtastic radio: records every ToRadio the bearer writes and lets a test push connect /
/// disconnect / FromRadio events straight into the bearer's callbacks. No CoreBluetooth, no hardware.
final class FakeRadio: MeshtasticRadio {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onFromRadio: (([UInt8]) -> Void)?

    private(set) var sent = [[UInt8]]()
    private(set) var started = false
    private(set) var stopped = false

    func start() { started = true }
    func stop() { stopped = true }
    func send(toRadio bytes: [UInt8]) { sent.append(bytes) }

    // Test drivers.
    func fireConnect() { onConnect?() }
    func fireDisconnect() { onDisconnect?() }
    func deliver(fromRadio bytes: [UInt8]) { onFromRadio?(bytes) }

    /// Deliver a FromRadio carrying MyNodeInfo{my_node_num}.
    func deliverMyNodeNum(_ num: UInt32) {
        var w = ProtoWriter()
        var info = ProtoWriter(); info.varintField(1, UInt64(num))
        w.bytesField(3, info.bytes)   // FromRadio.my_info
        deliver(fromRadio: w.bytes)
    }

    /// Deliver a FromRadio carrying a MeshPacket on the Hop port from `node` with `payload`.
    func deliverHopPacket(from node: UInt32, payload: [UInt8]) {
        var pkt = ProtoWriter()
        pkt.fixed32Field(1, node)                                   // from
        pkt.bytesField(4, MeshtasticProto.encodeData(payload: payload))  // decoded (Data)
        var w = ProtoWriter()
        w.bytesField(2, pkt.bytes)    // FromRadio.packet
        deliver(fromRadio: w.bytes)
    }

    /// Deliver a FromRadio carrying an ADMIN_APP MeshPacket (channel get/set).
    func deliverAdmin(from node: UInt32, payload: [UInt8]) {
        var pkt = ProtoWriter()
        pkt.fixed32Field(1, node)
        pkt.bytesField(4, MeshtasticProto.encodeData(payload: payload, portnum: MESH_ADMIN_PORTNUM))
        var w = ProtoWriter()
        w.bytesField(2, pkt.bytes)
        deliver(fromRadio: w.bytes)
    }

    /// A get_channel_response for a DISABLED slot, so the bearer can arm Hop's SECONDARY.
    func deliverFreeHopSlot(index: Int = 1, passkey: [UInt8] = [9, 9, 9, 9]) {
        deliverAdmin(
            from: 0,
            payload: MeshtasticProto.encodeGetChannelResponse(
                passkey: passkey, index: index, name: "", psk: [], role: MESH_CHANNEL_ROLE_DISABLED))
    }

    /// Reset the recorded ToRadio log (so a test can assert only what happened after a point).
    func clearSent() { sent.removeAll() }
}

/// Records the link events the BearerManager sink would see.
final class RecordingSink: LinkSink {
    struct Up: Equatable { let link: LinkId; let dialer: Bool; let peer: Data }
    private(set) var ups = [Up]()
    private(set) var bytesEvents = [(link: LinkId, data: Data)]()
    private(set) var downs = [LinkId]()

    func linkUp(_ link: LinkId, role: HopRole, peerId: Data) {
        ups.append(Up(link: link, dialer: role == .dialer, peer: peerId))
    }
    func linkBytes(_ link: LinkId, _ bytes: Data) { bytesEvents.append((link, bytes)) }
    func linkDown(_ link: LinkId) { downs.append(link) }
}

enum MeshTestDecode {

    /// Unwrap a ToRadio admin packet's AdminMessage payload, or nil if it is not ADMIN_APP.
    static func toRadioAdmin(_ bytes: [UInt8]) -> [UInt8]? {
        var r = ProtoReader(bytes)
        guard let (field, wire) = r.readTag(), field == 1, wire == 2, let pkt = r.readBytes() else { return nil }
        var pr = ProtoReader(pkt)
        var data: [UInt8]?
        while let (f, w) = pr.readTag() {
            if f == 4, w == 2 { data = pr.readBytes() }
            else { _ = pr.skip(w) }
        }
        guard let d = data, let (port, payload) = MeshtasticProto.decodeData(d),
              port == MESH_ADMIN_PORTNUM else { return nil }
        return payload
    }

    /// MeshPacket.channel on a ToRadio packet, 0 if omitted (PRIMARY).
    static func packetChannel(_ bytes: [UInt8]) -> UInt32 {
        var r = ProtoReader(bytes)
        guard let (field, wire) = r.readTag(), field == 1, wire == 2, let pkt = r.readBytes() else { return 0 }
        var pr = ProtoReader(pkt)
        while let (f, w) = pr.readTag() {
            if f == 3, w == 0 { return UInt32(truncatingIfNeeded: pr.readVarint() ?? 0) }
            _ = pr.skip(w)
        }
        return 0
    }
    /// Extract (to, fragment payload) from a ToRadio the bearer wrote, or nil if it is not a packet
    /// (e.g. a want_config ToRadio). Mirrors the encoder in MeshtasticProto.encodeToRadioPacket.
    static func toRadioFragment(_ bytes: [UInt8]) -> (to: UInt32, fragment: [UInt8])? {
        var r = ProtoReader(bytes)
        guard let (field, wire) = r.readTag(), field == 1, wire == 2, let pkt = r.readBytes() else { return nil }
        var pr = ProtoReader(pkt)
        var to: UInt32 = 0
        var data: [UInt8]?
        while let (f, w) = pr.readTag() {
            switch (f, w) {
            case (2, 5): to = pr.readFixed32() ?? 0
            case (4, 2): data = pr.readBytes()
            default: _ = pr.skip(w)
            }
        }
        guard let d = data, let payload = MeshtasticProto.decodeHopData(d) else { return nil }
        return (to, payload)
    }

    /// Every complete Hop link frame the bearer transmitted, grouped by (destination, msgId) and
    /// reassembled. want_config frames (no packet) are skipped. Lets a test assert on frame type + body
    /// and destination without caring how many fragments carried it.
    static func allFrames(_ sends: [[UInt8]]) -> [(to: UInt32, body: [UInt8])] {
        struct Partial { var count: Int; var chunks: [Int: [UInt8]]; var to: UInt32 }
        var partial = [String: Partial]()
        var out = [(to: UInt32, body: [UInt8])]()
        for s in sends {
            guard let (to, frag) = toRadioFragment(s), let h = MeshFragHeader(frag) else { continue }
            let key = "\(to)-\(h.msgId)"
            var p = partial[key] ?? Partial(count: h.count, chunks: [:], to: to)
            p.chunks[h.index] = h.chunk
            partial[key] = p
            if p.chunks.count == p.count {
                var body = [UInt8]()
                for i in 0..<p.count { body.append(contentsOf: p.chunks[i] ?? []) }
                out.append((to, body))
                partial[key] = nil
            }
        }
        return out
    }

    /// The first complete frame sent to `dest`, or nil.
    static func frame(to dest: UInt32, in sends: [[UInt8]]) -> [UInt8]? {
        allFrames(sends).first(where: { $0.to == dest })?.body
    }
}
