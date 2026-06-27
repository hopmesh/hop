import Foundation

/// One Hop link carried over **GATT** instead of L2CAP — the reliable cross-platform fallback.
///
/// Apple CoreBluetooth cannot open an L2CAP channel to an Android peripheral (it returns
/// `CBErrorDomain` "Unknown error"), so iOS↔Android can't use the fast L2CAP path. GATT writes +
/// notifications work in every direction (and in iOS background), so we frame the node's opaque
/// packets the SAME way `HopLink` does — a 4-byte big-endian length then that many bytes — but ship
/// them as GATT operations, chunked to the negotiated MTU.
///
/// Reliability is at the BLE layer (central writes WITH response; peripheral notifications are paced
/// against `isReady`), which needs strict **one-op-at-a-time** flow control: queue a frame, send a
/// chunk, wait for the completion callback (`chunkSent()`), then the next. The bearer supplies the
/// actual GATT op via `sendChunk` and feeds completions/receipts back in.
final class GattDataLink {
    let id: UInt64
    static let gattLinkBase: UInt64 = 60_000     // link-id range for GATT-data links

    private let usablePayload: () -> Int          // ATT MTU - 3, kept current
    private let sendChunk: (Data) -> Bool         // perform the GATT write/notify; false = couldn't start
    private let onBytes: (UInt64, Data) -> Void   // a complete reassembled frame
    private let onClose: (UInt64) -> Void

    private var outFrames: [Data] = []            // complete framed buffers awaiting send
    private var cursor: Data?                      // frame currently being chunked out
    private var offset = 0
    private var inFlight = false                   // a chunk is awaiting its completion callback
    private var inBuf = Data()                     // inbound reassembly buffer
    private var closed = false
    private(set) var lastRx = Date()
    private var gotFrame = false                   // received ≥1 real (non-keepalive) frame
    private let created = Date()

    private static let maxFrame = 4 * 1024 * 1024
    private static let minChunk = 20               // default ATT MTU 23 - 3
    private static let handshakeTimeout: TimeInterval = 4

    init(id: UInt64,
         usablePayload: @escaping () -> Int,
         sendChunk: @escaping (Data) -> Bool,
         onBytes: @escaping (UInt64, Data) -> Void,
         onClose: @escaping (UInt64) -> Void) {
        self.id = id
        self.usablePayload = usablePayload
        self.sendChunk = sendChunk
        self.onBytes = onBytes
        self.onClose = onClose
    }

    /// Frame and queue an outbound packet (empty = keepalive); kicks the pump. Call on the main queue.
    func send(_ bytes: Data) {
        guard !closed else { return }
        let n = UInt32(bytes.count)
        var framed = Data(capacity: 4 + bytes.count)
        framed.append(UInt8((n >> 24) & 0xff)); framed.append(UInt8((n >> 16) & 0xff))
        framed.append(UInt8((n >> 8) & 0xff));  framed.append(UInt8(n & 0xff))
        framed.append(bytes)
        outFrames.append(framed)
        pump()
    }

    /// The previous `sendChunk` completed — advance to the next chunk/frame.
    func chunkSent() {
        inFlight = false
        pump()
    }

    /// A GATT write/notification arrived: reassemble and surface whole frames.
    func received(_ data: Data) {
        guard !closed else { return }
        lastRx = Date()
        inBuf.append(data)
        while inBuf.count >= 4 {
            let b = [UInt8](inBuf.prefix(4))
            let len = (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
            if len < 0 || len > Self.maxFrame { close(); return }
            let total = 4 + len
            guard inBuf.count >= total else { break }
            if len > 0 {
                let frame = inBuf.subdata(in: (inBuf.startIndex + 4)..<(inBuf.startIndex + total))
                gotFrame = true
                onBytes(id, frame)
            }
            inBuf.removeSubrange(inBuf.startIndex..<(inBuf.startIndex + total))
        }
    }

    /// Send the next chunk if the channel is idle and there's data.
    private func pump() {
        guard !closed, !inFlight else { return }
        if cursor == nil {
            guard !outFrames.isEmpty else { return }
            cursor = outFrames.removeFirst()
            offset = 0
        }
        guard let frame = cursor else { return }
        let room = max(usablePayload(), Self.minChunk)
        let end = min(offset + room, frame.count)
        let chunk = frame.subdata(in: (frame.startIndex + offset)..<(frame.startIndex + end))
        inFlight = true
        if !sendChunk(chunk) {            // couldn't even start the op (peer gone / congested)
            inFlight = false
            close()
            return
        }
        offset = end
        if offset >= frame.count { cursor = nil }   // frame fully queued; next pump pulls the next
    }

    var idle: TimeInterval { Date().timeIntervalSince(lastRx) }
    var isHalfOpen: Bool { !gotFrame && Date().timeIntervalSince(created) > Self.handshakeTimeout }

    func close() {
        guard !closed else { return }
        closed = true
        onClose(id)
    }
}
