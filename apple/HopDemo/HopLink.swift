import Foundation
import CoreBluetooth

/// One L2CAP connection-oriented channel, framed as length-prefixed packets so the
/// node's opaque byte packets survive the stream boundary: a 4-byte big-endian
/// length, then that many bytes.
///
/// Reliability (iOS BLE drops links silently): a **keepalive** sends an empty frame
/// every few seconds to keep the channel warm and give the peer steady traffic, and
/// a **watchdog** closes the link if nothing has been received for too long — which
/// triggers the bearer's pending reconnect. Close is idempotent.
final class HopLink: NSObject, StreamDelegate {
    let id: UInt64
    private let channel: CBL2CAPChannel // retained — else the streams tear down
    private let input: InputStream
    private let output: OutputStream
    private let onBytes: (UInt64, Data) -> Void
    private let onClose: (UInt64) -> Void

    private var inBuffer = [UInt8]()
    private var outBuffer = [UInt8]()
    private var lastRead = Date()
    private var keepalive: Timer?
    private var watchdog: Timer?
    private var closed = false

    private static let keepaliveInterval: TimeInterval = 4
    private static let livenessTimeout: TimeInterval = 15

    init(id: UInt64, channel: CBL2CAPChannel,
         onBytes: @escaping (UInt64, Data) -> Void,
         onClose: @escaping (UInt64) -> Void) {
        self.id = id
        self.channel = channel
        self.input = channel.inputStream
        self.output = channel.outputStream
        self.onBytes = onBytes
        self.onClose = onClose
        super.init()
        for s in [input, output] {
            s.delegate = self
            s.schedule(in: .main, forMode: .common)
            s.open()
        }
        keepalive = Timer.scheduledTimer(withTimeInterval: Self.keepaliveInterval, repeats: true) { [weak self] _ in
            self?.send(Data()) // empty frame — peer ignores it, link stays warm
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.keepaliveInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastRead) > Self.livenessTimeout { self.close() }
        }
    }

    /// Frame and queue an outbound packet (empty = keepalive).
    func send(_ bytes: Data) {
        guard !closed else { return }
        let len = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: len) { outBuffer.append(contentsOf: $0) }
        outBuffer.append(contentsOf: bytes)
        drainWrites()
    }

    func close() {
        guard !closed else { return }
        closed = true
        keepalive?.invalidate(); watchdog?.invalidate()
        for s in [input, output] { s.close(); s.remove(from: .main, forMode: .common) }
        onClose(id)
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable: readAvailable()
        case .hasSpaceAvailable: drainWrites()
        case .endEncountered, .errorOccurred: close()
        default: break
        }
    }

    private func drainWrites() {
        while !outBuffer.isEmpty && output.hasSpaceAvailable {
            let n = output.write(outBuffer, maxLength: outBuffer.count)
            if n > 0 { outBuffer.removeFirst(n) } else { break }
        }
    }

    private func readAvailable() {
        var tmp = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let n = input.read(&tmp, maxLength: tmp.count)
            if n > 0 { inBuffer.append(contentsOf: tmp[0..<n]) } else { break }
        }
        lastRead = Date()
        deframe()
    }

    private func deframe() {
        while inBuffer.count >= 4 {
            let len = UInt32(inBuffer[0]) << 24 | UInt32(inBuffer[1]) << 16
                    | UInt32(inBuffer[2]) << 8  | UInt32(inBuffer[3])
            let total = 4 + Int(len)
            guard inBuffer.count >= total else { break }
            if len > 0 { // skip empty keepalive frames
                onBytes(id, Data(inBuffer[4..<total]))
            }
            inBuffer.removeFirst(total)
        }
    }
}
