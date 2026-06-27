import Foundation
import CoreBluetooth
import Network

/// A single long-lived background thread running a RunLoop, where ALL BLE L2CAP stream I/O and the
/// per-link keepalive/watchdog timers live — deliberately OFF the main runloop. The lab proved iOS 18+
/// silently drops CoreBluetooth stream/L2CAP callbacks scheduled on a busy main runloop, and main-
/// thread stream servicing starves the link under load. One shared thread serializes all L2CAP links.
final class IOThread {
    static let shared = IOThread()
    private var cfRunLoop: CFRunLoop!

    private init() {
        let sem = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            cfRunLoop = CFRunLoopGetCurrent()
            // A port keeps the runloop alive when it has no other input sources (else run() returns).
            RunLoop.current.add(NSMachPort(), forMode: .common)
            sem.signal()
            RunLoop.current.run()
        }
        thread.name = "hop.io"
        thread.qualityOfService = .userInitiated
        thread.start()
        sem.wait()   // block until the runloop is captured + alive
    }

    /// Run `block` on the I/O thread's runloop (in common modes, so it interleaves with stream events).
    /// Always async; never blocks the caller — safe to call from `hop.core`, `hop.ble`, or main.
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(cfRunLoop)
    }
}

/// One L2CAP connection-oriented channel, framed as length-prefixed packets so the
/// node's opaque byte packets survive the stream boundary: a 4-byte big-endian
/// length, then that many bytes.
///
/// Reliability (iOS BLE drops links silently): a **keepalive** sends an empty frame
/// every few seconds to keep the channel warm and give the peer steady traffic, and
/// a **watchdog** closes the link if nothing has been received for too long — which
/// triggers the bearer's pending reconnect. Close is idempotent.
///
/// Threading: the streams + both timers are scheduled on the shared `IOThread` runloop (NOT main), so
/// every method below — `send`, `close`, the stream delegate, the timer fires — runs single-threaded
/// on that I/O thread; no locks. `onBytes`/`onClose` are invoked there, and the bearer hops them onto
/// `hop.core` (node) / main (UI). `send`, called from the bearer's pump on `hop.core`, marshals itself
/// onto the I/O thread before touching the stream/buffer.
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
        // Streams + keepalive/watchdog live on the shared IOThread runloop, off main (see class doc).
        // Schedule them there; everything thereafter is single-threaded on that thread.
        IOThread.shared.perform { [self] in
            let rl = RunLoop.current
            for s in [input, output] {
                s.delegate = self
                s.schedule(in: rl, forMode: .common)
                s.open()
            }
            let ka = Timer(timeInterval: Self.keepaliveInterval, repeats: true) { [weak self] _ in
                self?.send(Data()) // empty frame — peer ignores it, link stays warm
            }
            let wd = Timer(timeInterval: Self.keepaliveInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastRead) > Self.livenessTimeout { self.close() }
            }
            rl.add(ka, forMode: .common); rl.add(wd, forMode: .common)
            keepalive = ka; watchdog = wd
        }
    }

    /// Frame and queue an outbound packet (empty = keepalive). Called from the bearer's pump on
    /// `hop.core`; marshals onto the I/O thread before touching the buffer/stream.
    func send(_ bytes: Data) {
        IOThread.shared.perform { [weak self] in
            guard let self, !self.closed else { return }
            let len = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: len) { self.outBuffer.append(contentsOf: $0) }
            self.outBuffer.append(contentsOf: bytes)
            self.drainWrites()
        }
    }

    /// Tear down the link. Runs on the I/O thread (the timers/stream events call it there); if invoked
    /// from elsewhere it marshals over so stream teardown happens on the runloop that owns them.
    func close() {
        IOThread.shared.perform { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.keepalive?.invalidate(); self.watchdog?.invalidate()
            let rl = RunLoop.current
            for s in [self.input, self.output] { s.close(); s.remove(from: rl, forMode: .common) }
            self.onClose(self.id)
        }
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

/// One LAN (local-network TCP) link over an `NWConnection`, with the SAME 4-byte big-endian
/// length-prefix framing as [HopLink]. This is the cross-platform high-bandwidth path: when two
/// devices share Wi-Fi, they discover via mDNS/Bonjour and talk over plain TCP — works iOS↔iOS,
/// iOS↔Android, and Android↔Android (unlike MultipeerConnectivity/AWDL, which is Apple-only).
final class LanLink {
    let id: UInt64
    private let conn: NWConnection
    private let onReady: (UInt64) -> Void
    private let onBytes: (UInt64, Data) -> Void
    private let onClose: (UInt64) -> Void
    private let lock = NSLock()
    private var closed = false
    private var keepalive: DispatchSourceTimer?

    /// All LAN I/O runs OFF the main thread. Critically, this keeps Wi-Fi traffic from starving the
    /// BLE link's keepalive/stream servicing (which run on the main runloop) — a starved BLE link
    /// goes quiet, iOS's connection-supervision timeout fires, and the link drops (REMOTE_USER_
    /// TERMINATED) then churns. Independent transports must not compete for the main thread, so Hop
    /// can hold BLE + Wi-Fi paths to the same peer at once.
    private static let ioQueue = DispatchQueue(label: "hop.lan.io", qos: .userInitiated)

    init(id: UInt64, conn: NWConnection,
         onReady: @escaping (UInt64) -> Void,
         onBytes: @escaping (UInt64, Data) -> Void,
         onClose: @escaping (UInt64) -> Void) {
        self.id = id
        self.conn = conn
        self.onReady = onReady
        self.onBytes = onBytes
        self.onClose = onClose
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady(self.id)   // TCP up — now a Noise handshake can begin (on ioQueue)
                self.startKeepalive()
                self.readHeader()
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        conn.start(queue: Self.ioQueue)
    }

    private func startKeepalive() {
        let t = DispatchSource.makeTimerSource(queue: Self.ioQueue)
        t.schedule(deadline: .now() + 4, repeating: 4)
        t.setEventHandler { [weak self] in self?.send(Data()) }  // empty frame keeps the TCP link warm
        t.resume()
        keepalive = t
    }

    func send(_ bytes: Data) {
        var len = UInt32(bytes.count).bigEndian
        var frame = Data()
        withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        frame.append(bytes)
        conn.send(content: frame, completion: .contentProcessed { _ in })  // NWConnection.send is thread-safe
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        keepalive?.cancel()
        conn.cancel()
        onClose(id)
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, done, err in
            guard let self else { return }
            if let err = err as NSError?, err.code != 0 { return self.close() }
            guard let data, data.count == 4 else { if done { self.close() }; return }
            let len = UInt32(data[data.startIndex]) << 24 | UInt32(data[data.startIndex + 1]) << 16
                    | UInt32(data[data.startIndex + 2]) << 8 | UInt32(data[data.startIndex + 3])
            if len == 0 { return self.readHeader() } // keepalive frame
            self.readBody(Int(len))
        }
    }

    private func readBody(_ len: Int) {
        conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, done, err in
            guard let self else { return }
            if let err = err as NSError?, err.code != 0 { return self.close() }
            if let data, data.count == len { self.onBytes(self.id, data) }
            if done { return self.close() }
            self.readHeader()
        }
    }
}
