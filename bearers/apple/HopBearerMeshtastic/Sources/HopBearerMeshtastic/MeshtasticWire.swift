// MeshtasticWire, the Meshtastic bearer's PURE, radio-free wire logic, split out so it is unit-testable
// on a headless macOS `swift test` with no CoreBluetooth peer and no Meshtastic hardware (the same
// discipline LanWire / CentralCore follow). Everything here is value math: the minimal Meshtastic
// protobuf codec, the fragment/reassembly layer that carries a Hop link frame across many tiny LoRa
// packets, the Hop link-frame grammar (byte-identical to the LAN/BLE bearers), and the one-pipe-per-peer
// dedup keep-rule. MeshtasticBearer.swift (link state) and MeshtasticBearer+Radio.swift (the real GATT
// connection to a Meshtastic radio) build on top of it and are EXCLUDED from the coverage denominator,
// exactly like every other bearer's radio glue.
//
// WHY A SEPARATE TRANSPORT SHAPE. LAN/BLE are byte-stream links: a 4-byte length prefix deframes a
// stream. Meshtastic is the opposite: a datagram mesh of ~200-byte LoRa packets, lossy and airtime
// limited, that RELAYS each packet hop-by-hop across every radio in range. So a Hop link frame (a HELLO,
// or a DATA carrying a sealed Hop record) does not fit one packet and must be FRAGMENTED into
// MESH_MAX_CHUNK-sized pieces, each shipped as one Meshtastic `MeshPacket` on a private app port, and
// REASSEMBLED on the far side keyed by (sender node, message id). The delay-tolerant, store-and-forward
// nature of the mesh is a natural fit for Hop, which is itself delay-tolerant by design.
//
// Hop link-frame grammar (the SAME 1-byte type tags the LAN bearer uses, so the consumer sees identical
// linkUp/linkBytes/linkDown semantics regardless of radio):
//   HELLO 0x01 : [16B nodeId][1B role][1B flags]   role 1 = the greater-id side (the Noise initiator)
//   PING  0x02 : [8B seq][8B nowMs]                 keepalive; never surfaced to the consumer
//   PONG  0x03 : echoes the peer's PING body prefix
//   DATA  0x10 : the consumer's application bytes (a sealed Hop record)
//
// The fragment header prepended to each Meshtastic payload is 4 bytes:
//   [msgId hi][msgId lo][fragIndex][fragCount]      then up to MESH_MAX_CHUNK bytes of the frame body
//
// These constants are a POLICY the bearer implements on BOTH platforms, so per bearers/CLAUDE.md they
// are pinned in `bearers/meshtastic-vectors.json` and asserted by `tools/meshtastic-parity.sh`. Keep the
// two in lockstep; the guard fails CI if Apple and Android drift.

import Foundation
import HopContract   // the bearer contract (no libhop): log/hex/nodeIdGreater helpers

// MARK: - Pinned cross-platform constants (see bearers/meshtastic-vectors.json) --------------------------

/// Meshtastic `PortNum` for Hop traffic. PRIVATE_APP is 256; Hop rides a fixed offset inside the private
/// range (256..511) so it never collides with a first-party Meshtastic app. Hop packets go on a
/// SECONDARY channel the bearer writes (see MESH_HOP_CHANNEL_*), not on PRIMARY.
let MESH_HOP_PORTNUM: UInt32 = 260

/// Meshtastic `PortNum.ADMIN_APP`. Channel get/set rides this, never the Hop port.
let MESH_ADMIN_PORTNUM: UInt32 = 6

/// Meshtastic `PortNum.ROUTING_APP`. Unicast fragments set want_ack; NONE on this port is the radio ACK.
let MESH_ROUTING_PORTNUM: UInt32 = 5

/// Spray unacked unicast DATA/HELLO. Seconds on Apple, milliseconds on Android; parity scales.
let MESH_SPRAY_INITIAL_S: Double = 2.0
let MESH_SPRAY_MULTIPLIER = 2
let MESH_SPRAY_CAP_S: Double = 60.0
let MESH_SPRAY_TICK_S: Double = 1.0
let MESH_SPRAY_MAX_OUTSTANDING = 8

/// SECONDARY slot name Hop writes. Primary (index 0) is left to Meshtastic.app.
let MESH_HOP_CHANNEL_NAME = "Hop"

/// AES-128 PSK, hex 686f702e6d6573682e70736b2e763121 ("hop.mesh.psk.v1!"). Shared by every Hop node.
let MESH_HOP_CHANNEL_PSK_HEX = "686f702e6d6573682e70736b2e763121"
let MESH_HOP_CHANNEL_PSK: [UInt8] = [
    0x68, 0x6f, 0x70, 0x2e, 0x6d, 0x65, 0x73, 0x68,
    0x2e, 0x70, 0x73, 0x6b, 0x2e, 0x76, 0x31, 0x21,
]

/// ChannelSettings.id; ASCII 'HOP1' as 0x484F5031.
let MESH_HOP_CHANNEL_ID: UInt32 = 0x484F5031

let MESH_CHANNEL_ROLE_DISABLED = 0
let MESH_CHANNEL_ROLE_SECONDARY = 2

/// Meshtastic MAX_NUM_CHANNELS. Index 0 is PRIMARY; Hop probes 1..7.
let MESH_MAX_CHANNELS = 8

/// The Meshtastic broadcast node address (0xffffffff). HELLO and PING go to the broadcast address so a
/// peer is discovered without knowing its node num first; DATA and PONG unicast back to the sender.
let MESH_BROADCAST_ADDR: UInt32 = 0xffff_ffff

/// LoRa airtime is scarce, so a Hop record is chunked into at most this many bytes per Meshtastic packet.
/// A Meshtastic `Data.payload` tops out near 237 bytes; 200 leaves headroom for the 4-byte fragment
/// header plus the surrounding protobuf field tags without ever overflowing a single frame.
let MESH_MAX_CHUNK = 200

/// The fixed fragment header size: [msgId:2][fragIndex:1][fragCount:1].
let MESH_FRAG_HEADER = 4

/// A frame body is split across at most 255 fragments (fragCount is one byte), which with MESH_MAX_CHUNK
/// bounds a single reassembled frame at 255 * 200 = 51000 bytes. Larger link frames are refused outright
/// (they would never survive a lossy LoRa mesh anyway).
let MESH_MAX_FRAGS = 255
let MESH_MAX_MESSAGE = MESH_MAX_FRAGS * MESH_MAX_CHUNK

/// Liveness. LoRa is slow and duty-cycle limited, so the keepalive is far lazier than the LAN bearer's
/// 1 Hz: PING every 30 s, declare a peer dead after 180 s of silence. Delay-tolerant by construction.
let MESH_PING_S: Double = 30.0
let MESH_DEAD_S: Double = 180.0

/// A half-assembled inbound message is dropped after this long, so a peer that sends 3 of 5 fragments and
/// vanishes cannot pin reassembly memory forever. Also bounds concurrent partial messages per peer.
let MESH_REASSEMBLY_TTL_S: Double = 120.0
let MESH_MAX_PARTIAL_PER_PEER = 8

// Hop link-frame type tags (hello/ping/pong/data identical to LAN). ack is Meshtastic-bearer-only.
let M_HELLO: UInt8 = 0x01
let M_PING: UInt8 = 0x02
let M_PONG: UInt8 = 0x03
let M_ACK: UInt8 = 0x04
let M_DATA: UInt8 = 0x10

// MARK: - Minimal protobuf codec (only the Meshtastic messages the bearer needs) ------------------------

/// A tiny protobuf writer: just varint, fixed32, and length-delimited fields. Meshtastic messages are
/// small and their field numbers are stable, so hand-encoding the exact subset the bearer needs is far
/// lighter than pulling the full generated SDK, and it is FULLY unit-testable byte for byte.
struct ProtoWriter {
    private(set) var bytes = [UInt8]()

    mutating func varintField(_ field: Int, _ value: UInt64) {
        tag(field, 0)
        varint(value)
    }

    mutating func fixed32Field(_ field: Int, _ value: UInt32) {
        tag(field, 5)
        for i in 0..<4 { bytes.append(UInt8((value >> (8 * UInt32(i))) & 0xff)) }   // little-endian
    }

    mutating func bytesField(_ field: Int, _ value: [UInt8]) {
        tag(field, 2)
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    private mutating func tag(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }

    private mutating func varint(_ v: UInt64) {
        var value = v
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
    }
}

/// A tiny protobuf reader over a byte slice. Every read is bounds-checked and returns nil on a malformed
/// buffer, so a hostile radio frame can never index out of range. It skips fields the bearer does not
/// care about by wire type.
struct ProtoReader {
    private let buf: [UInt8]
    private var i = 0

    init(_ bytes: [UInt8]) { self.buf = bytes }

    var atEnd: Bool { i >= buf.count }

    /// Read the next field's (fieldNumber, wireType), or nil at end / on a truncated tag.
    mutating func readTag() -> (field: Int, wire: Int)? {
        guard let t = readVarint() else { return nil }
        return (Int(t >> 3), Int(t & 0x7))
    }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < buf.count {
            let byte = buf[i]; i += 1
            if shift > 63 { return nil }                       // overlong varint, refuse
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil                                             // ran off the end mid-varint
    }

    mutating func readFixed32() -> UInt32? {
        guard i + 4 <= buf.count else { return nil }
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(buf[i + k]) << (8 * UInt32(k)) }
        i += 4
        return v
    }

    mutating func readBytes() -> [UInt8]? {
        guard let len = readVarint(), i + Int(len) <= buf.count else { return nil }
        let out = Array(buf[i..<i + Int(len)])
        i += Int(len)
        return out
    }

    /// Skip a field of the given wire type (used for fields the bearer ignores). Returns false if the
    /// buffer is malformed. Wire type 1 (64-bit) and 5 (32-bit) are fixed widths; 0 is a varint; 2 is
    /// length-delimited. Groups (3/4) are obsolete and treated as malformed.
    mutating func skip(_ wire: Int) -> Bool {
        switch wire {
        case 0: return readVarint() != nil
        case 1: guard i + 8 <= buf.count else { return false }; i += 8; return true
        case 2: return readBytes() != nil
        case 5: return readFixed32() != nil
        default: return false
        }
    }
}

// MARK: - Meshtastic messages (the exact subset the bearer speaks) --------------------------------------

/// The inbound Meshtastic payload the bearer cares about after decoding one `FromRadio`: our node
/// number, a Hop-port data packet, or an ADMIN_APP payload (channel get/set).
enum MeshInbound: Equatable {
    case myNodeNum(UInt32)
    case hopData(from: UInt32, payload: [UInt8])
    case admin(payload: [UInt8])
    case routing(requestId: UInt32, error: Int)
}

/// One Meshtastic Channel (index + settings + role) from a get_channel_response.
struct MeshChannel: Equatable {
    let index: Int
    let name: String
    let psk: [UInt8]
    let role: Int
    var isHop: Bool { name == MESH_HOP_CHANNEL_NAME && psk == MESH_HOP_CHANNEL_PSK }
    var isFree: Bool { role == MESH_CHANNEL_ROLE_DISABLED }
}

/// Decoded AdminMessage: the session passkey plus an optional Channel from get_channel_response.
struct AdminInbound: Equatable {
    let passkey: [UInt8]
    let channel: MeshChannel?
}

enum MeshtasticProto {
    // Field numbers from the stable Meshtastic mesh.proto. Wire types matter: from/to/id are `fixed32`,
    // portnum/channel/hop_limit are varints, decoded/payload are length-delimited.
    //   Data:          portnum=1 (varint), payload=2 (bytes)
    //   MeshPacket:    from=1 (fixed32), to=2 (fixed32), channel=3 (varint), decoded=4 (Data),
    //                  id=6 (fixed32), hop_limit=9 (varint), want_ack=10 (varint/bool)
    //   ToRadio:       packet=1 (MeshPacket), want_config_id=3 (varint)
    //   FromRadio:     packet=2 (MeshPacket), my_info=3 (MyNodeInfo)
    //   MyNodeInfo:    my_node_num=1 (varint)
    //   Channel:       index=1 (varint), settings=2 (ChannelSettings), role=3 (varint)
    //   ChannelSettings: psk=2 (bytes), name=3 (string), id=4 (fixed32)
    //   AdminMessage:  get_channel_request=1 (uint32, index+1), get_channel_response=2 (Channel),
    //                  set_channel=33 (Channel), session_passkey=101 (bytes)

    /// Encode a Meshtastic `Data` submessage. Defaults to the Hop port.
    static func encodeData(payload: [UInt8], portnum: UInt32 = MESH_HOP_PORTNUM) -> [UInt8] {
        var w = ProtoWriter()
        w.varintField(1, UInt64(portnum))
        w.bytesField(2, payload)
        return w.bytes
    }

    static func encodeToRadioPacket(from: UInt32, to: UInt32, id: UInt32, hopLimit: UInt32,
                                    fragment: [UInt8], portnum: UInt32 = MESH_HOP_PORTNUM,
                                    channel: UInt32 = 0, wantAck: Bool = false) -> [UInt8] {
        var pkt = ProtoWriter()
        pkt.fixed32Field(1, from)
        pkt.fixed32Field(2, to)
        if channel != 0 { pkt.varintField(3, UInt64(channel)) }
        pkt.bytesField(4, encodeData(payload: fragment, portnum: portnum))
        pkt.fixed32Field(6, id)
        pkt.varintField(9, UInt64(hopLimit))
        if wantAck { pkt.varintField(10, 1) }
        var radio = ProtoWriter()
        radio.bytesField(1, pkt.bytes)
        return radio.bytes
    }

    /// Encode the `ToRadio{ want_config_id }` the app sends on connect to make the radio stream its
    /// config + node db + MyNodeInfo (the bearer only needs MyNodeInfo, for our own node num).
    static func encodeWantConfig(_ nonce: UInt32) -> [UInt8] {
        var w = ProtoWriter()
        w.varintField(3, UInt64(nonce))
        return w.bytes
    }

    /// AdminMessage.get_channel_request. Firmware uses index+1 so 0 can mean "unset".
    static func encodeGetChannelRequest(index: Int) -> [UInt8] {
        var w = ProtoWriter()
        w.varintField(1, UInt64(index + 1))
        return w.bytes
    }

    static func encodeChannel(index: Int, name: String, psk: [UInt8], role: Int) -> [UInt8] {
        var settings = ProtoWriter()
        settings.bytesField(2, psk)
        settings.bytesField(3, Array(name.utf8))
        settings.fixed32Field(4, MESH_HOP_CHANNEL_ID)
        var channel = ProtoWriter()
        channel.varintField(1, UInt64(index))
        channel.bytesField(2, settings.bytes)
        channel.varintField(3, UInt64(role))
        return channel.bytes
    }

    /// AdminMessage.set_channel of Hop's SECONDARY, with the required session_passkey.
    static func encodeSetHopChannel(passkey: [UInt8], index: Int) -> [UInt8] {
        let channel = encodeChannel(index: index, name: MESH_HOP_CHANNEL_NAME,
                                    psk: MESH_HOP_CHANNEL_PSK, role: MESH_CHANNEL_ROLE_SECONDARY)
        var w = ProtoWriter()
        w.bytesField(33, channel)
        if !passkey.isEmpty { w.bytesField(101, passkey) }
        return w.bytes
    }

    /// AdminMessage.get_channel_response, for tests that drive the bearer without a radio.
    static func encodeGetChannelResponse(passkey: [UInt8], index: Int, name: String,
                                         psk: [UInt8], role: Int) -> [UInt8] {
        var w = ProtoWriter()
        w.bytesField(2, encodeChannel(index: index, name: name, psk: psk, role: role))
        if !passkey.isEmpty { w.bytesField(101, passkey) }
        return w.bytes
    }

    static func encodeAdminToRadio(to: UInt32, id: UInt32, admin: [UInt8]) -> [UInt8] {
        encodeToRadioPacket(from: 0, to: to, id: id, hopLimit: 0, fragment: admin,
                            portnum: MESH_ADMIN_PORTNUM, channel: 0)
    }

    /// Decode one `FromRadio` frame into the one thing the bearer acts on, or nil if it is a message the
    /// bearer ignores (config, node_info, log records, ...) or is malformed.
    static func decodeFromRadio(_ bytes: [UInt8]) -> MeshInbound? {
        var r = ProtoReader(bytes)
        while let (field, wire) = r.readTag() {
            switch (field, wire) {
            case (2, 2):
                guard let sub = r.readBytes() else { return nil }
                if let inbound = decodeMeshPacket(sub) { return inbound }
            case (3, 2):
                guard let sub = r.readBytes() else { return nil }
                if let num = decodeMyNodeNum(sub) { return .myNodeNum(num) }
            default:
                guard r.skip(wire) else { return nil }
            }
        }
        return nil
    }

    static func decodeMeshPacket(_ bytes: [UInt8]) -> MeshInbound? {
        var r = ProtoReader(bytes)
        var from: UInt32 = 0
        var decoded: [UInt8]?
        while let (field, wire) = r.readTag() {
            switch (field, wire) {
            case (1, 5): guard let v = r.readFixed32() else { return nil }; from = v
            case (4, 2): guard let v = r.readBytes() else { return nil }; decoded = v
            default: guard r.skip(wire) else { return nil }
            }
        }
        guard let data = decoded, let (port, payload) = decodeData(data) else { return nil }
        switch port {
        case MESH_HOP_PORTNUM: return .hopData(from: from, payload: payload)
        case MESH_ADMIN_PORTNUM: return .admin(payload: payload)
        case MESH_ROUTING_PORTNUM: return decodeRouting(data)
        default: return nil
        }
    }

    static func decodeRouting(_ data: [UInt8]) -> MeshInbound? {
        var r = ProtoReader(data)
        var port: UInt32 = 0
        var payload: [UInt8]?
        var requestId: UInt32 = 0
        while let (field, wire) = r.readTag() {
            switch (field, wire) {
            case (1, 0):
                guard let v = r.readVarint() else { return nil }
                port = UInt32(truncatingIfNeeded: v)
            case (2, 2): guard let v = r.readBytes() else { return nil }; payload = v
            case (6, 5): guard let v = r.readFixed32() else { return nil }; requestId = v
            default: guard r.skip(wire) else { return nil }
            }
        }
        guard port == MESH_ROUTING_PORTNUM else { return nil }
        var error = 0
        if let payload {
            var p = ProtoReader(payload)
            while let (field, wire) = p.readTag() {
                switch (field, wire) {
                case (3, 0):
                    guard let v = p.readVarint() else { return nil }
                    error = Int(v)
                default: guard p.skip(wire) else { return nil }
                }
            }
        }
        return .routing(requestId: requestId, error: error)
    }

    static func decodeData(_ bytes: [UInt8]) -> (port: UInt32, payload: [UInt8])? {
        var r = ProtoReader(bytes)
        var portnum: UInt32 = 0
        var payload: [UInt8]?
        var sawPort = false
        while let (field, wire) = r.readTag() {
            switch (field, wire) {
            case (1, 0):
                guard let v = r.readVarint() else { return nil }
                portnum = UInt32(truncatingIfNeeded: v)
                sawPort = true
            case (2, 2): guard let v = r.readBytes() else { return nil }; payload = v
            default: guard r.skip(wire) else { return nil }
            }
        }
        guard sawPort else { return nil }
        return (portnum, payload ?? [])
    }

    /// Decode a `Data` submessage, returning its payload IFF it is on the Hop port, else nil.
    static func decodeHopData(_ bytes: [UInt8]) -> [UInt8]? {
        guard let (port, payload) = decodeData(bytes), port == MESH_HOP_PORTNUM else { return nil }
        return payload
    }

    static func decodeChannel(_ bytes: [UInt8]) -> MeshChannel? {
        var r = ProtoReader(bytes)
        var index = 0
        var settings: [UInt8]?
        var role = 0
        while let (field, wire) = r.readTag() {
            switch (field, wire) {
            case (1, 0): guard let v = r.readVarint() else { return nil }; index = Int(v)
            case (2, 2): guard let v = r.readBytes() else { return nil }; settings = v
            case (3, 0): guard let v = r.readVarint() else { return nil }; role = Int(v)
            default: guard r.skip(wire) else { return nil }
            }
        }
        var name = ""
        var psk: [UInt8] = []
        if let settings {
            var s = ProtoReader(settings)
            while let (field, wire) = s.readTag() {
                switch (field, wire) {
                case (2, 2): guard let v = s.readBytes() else { return nil }; psk = v
                case (3, 2):
                    guard let v = s.readBytes(), let n = String(bytes: v, encoding: .utf8) else { return nil }
                    name = n
                default: guard s.skip(wire) else { return nil }
                }
            }
        }
        return MeshChannel(index: index, name: name, psk: psk, role: role)
    }

    static func decodeAdminMessage(_ bytes: [UInt8]) -> AdminInbound? {
        var r = ProtoReader(bytes)
        var passkey: [UInt8] = []
        var channel: MeshChannel?
        while let (field, wire) = r.readTag() {
            switch (field, wire) {
            case (2, 2):
                guard let sub = r.readBytes(), let ch = decodeChannel(sub) else { return nil }
                channel = ch
            case (101, 2): guard let v = r.readBytes() else { return nil }; passkey = v
            default: guard r.skip(wire) else { return nil }
            }
        }
        return AdminInbound(passkey: passkey, channel: channel)
    }

    static func decodeMyNodeNum(_ bytes: [UInt8]) -> UInt32? {
        var r = ProtoReader(bytes)
        while let (field, wire) = r.readTag() {
            if field == 1, wire == 0 { return r.readVarint().map { UInt32(truncatingIfNeeded: $0) } }
            guard r.skip(wire) else { return nil }
        }
        return nil
    }
}

// MARK: - Hop link-frame grammar (identical tags to the LAN bearer) -------------------------------------

enum MeshFrame {
    static func hello(myId: Data, isGreater: Bool) -> [UInt8] {
        var b: [UInt8] = [M_HELLO]
        b.append(contentsOf: myId)
        b.append(isGreater ? 1 : 0)
        b.append(0)
        return b
    }

    static func ping(seq: UInt64, nowMs: UInt64) -> [UInt8] {
        var b: [UInt8] = [M_PING]
        b.append(contentsOf: u64(seq))
        b.append(contentsOf: u64(nowMs))
        return b
    }

    static func pong(echo: [UInt8]) -> [UInt8] { [M_PONG] + echo }

    static func data(_ payload: [UInt8]) -> [UInt8] { [M_DATA] + payload }

    static func ack(msgId: UInt16) -> [UInt8] {
        [M_ACK, UInt8(msgId >> 8), UInt8(msgId & 0xff)]
    }

    static func ackMsgId(_ body: [UInt8]) -> UInt16? {
        guard body.count >= 3, body[0] == M_ACK else { return nil }
        return UInt16(body[1]) << 8 | UInt16(body[2])
    }

    /// The 16-byte peerId a HELLO body carries, or nil if the body is too short.
    static func helloPeerId(_ body: [UInt8]) -> Data? {
        body.count >= 17 ? Data(body[1..<17]) : nil
    }

    static func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (56 - $0 * 8)) & 0xff) } }

    static func u64dec(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 where o + k < b.count { v = v << 8 | UInt64(b[o + k]) }
        return v
    }
}

// MARK: - Fragmentation + reassembly --------------------------------------------------------------------

/// Split a Hop link-frame body into fragments that each fit one Meshtastic packet. Every fragment is
/// prefixed with [msgId:2][fragIndex:1][fragCount:1]. An empty body still yields ONE (empty) fragment so
/// a zero-length frame round-trips. Returns nil if the body is larger than MESH_MAX_MESSAGE (too big to
/// address with a one-byte fragment count).
func meshFragment(_ body: [UInt8], msgId: UInt16) -> [[UInt8]]? {
    guard body.count <= MESH_MAX_MESSAGE else { return nil }
    let count = body.isEmpty ? 1 : (body.count + MESH_MAX_CHUNK - 1) / MESH_MAX_CHUNK
    guard count <= MESH_MAX_FRAGS else { return nil }
    var out = [[UInt8]]()
    for idx in 0..<count {
        let start = idx * MESH_MAX_CHUNK
        let end = min(start + MESH_MAX_CHUNK, body.count)
        var frag: [UInt8] = [UInt8(msgId >> 8), UInt8(msgId & 0xff), UInt8(idx), UInt8(count)]
        if start < end { frag.append(contentsOf: body[start..<end]) }
        out.append(frag)
    }
    return out
}

/// The parsed header of one inbound fragment. Returns nil for a runt (< 4 header bytes) or an inconsistent
/// header (index >= count, or count == 0).
struct MeshFragHeader: Equatable {
    let msgId: UInt16
    let index: Int
    let count: Int
    let chunk: [UInt8]

    init?(_ frag: [UInt8]) {
        guard frag.count >= MESH_FRAG_HEADER else { return nil }
        let id = UInt16(frag[0]) << 8 | UInt16(frag[1])
        let idx = Int(frag[2])
        let cnt = Int(frag[3])
        guard cnt >= 1, cnt <= MESH_MAX_FRAGS, idx < cnt else { return nil }
        self.msgId = id
        self.index = idx
        self.count = cnt
        self.chunk = Array(frag[MESH_FRAG_HEADER...])
    }
}

struct MeshComplete: Equatable {
    let msgId: UInt16
    let body: [UInt8]
}

/// Per-peer reassembly of fragmented Hop frames. Keyed by (peer node num, msgId). A message completes when
/// all `count` fragments have arrived; it is evicted if it goes stale (TTL) or the peer exceeds
/// MESH_MAX_PARTIAL_PER_PEER concurrent partials (oldest dropped). Pure: the caller supplies `now` so it
/// is deterministically testable with no clock.
final class MeshReassembler {
    private struct Partial {
        var count: Int
        var chunks: [Int: [UInt8]]
        var firstSeenS: Double
    }

    // node num -> msgId -> Partial
    private var partials = [UInt32: [UInt16: Partial]]()

    /// Feed one inbound fragment from `peer`. Returns the fully reassembled frame body when this fragment
    /// completes a message, else nil. `nowS` is the caller's clock (seconds).
    func accept(peer: UInt32, fragment: [UInt8], nowS: Double) -> MeshComplete? {
        guard let h = MeshFragHeader(fragment) else { return nil }
        evictStale(nowS: nowS)
        var byId = partials[peer] ?? [:]

        if h.count == 1 {
            if byId.isEmpty { partials.removeValue(forKey: peer) } else { partials[peer] = byId }
            return MeshComplete(msgId: h.msgId, body: h.chunk)
        }

        var p = byId[h.msgId] ?? Partial(count: h.count, chunks: [:], firstSeenS: nowS)
        // A count mismatch across fragments of one id means corruption; restart this id from scratch.
        if p.count != h.count { p = Partial(count: h.count, chunks: [:], firstSeenS: nowS) }
        p.chunks[h.index] = h.chunk
        byId[h.msgId] = p

        // Bound concurrent partials per peer: drop the oldest if over budget.
        if byId.count > MESH_MAX_PARTIAL_PER_PEER {
            if let oldest = byId.min(by: { $0.value.firstSeenS < $1.value.firstSeenS })?.key {
                byId.removeValue(forKey: oldest)
            }
        }

        guard p.chunks.count == p.count else { partials[peer] = byId; return nil }

        // Complete: concatenate in index order and drop the partial.
        var body = [UInt8]()
        for idx in 0..<p.count { body.append(contentsOf: p.chunks[idx] ?? []) }
        byId.removeValue(forKey: h.msgId)
        if byId.isEmpty { partials.removeValue(forKey: peer) } else { partials[peer] = byId }
        return MeshComplete(msgId: h.msgId, body: body)
    }

    /// Drop every peer's partials whose first fragment is older than the TTL.
    func evictStale(nowS: Double) {
        for (peer, byId) in partials {
            var kept = byId
            for (id, p) in byId where nowS - p.firstSeenS > MESH_REASSEMBLY_TTL_S {
                kept.removeValue(forKey: id)
            }
            if kept.isEmpty { partials.removeValue(forKey: peer) } else { partials[peer] = kept }
        }
    }

    /// Forget everything buffered for a peer (called when its link goes down).
    func forget(peer: UInt32) { partials.removeValue(forKey: peer) }

    var partialPeerCount: Int { partials.count }
}

// MARK: - Dedup keep-rule (shared with every other bearer) ----------------------------------------------

/// The one-pipe-per-peer keep rule, identical to the LAN/BLE bearers: on a duplicate pair to one peer,
/// keep the leg whose "I am the greater id" role matches. Meshtastic is a broadcast medium so a true
/// duplicate is rare, but two simultaneous HELLOs can still race; this makes the survivor deterministic
/// and consistent with the id-based role the Noise handshake uses.
func meshKeepGreaterLeg(myId: Data, peer: Data) -> Bool { nodeIdGreater(myId, peer) }
