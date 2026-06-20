import Foundation
import CoreBluetooth
import CoreLocation
import MultipeerConnectivity
import Network
import UserNotifications
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// The Hop identity secret is derived **deterministically from the device's vendor
/// id** — so the keypair (and thus the address) is identical every launch *by
/// construction*, with no dependency on Keychain/file storage (which proved
/// unreliable on dev-installed builds, wiping the address on reinstall). The secret
/// is the keypair is the address; re-deriving the same seed keeps the node routeable.
/// `note` is shown in the UI for transparency.
enum IdentityStore {
    static var note = "init"

    /// A 32-byte Ed25519 seed from the vendor id (stable across launches/reinstall,
    /// until every app from this vendor is removed).
    static func deviceSeed() -> Data {
        #if canImport(UIKit)
        let vid = UIDevice.current.identifierForVendor?.uuidString
        #else
        let vid: String? = nil
        #endif
        note = vid != nil ? "device-derived" : "random (no vendor id)"
        let basis = vid ?? UUID().uuidString
        return Data(SHA256.hash(data: Data("hop.identity.v1|\(basis)".utf8)))
    }
}

/// Foreground CoreBluetooth + L2CAP bearer for Hop, plus iBeacon region monitoring
/// for background wake (DESIGN.md §11, §22). It shuttles the node's opaque byte
/// packets and surfaces peers/messages/queue to the UI; all protocol logic is in
/// `hop-core`.
final class HopBearer: NSObject, ObservableObject {
    static let shared = HopBearer()

    static let serviceUUID = CBUUID(string: "F0900000-0000-4000-8000-000000000000")
    static let psmCharUUID = CBUUID(string: "F0900001-0000-4000-8000-000000000000")
    static let beaconUUID = UUID(uuidString: "F0900BEA-C000-4000-8000-000000000000")!
    static let refreshTaskId = "net.waldrip.hop.refresh"
    /// App-level presence service: title = display name (DESIGN.md §23).
    static let presenceService = "presence"
    /// MultipeerConnectivity service type for the Wi-Fi bearer (≤15 chars).
    static let mcServiceType = "hop-mesh"
    /// Default cloud relay: the anycast address resolves to the device's nearest node,
    /// which it checks into for pending messages (DESIGN.md §28).
    static let defaultRelay = "wss://relay.hopme.sh/"
    /// How long a presence advert lives before it must be refreshed (10 min).
    static let presenceTtlMs: UInt32 = 600_000

    struct Peer: Identifiable, Hashable {
        let address: Data; let name: String; let hops: UInt8
        var active: Bool = true       // peer's app foreground (vs backgrounded)
        var platform: String = ""     // "ios" / "android"
        var app: String = ""          // the app embedding Hop on that device
        var id: Data { address }
        // Identity is the address — metadata updates don't churn navigation.
        static func == (l: Peer, r: Peer) -> Bool { l.address == r.address }
        func hash(into h: inout Hasher) { h.combine(address) }
    }
    struct Message: Identifiable {
        let id = UUID()
        let peer: String; let text: String; let incoming: Bool
        var bundleId: Data? = nil
        // Incoming metadata (shown under the bubble).
        var hops: UInt8 = 0
        var latencyMs: UInt64? = nil      // received time − sender's send time
        var trace: [TraceHopInfo] = []    // each forwarding hop, resolved at render (§27)
        // Outgoing delivery tracking.
        var sentAt: Date = Date()
        var deliveredAt: Date? = nil
        var relayed: UInt32 = 0
        var delivered: Bool = false
        var deliveryHops: UInt8 = 0
    }
    struct QueueRow: Identifiable {
        let id: Data; let own: Bool; let to: String; let priority: UInt8; let hops: UInt8
    }
    struct TransportStatus: Identifiable, Hashable {
        let id: String      // "Bluetooth" / "Wi-Fi"
        let active: Bool    // radio up + bearer running
        let links: Int      // live links on this transport
    }

    @Published var myAddress = ""
    @Published var myName = ""
    @Published var idNote = ""   // identity persistence outcome (diagnostic)
    @Published var status = "starting…" { didSet { NSLog("HOPLOG status: \(status)") } }
    @Published var reachable: [Peer] = []   // discovered now (direct + mesh)
    @Published var seen: [Peer] = []        // historical, not currently reachable
    @Published var secured: Set<Data> = []  // addresses we have a forward-secret session with
    @Published var routed: Set<Data> = []   // addresses we've learned a live route to (§27)
    @Published var transports: [TransportStatus] = []  // per-bearer status (all run at once)
    @Published var relayStatus = "not connected"        // cloud relay link state
    @Published var linkTransports: [Data: Set<String>] = [:]  // direct peer → transport(s) carrying it
    @Published var relays: [Peer] = []   // connected cloud relays (named by their domain via hop.identify)
    /// Resolved display name per 8-byte short address, for resolving trace hops (§27/§29).
    @Published var nameByShort: [Data: String] = [:]
    @Published var serviceLog: [String] = []   // hop.identify + custom service-call activity (§29)
    private var identities: [Data: IdentityInfo] = [:]   // address → identify record
    private var identifyAsked = Set<Data>()              // addresses we've sent hop.identify to
    private var identifyReqs = Set<Data>()               // outstanding identify request bundle ids
    @Published var messages: [Message] = []
    @Published var queue: [QueueRow] = []
    @Published var unread: [String: Int] = [:]   // peer name → unread incoming count
    @Published var httpResults: [String] = []    // egress request/response log (Use Case A)
    private var activePeer: String?              // chat currently on screen (not counted)

    /// Stable identity across launches. Stored in the **Keychain**, not UserDefaults:
    /// a force-quit kills the process before UserDefaults flushes its buffered write,
    /// losing the secret and regenerating the address every launch. The Keychain
    /// persists immediately (and survives reinstall).
    private let node: HopNode = {
        // Persistent message store on disk — survives restarts; bounded (older relayed
        // messages are evicted to make room). The identity secret is stored separately.
        let dbPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("hop.db").path
        // Identity is derived from the device, so the address is stable every launch
        // with no storage to fail. The db path persists *messages*.
        return HopNode.open(dbPath: dbPath, secret: IdentityStore.deviceSeed())
    }()
    private var peripheralMgr: CBPeripheralManager!
    private var centralMgr: CBCentralManager!
    private let location = CLLocationManager()
    private lazy var beaconRegion = CLBeaconRegion(uuid: HopBearer.beaconUUID, identifier: "hop")
    private var psm: CBL2CAPPSM = 0
    private var links: [UInt64: HopLink] = [:]
    private var nextLinkId: UInt64 = 1
    private var connecting = Set<UUID>()
    private var opened = Set<UUID>()
    private var retained: [UUID: CBPeripheral] = [:]
    private var backoff: [UUID: TimeInterval] = [:]   // per-peer reconnect delay
    private var reconnectScheduled = Set<UUID>()
    // Wi-Fi bearer (MultipeerConnectivity) — a second transport feeding the same node.
    private var mcPeerID: MCPeerID?
    private var mcSession: MCSession?
    private var mcAdvertiser: MCNearbyServiceAdvertiser?
    private var mcBrowser: MCNearbyServiceBrowser?
    private var mcLinkByPeer: [MCPeerID: UInt64] = [:]
    private var mcPeerByLink: [UInt64: MCPeerID] = [:]
    private var mcNextLinkId: UInt64 = 10_000   // distinct id range from BLE links
    private var wifiBlocked = false             // MC failed to start (e.g. local-network denied)
    // Cloud relay bearer — reaches a hop-relayd over the internet (DESIGN.md §19, §21).
    // Two flavors share one link id: raw TCP (path A, the VM) and WebSocket (path B,
    // Cloud Run behind the global LB, wss:// terminating TLS at the balancer).
    private var relayConn: NWConnection?
    private var relayWS: URLSessionWebSocketTask?
    private var relaySession: URLSession?
    private var relayURL: String?              // last relay endpoint (for auto check-in)
    private var relayReconnectScheduled = false
    private let relayLinkId: UInt64 = 20_000    // distinct id range from BLE/Wi-Fi
    private var l2capPsm: [UUID: CBL2CAPPSM] = [:]    // last PSM read per peripheral
    private var l2capAttempts: [UUID: Int] = [:]      // L2CAP open retry counter
    private var didSetupPeripheral = false            // peripheral published this power cycle
    private var nameByAddr: [Data: String] = [:]
    private var contacts: [Data: Peer] = [:]   // app-side contact book (address → peer)
    private var lastRelayLog = -1
    private var lastReachLog = -1
    private var tickTimer: Timer?
    private var advTimer: Timer?
    private var advCounter = 0
    private var advBeaconNow = false
    private var started = false
    private var appActive = true   // our app foreground state, carried in presence
    // Real Wi-Fi availability (MC's session object stays non-nil even when the radio is
    // off in Settings, so we can't infer the radio from it).
    private let pathMonitor = NWPathMonitor()
    private var wifiUp = false

    /// The app embedding Hop on this device (shown to peers via presence).
    static let appName: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "HopDemo"

    func start(name: String) {
        guard !started else { return }
        started = true
        myName = name
        node.setName(name: name)   // what hop.identify reports for us (§29)
        myAddress = HopBearer.base58(node.address())
        idNote = "\(IdentityStore.note) → \(myAddress.prefix(8))"
        // Note: we deliberately do NOT stamp our app id into trace hops — that would
        // advertise which app this device runs to every relay on the path (§27 privacy).
        // Device hops show as "device"; only infra relays self-identify as "Hop Relay".
        // Presence is an app-level service (DESIGN.md §23): we publish our display
        // name on the "presence" topic and subscribe so discovered records are
        // retained. The protocol knows nothing about names — contacts live here.
        node.subscribe(topic: HopBearer.presenceService)
        publishPresence()
        // Publish our prekey once so peers can open forward-secret sessions to us
        // (DESIGN.md §25). Its TTL is long and link-up gossip re-offers it to new
        // neighbours, so no periodic re-publish is needed.
        _ = try? node.publishPrekey()

        // Check in with our nearest cloud node (anycast) for pending messages, and keep
        // checked in by auto-reconnecting on drop/foreground (DESIGN.md §28).
        connectRelay(HopBearer.defaultRelay)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        #if canImport(UIKit)
        // Re-publish presence with our foreground/background state on each transition
        // (iOS suspends us shortly after backgrounding, so the "bg" advert is our last
        // word until we return — peers show that as our state).
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appActive = true; self?.publishPresence(); self?.restartWiFi()
            self?.scheduleRelayReconnect()   // re-check-in on foreground (§28)
            self?.pump()
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appActive = false; self?.publishPresence(); self?.pump()
        }
        #endif

        peripheralMgr = CBPeripheralManager(delegate: self, queue: .main,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "hop.peripheral"])
        centralMgr = CBCentralManager(delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "hop.central"])

        startWiFi()

        // Reflect the real Wi-Fi radio in the indicator (MC's session stays non-nil even
        // when Wi-Fi is switched off, which kept it showing green).
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.wifiUp = path.status == .satisfied && path.usesInterfaceType(.wifi)
                self?.refresh()
            }
        }
        pathMonitor.start(queue: DispatchQueue.global(qos: .utility))

        // iBeacon region monitoring → background/killed wake (§22).
        location.delegate = self
        location.requestAlwaysAuthorization()
        beaconRegion.notifyOnEntry = true
        beaconRegion.notifyEntryStateOnDisplay = true

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.backgroundTick()
        }
    }

    private var tickCount = 0

    /// Re-publish our presence advert so it stays live (it carries a TTL) and any
    /// rename propagates. The advert's publisher field is our address — that's all a
    /// peer needs to seal a message back to us (DESIGN.md §4, §23).
    private func publishPresence() {
        // summary carries app-level metadata: "state|platform|app".
        let meta = "\(appActive ? "fg" : "bg")|ios|\(HopBearer.appName)"
        _ = try? node.publishService(service: HopBearer.presenceService,
                                     title: myName, summary: meta, tags: [],
                                     ttlMs: HopBearer.presenceTtlMs)
    }

    func backgroundTick() {
        node.tick(nowMs: HopBearer.nowMs())
        tickCount += 1
        // Refresh presence periodically so it never lapses its TTL (link-up gossip
        // also shares it to new neighbours immediately).
        if tickCount % 20 == 0 { publishPresence() }
        pump()
    }

    /// Persisted display name to use across launches (falls back to the device name).
    static func savedName(default deviceName: String) -> String {
        UserDefaults.standard.string(forKey: "hop.displayName") ?? deviceName
    }

    /// Change this device's name; persists it and re-publishes presence so peers update.
    func setName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != myName else { return }
        myName = trimmed
        node.setName(name: trimmed)   // update what hop.identify reports (§29)
        UserDefaults.standard.set(trimmed, forKey: "hop.displayName")
        publishPresence()
        pump()
    }

    func send(_ text: String, to peer: Peer) {
        let id = try? node.sendMessage(dst: peer.address,
                                       contentType: "text/plain", body: Data(text.utf8),
                                       requestAck: true)
        messages.append(Message(peer: peer.name, text: text, incoming: false, bundleId: id))
        pump()
    }

    // MARK: - Wi-Fi (MultipeerConnectivity) bearer

    /// Stand up the Wi-Fi bearer: advertise + browse for nearby Hop peers and shuttle
    /// the node's frames over a `MCSession`, exactly like the BLE bearer but a
    /// different medium (DESIGN.md §26). Encryption is left to Hop's Noise layer.
    private func startWiFi() {
        let pid = MCPeerID(displayName: String(myAddress.prefix(60)))
        mcPeerID = pid
        let session = MCSession(peer: pid, securityIdentity: nil, encryptionPreference: .none)
        session.delegate = self
        mcSession = session
        let adv = MCNearbyServiceAdvertiser(peer: pid, discoveryInfo: nil, serviceType: HopBearer.mcServiceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        mcAdvertiser = adv
        let br = MCNearbyServiceBrowser(peer: pid, serviceType: HopBearer.mcServiceType)
        br.delegate = self
        br.startBrowsingForPeers()
        mcBrowser = br
        NSLog("HOPLOG wifi start: \(pid.displayName)")
    }

    /// Re-attempt advertise/browse and clear any blocked state. Called on foreground —
    /// MultipeerConnectivity errors out while the Local Network prompt is still
    /// pending, so this recovers once the user grants permission (no relaunch needed).
    private func restartWiFi() {
        wifiBlocked = false
        mcAdvertiser?.stopAdvertisingPeer()
        mcBrowser?.stopBrowsingForPeers()
        mcAdvertiser?.startAdvertisingPeer()
        mcBrowser?.startBrowsingForPeers()
        NSLog("HOPLOG wifi restart")
    }

    // MARK: - Cloud relay bearer (→ hop-relayd)

    /// Connect to a `hop-relayd`. Accepts either a `host:port` (raw TCP, path A) or a
    /// `ws://`/`wss://` URL (WebSocket, path B). The device dials, so it's the Noise
    /// initiator. Once connected, presence floods over this link, so two devices on the
    /// same relay discover and message each other across the internet (DESIGN.md §19, §21).
    func connectRelay(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        relayURL = trimmed   // remembered so we auto-reconnect (check-in) on drop (§28)
        if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            connectRelayWS(trimmed)
        } else {
            connectRelayTCP(trimmed)
        }
    }

    /// Reconnect to the last relay after a backoff — this is the device "check-in"
    /// (DESIGN.md §28): reconnecting to the anycast address wakes our nearest node and
    /// pulls any pending messages. Triggered on drop and on foreground.
    private func scheduleRelayReconnect() {
        guard let url = relayURL, !relayReconnectScheduled else { return }
        relayReconnectScheduled = true
        let delay = 5.0 + Double.random(in: 0...3)   // small backoff + jitter
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.relayReconnectScheduled = false
            // Only reconnect if we're not already connected.
            if self.relayStatus != "connected" { self.connectRelay(url) }
        }
    }

    /// WebSocket bearer: each link packet is one binary frame (no length framing — WS
    /// supplies it). The LB terminates TLS, so `wss://relay.hopme.sh/` reaches `ws://`
    /// inside the container.
    private func connectRelayWS(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { relayStatus = "bad url"; return }
        relayConn?.cancel(); relayConn = nil
        relayWS?.cancel(with: .goingAway, reason: nil)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        relaySession = session
        let task = session.webSocketTask(with: url)
        relayWS = task
        relayStatus = "connecting…"
        task.resume()   // node.connected fires on didOpenWithProtocol
    }

    private func receiveRelayWS() {
        relayWS?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .data(let d) = message {
                    DispatchQueue.main.async { self.node.received(link: self.relayLinkId, bytes: d); self.pump() }
                }
                self.receiveRelayWS()
            case .failure:
                DispatchQueue.main.async {
                    self.relayStatus = "disconnected"
                    self.node.disconnected(link: self.relayLinkId); self.pump()
                }
            }
        }
    }

    /// Connect to a `hop-relayd` at `host:port` over TCP. Framing matches the daemon
    /// (4-byte big-endian length prefix).
    private func connectRelayTCP(_ hostPort: String) {
        let parts = hostPort.split(separator: ":")
        guard parts.count == 2, let port = NWEndpoint.Port(String(parts[1])) else {
            relayStatus = "bad address"; return
        }
        relayWS?.cancel(with: .goingAway, reason: nil); relayWS = nil
        relayConn?.cancel()
        let conn = NWConnection(host: NWEndpoint.Host(String(parts[0])), port: port, using: .tcp)
        relayConn = conn
        let link = relayLinkId
        relayStatus = "connecting…"
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.relayStatus = "connected"
                    self.node.connected(link: link, initiator: true)
                    self.receiveRelayFrame(conn, link: link)
                    self.pump()
                case .failed(let e):
                    self.relayStatus = "failed: \(e.localizedDescription)"
                    self.node.disconnected(link: link); self.pump()
                case .cancelled:
                    self.relayStatus = "disconnected"
                    self.node.disconnected(link: link)
                default: break
                }
            }
        }
        conn.start(queue: .main)
    }

    private func receiveRelayFrame(_ conn: NWConnection, link: UInt64) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] hdr, _, done, err in
            guard let self else { return }
            guard let hdr, hdr.count == 4, err == nil else {
                DispatchQueue.main.async { if done || err != nil { self.node.disconnected(link: link) } }
                return
            }
            let b = [UInt8](hdr)
            let n = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard n > 0, n <= 1 << 20 else { return }
            conn.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] payload, _, done2, err2 in
                guard let self else { return }
                if let payload, payload.count == n {
                    DispatchQueue.main.async { self.node.received(link: link, bytes: payload); self.pump() }
                    self.receiveRelayFrame(conn, link: link)
                } else if done2 || err2 != nil {
                    DispatchQueue.main.async { self.node.disconnected(link: link) }
                }
            }
        }
    }

    private func relaySend(_ bytes: Data) {
        if let ws = relayWS {
            ws.send(.data(bytes)) { _ in }   // one link packet = one WS binary frame
            return
        }
        var len = UInt32(bytes.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(bytes)
        relayConn?.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - plumbing

    private func addLink(_ channel: CBL2CAPChannel, initiator: Bool) {
        let id = nextLinkId; nextLinkId += 1
        NSLog("HOPLOG addLink id=\(id) initiator=\(initiator)")
        let link = HopLink(id: id, channel: channel,
                           onBytes: { [weak self] lid, data in
                               NSLog("HOPLOG recv \(data.count)B on link \(lid)")
                               self?.node.received(link: lid, bytes: data); self?.pump()
                           },
                           onClose: { [weak self] lid in
                               self?.links[lid] = nil; self?.node.disconnected(link: lid); self?.refresh()
                           })
        links[id] = link
        node.connected(link: id, initiator: initiator)
        status = "linked (\(initiator ? "central" : "peripheral"))"
        pump()
    }

    private func pump() {
        for pkt in node.drainOutgoing() {
            if let link = links[pkt.link] {
                link.send(pkt.bytes)                       // BLE L2CAP link
            } else if let peer = mcPeerByLink[pkt.link] {
                try? mcSession?.send(pkt.bytes, toPeers: [peer], with: .reliable) // Wi-Fi link
            } else if pkt.link == relayLinkId {
                relaySend(pkt.bytes)                       // cloud relay (TCP) link
            }
        }
        refresh()
        for m in node.takeInbox() {
            let who = nameByAddr[m.from] ?? HopBearer.shortHex(m.from)
            let text = String(data: m.body, encoding: .utf8) ?? "<\(m.body.count) bytes>"
            let now = HopBearer.nowMs()
            let latency = now >= m.createdAt ? now - m.createdAt : 0  // clamp clock skew
            messages.append(Message(peer: who, text: text, incoming: true,
                                    hops: m.hops, latencyMs: latency, trace: m.trace))
            if who != activePeer { unread[who, default: 0] += 1 }  // badge unless viewing
            notifyIfBackgrounded(from: who, text: text)
        }
        serveHttpRequests()  // gateway role + collect any egress responses
        drainServices()      // hop.identify replies + custom service calls (§29)
    }

    // MARK: - Services & commands (DESIGN.md §29)

    /// Queue a built-in identity call to `address` (once per session per address) so we
    /// learn its display name / a relay's domain — and can resolve it in traces. Does not
    /// pump (safe to call from `refresh`); the next tick flushes it.
    private func queueIdentify(_ address: Data) {
        guard !identifyAsked.contains(address) else { return }
        identifyAsked.insert(address)
        if let id = try? node.sendServiceRequest(dst: address, service: serviceIdentify(),
                                                 method: "", args: Data()) {
            identifyReqs.insert(id)
        }
    }

    /// Identify `address` now (from the UI), flushing immediately.
    func identify(_ address: Data) {
        queueIdentify(address)
        pump()
    }

    /// The resolved identity (name + kind) we've learned for an address, if any.
    func identity(_ address: Data) -> IdentityInfo? { identities[address] }

    /// Best display name for a full address: an identify name, a known peer/relay's name,
    /// else the short address.
    func displayName(_ address: Data) -> String {
        if let info = identities[address], !info.name.isEmpty { return info.name }
        if let p = (reachable + relays + seen).first(where: { $0.address == address }) {
            return p.name
        }
        return HopBearer.shortHex(address)
    }

    /// Resolve a trace hop to a display label: a known node's name (or a relay's domain),
    /// else the carrying-app label + the hop's short address in hex (§27).
    func traceLabel(_ hop: TraceHopInfo) -> String {
        if hop.node == HopBearer.shortData(node.address()) { return "you" }
        if let name = nameByShort[hop.node], !name.isEmpty { return name }
        return "\(hop.appLabel) \(HopBearer.hex(hop.node))"
    }

    /// Drain identify replies and custom service traffic. Identify replies update the
    /// address book (names + relay domains); custom requests get a "not implemented"
    /// reply so callers aren't left hanging (the demo registers no app services yet).
    private func drainServices() {
        for resp in node.takeServiceResponses() {
            if identifyReqs.remove(resp.forRequestId) != nil, resp.status == 0,
               let info = decodeIdentity(body: resp.body) {
                identities[Data(info.address)] = info
                let label = info.name.isEmpty ? HopBearer.shortHex(Data(info.address)) : info.name
                nameByAddr[Data(info.address)] = label
                serviceLog.insert("identify ← \(label) (\(info.kind))", at: 0)
                refresh()
            } else {
                let text = String(data: resp.body, encoding: .utf8) ?? "<\(resp.body.count) bytes>"
                serviceLog.insert("service ← \(resp.status): \(text.prefix(120))", at: 0)
            }
        }
        for req in node.takeServiceRequests() {
            // No custom services registered in the demo yet — reply 501 so the caller
            // gets a definite answer instead of a timeout.
            serviceLog.insert("service → \(req.service)/\(req.method) (501)", at: 0)
            try? node.sendServiceResponse(to: req.from, forRequestId: req.requestId,
                                          status: 501, body: Data())
        }
    }

    /// Use Case A: ask `gateway` to fetch `urlString` on our behalf (sealed to it).
    func fetch(_ urlString: String, via gateway: Peer) {
        _ = try? node.sendHttpRequest(gateway: gateway.address, method: "GET",
                                      url: urlString, body: Data(), maxResp: 64_000)
        httpResults.insert("→ GET \(urlString) via \(gateway.name)", at: 0)
        pump()
    }

    /// Gateway role: fulfill egress HTTP requests from mesh peers if we have internet.
    /// Restricted to HTTPS GET for safety (a real gateway would apply an allowlist).
    private func serveHttpRequests() {
        for r in node.takeHttpRequests() {
            guard r.method.uppercased() == "GET", r.url.hasPrefix("https://"),
                  let url = URL(string: r.url) else {
                try? node.sendHttpResponse(to: r.from, forRequestId: r.requestId,
                                           status: 403, body: Data("blocked".utf8))
                continue
            }
            URLSession.shared.dataTask(with: url) { [weak self] data, resp, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let status = UInt16((resp as? HTTPURLResponse)?.statusCode ?? 502)
                    var body = data ?? Data()
                    if body.count > Int(r.maxResp) { body = body.prefix(Int(r.maxResp)) }
                    try? self.node.sendHttpResponse(to: r.from, forRequestId: r.requestId,
                                                    status: status, body: body)
                    self.pump()
                }
            }.resume()
        }
        for r in node.takeHttpResponses() {
            let text = String(data: r.body, encoding: .utf8) ?? "<\(r.body.count) bytes>"
            httpResults.insert("← HTTP \(r.status): \(text.prefix(400))", at: 0)
        }
    }

    /// The chat for `peer` is on screen: clear its badge and stop counting it.
    func openChat(_ peer: String) { activePeer = peer; unread[peer] = 0 }
    /// The chat closed.
    func closeChat() { activePeer = nil }
    /// Total unread across all peers (for the title badge).
    var totalUnread: Int { unread.values.reduce(0, +) }

    private func refresh() {
        let mine = node.address()
        // Discover peers by browsing the app-level "presence" service. A device may
        // re-publish several presence adverts (one per refresh); collapse to one per
        // address, keeping the nearest hop count — the contact-book logic the
        // protocol no longer carries (DESIGN.md §23).
        // Collapse the many retained presence adverts per publisher: nearest hops for
        // distance, newest advert (max createdAt) for current name/state/platform/app.
        struct Agg { var minHops: UInt8; var newestAt: UInt64; var peer: Peer }
        var agg = [Data: Agg]()
        for p in node.browse(service: HopBearer.presenceService, tag: "") where p.publisher != mine {
            let name = p.title.isEmpty ? HopBearer.shortHex(p.publisher) : p.title
            let parts = p.summary.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let active = parts.indices.contains(0) ? parts[0] != "bg" : true
            let platform = parts.indices.contains(1) ? parts[1] : ""
            let app = parts.indices.contains(2) ? parts[2] : ""
            let hops = agg[p.publisher].map { min($0.minHops, p.hops) } ?? p.hops
            if let ex = agg[p.publisher], p.createdAt < ex.newestAt {
                agg[p.publisher] = Agg(minHops: hops, newestAt: ex.newestAt, peer: ex.peer) // older: just refresh hops
            } else {
                let peer = Peer(address: p.publisher, name: name, hops: hops,
                                active: active, platform: platform, app: app)
                agg[p.publisher] = Agg(minHops: hops, newestAt: p.createdAt, peer: peer)
            }
            nameByAddr[p.publisher] = name
        }
        var byAddr = [Data: Peer]()
        for (addr, a) in agg {
            var peer = a.peer
            peer = Peer(address: addr, name: peer.name, hops: a.minHops,
                        active: peer.active, platform: peer.platform, app: peer.app)
            byAddr[addr] = peer
        }
        reachable = byAddr.values.sorted { ($0.hops, $0.name) < ($1.hops, $1.name) }

        // Accumulate everyone we've ever seen this session into the contact book;
        // those not currently reachable form the "seen" list.
        for (addr, peer) in byAddr { contacts[addr] = peer }
        let here = Set(byAddr.keys)
        seen = contacts.filter { !here.contains($0.key) }
            .map { Peer(address: $0.key, name: $0.value.name, hops: 0) }
            .sorted { $0.name < $1.name }

        // Which contacts we're talking to over a forward-secret session (lock icon).
        secured = Set(contacts.keys.filter { node.isSecured(address: $0) })
        // Which contacts we've learned a live route to from deliveries (§27).
        routed = Set(contacts.keys.filter { node.knowsRoute(address: $0) })

        // Per-transport status — both bearers run at once (DESIGN.md §26). The headline
        // count is the *actual transport-level connections* (what the user means by
        // "linked"), not just handshake-complete Hop links — otherwise a peer that's
        // connected but mid-Noise-handshake shows as zero. The expandable list below
        // shows the identified peers (and notes any still establishing).
        let bleActive = peripheralMgr?.state == .poweredOn || centralMgr?.state == .poweredOn
        // MC keeps its session object even when Wi-Fi is off; trust the real radio (or
        // the presence of live MC links) instead.
        let wifiActive = !wifiBlocked && (wifiUp || !mcPeerByLink.isEmpty)
        let relayActive = (relayConn != nil || relayWS != nil) && relayStatus == "connected"
        let pls = node.peerLinks()
        transports = [
            TransportStatus(id: "Bluetooth", active: bleActive, links: links.count),
            TransportStatus(id: "Wi-Fi", active: wifiActive, links: mcPeerByLink.count),
            TransportStatus(id: "Relay", active: relayActive, links: relayActive ? 1 : 0),
        ]

        // Map each direct neighbour to the transport(s) carrying it (the route).
        var lt = [Data: Set<String>]()
        for pl in pls {
            let t = pl.link < 10_000 ? "BT" : (pl.link < 20_000 ? "Wi-Fi" : "Relay")
            lt[pl.address, default: []].insert(t)
        }
        linkTransports = lt

        // Connected cloud relays (the relay-link peers), named by their region domain via
        // hop.identify (DESIGN.md §29). Shown as their own list section so the backbone is
        // visible alongside device peers.
        relays = pls.filter { $0.link >= 20_000 }.map { pl in
            let name = identities[pl.address]?.name.isEmpty == false
                ? identities[pl.address]!.name
                : (nameByAddr[pl.address] ?? "relay")
            return Peer(address: pl.address, name: name, hops: 1, platform: "cloud", app: "Hop Relay")
        }
        .sorted { $0.name < $1.name }

        // Learn the name/kind of everyone we're directly linked to (the relay's domain,
        // a peer's kind) so traces resolve and relays show by domain (§29).
        for pl in pls { queueIdentify(pl.address) }

        // Index every known full address by its 8-byte short form so trace hops (§27)
        // resolve to display names.
        var ns = [Data: String]()
        for (addr, name) in nameByAddr { ns[HopBearer.shortData(addr)] = name }
        nameByShort = ns

        queue = node.queue().map {
            QueueRow(id: $0.id, own: $0.own,
                     to: $0.to.isEmpty ? "internet" : HopBearer.shortHex($0.to),
                     priority: $0.priority, hops: $0.hops)
        }
        if reachable.count != lastReachLog { NSLog("HOPLOG reachable=\(reachable.count)"); lastReachLog = reachable.count }
        let relayN = queue.filter { !$0.own }.count
        if relayN != lastRelayLog { NSLog("HOPLOG relayQueue=\(relayN) total=\(queue.count)"); lastRelayLog = relayN }

        for i in messages.indices where !messages[i].incoming {
            guard let bid = messages[i].bundleId else { continue }
            let s = node.messageStatus(id: bid)
            messages[i].relayed = s.relayed
            messages[i].deliveryHops = s.deliveryHops
            if s.delivered && messages[i].deliveredAt == nil {
                messages[i].delivered = true
                messages[i].deliveredAt = Date()  // our clock: send→delivered is skew-free
            }
        }
    }

    private func notifyIfBackgrounded(from: String, text: String) {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .active else { return }
        #endif
        let content = UNMutableNotificationContent()
        content.title = from; content.body = text; content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Advertise the service UUID most of the time (so peers can link), pulsing the
    /// iBeacon briefly so it also wakes nearby dormant devices. The two are mutually
    /// exclusive on iOS, so we alternate instead of toggling (§22). Foreground only —
    /// iOS won't advertise the iBeacon in the background regardless.
    private func startAdvertisingCycle() {
        applyAdvertising(beacon: false)
        status = "advertising + wake-beacon (psm \(psm))"
        advTimer?.invalidate()
        advTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.advCounter = (self.advCounter + 1) % 7
            let wantBeacon = self.advCounter >= 5 // ~2s beacon out of every 7s
            if wantBeacon != self.advBeaconNow {
                self.advBeaconNow = wantBeacon
                self.applyAdvertising(beacon: wantBeacon)
            }
        }
    }

    private func applyAdvertising(beacon: Bool) {
        guard let p = peripheralMgr, p.state == .poweredOn else { return }
        p.stopAdvertising()
        if beacon, let data = beaconRegion.peripheralData(withMeasuredPower: nil) as? [String: Any] {
            p.startAdvertising(data)
        } else {
            p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [HopBearer.serviceUUID]])
        }
    }

    static func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    /// Compact elapsed-time label: 3s / 5m / 2h / 4d.
    static func compactDuration(_ ms: UInt64) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
    }
    /// A single link to the destination is "direct" (0 relays); ≥2 shows the count.
    /// Matches the peer-row convention.
    static func hopsLabel(_ h: UInt8) -> String { h <= 1 ? "direct" : "\(h) hops" }
    /// Compact base58 prefix for display (full base58 via `addressBase58`).
    static func shortHex(_ d: Data) -> String { String(addressBase58(address: d).prefix(8)) }
    static func base58(_ d: Data) -> String { addressBase58(address: d) }
    /// The 8-byte short form of a full address — matches what trace hops carry (§27).
    static func shortData(_ d: Data) -> Data { shortAddress(address: d) }
    /// Hex of an arbitrary byte string (for an unresolved short trace hop).
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Peripheral

extension HopBearer: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { didSetupPeripheral = false; return }
        // Set up exactly once per power-on. Republishing on every state callback would
        // mint a new PSM and invalidate the one a central just read (→ "Unknown error").
        guard !didSetupPeripheral else { return }
        didSetupPeripheral = true
        // Clear anything carried over by state restoration (a prior install left a
        // service + L2CAP channel registered) and set up fresh, so we always advertise
        // a valid PSM after a reinstall instead of a stale one (or none).
        peripheral.removeAllServices()
        peripheral.stopAdvertising()
        peripheral.publishL2CAPChannel(withEncryption: false) // → didPublish → add service + advertise
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        status = "restored (peripheral)"
    }

    func peripheralManager(_ p: CBPeripheralManager, didPublishL2CAPChannel psm: CBL2CAPPSM, error: Error?) {
        if let error { status = "publish failed: \(error.localizedDescription)"; return }
        self.psm = psm
        var be = psm.bigEndian
        let value = Data(bytes: &be, count: MemoryLayout<CBL2CAPPSM>.size)
        let char = CBMutableCharacteristic(type: HopBearer.psmCharUUID, properties: [.read],
                                           value: value, permissions: [.readable])
        let service = CBMutableService(type: HopBearer.serviceUUID, primary: true)
        service.characteristics = [char]
        p.add(service)
        startAdvertisingCycle()
    }

    func peripheralManager(_ p: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error {
            let e = error as NSError
            NSLog("HOPLOG accept L2CAP failed: domain=\(e.domain) code=\(e.code) — \(e.localizedDescription)")
            status = "accept L2CAP failed (\(e.code))"
            return
        }
        guard let channel else { return }
        addLink(channel, initiator: false)
    }
}

// MARK: - Central

extension HopBearer: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // Re-adopt peripherals the system still holds connected from a previous
        // install/launch (state restoration). A fresh scan never resurfaces an
        // already-connected peripheral, so without this we'd show no peers until the
        // user force-quits — the reported bug. Re-run discovery to rebuild the link.
        for p in central.retrieveConnectedPeripherals(withServices: [HopBearer.serviceUUID]) {
            retained[p.identifier] = p
            connecting.insert(p.identifier) // scheduleReconnect owns it (not the scan)
            opened.remove(p.identifier)
            p.delegate = self
            central.cancelPeripheralConnection(p) // → didDisconnect → scheduleReconnect (fresh link)
        }
        central.scanForPeripherals(withServices: [HopBearer.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Retain restored peripherals so power-on can re-link them.
        for p in dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [] {
            retained[p.identifier] = p
            p.delegate = self
        }
        status = "restored (central)"
    }

    func centralManager(_ c: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !connecting.contains(peripheral.identifier) else { return }
        connecting.insert(peripheral.identifier)
        retained[peripheral.identifier] = peripheral
        peripheral.delegate = self
        status = "found a device, connecting…"
        c.connect(peripheral)
    }

    func centralManager(_ c: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "connected (GATT), reading PSM…"
        peripheral.discoverServices([HopBearer.serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        scheduleReconnect(peripheral)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        opened.remove(peripheral.identifier)
        status = "peer left — awaiting return…"
        scheduleReconnect(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if error != nil { return recover(peripheral) }
        for s in peripheral.services ?? [] where s.uuid == HopBearer.serviceUUID {
            peripheral.discoverCharacteristics([HopBearer.psmCharUUID], for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if error != nil { return recover(peripheral) }
        for ch in service.characteristics ?? [] where ch.uuid == HopBearer.psmCharUUID {
            peripheral.readValue(for: ch)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil { return recover(peripheral) }
        guard let v = characteristic.value, v.count >= 2 else { return }
        guard !opened.contains(peripheral.identifier) else { return }
        opened.insert(peripheral.identifier)
        let psm = CBL2CAPPSM(UInt16(v[0]) << 8 | UInt16(v[1]))
        l2capPsm[peripheral.identifier] = psm
        l2capAttempts[peripheral.identifier] = 0
        status = "opening L2CAP (psm \(psm))…"
        peripheral.openL2CAPChannel(psm)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if error != nil || channel == nil {
            let e = (error as NSError?)
            NSLog("HOPLOG open L2CAP failed: domain=\(e?.domain ?? "nil") code=\(e?.code ?? -1) — \(e?.localizedDescription ?? "?")")
            // Older radios (e.g. iPhone XR) fail the first open intermittently; retry
            // the same PSM a few times before tearing the connection down.
            let id = peripheral.identifier
            let n = (l2capAttempts[id] ?? 0) + 1
            l2capAttempts[id] = n
            if n <= 3, let psm = l2capPsm[id] {
                status = "L2CAP retry \(n) (psm \(psm))…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, let p = self.retained[id] else { return }
                    p.openL2CAPChannel(psm)
                }
            } else {
                l2capAttempts[id] = nil
                recover(peripheral)
            }
            return
        }
        backoff[peripheral.identifier] = nil // link is up — reset the retry clock
        l2capAttempts[peripheral.identifier] = nil
        addLink(channel!, initiator: true)
    }

    /// Reset a stuck peripheral and let the backoff path re-establish (not in a tight
    /// loop — see `scheduleReconnect`). The XR-class radios fail L2CAP opens
    /// intermittently; hammering them instantly just wedges the connection.
    private func recover(_ peripheral: CBPeripheral) {
        opened.remove(peripheral.identifier)
        centralMgr.cancelPeripheralConnection(peripheral) // → didDisconnect → scheduleReconnect
    }

    /// Re-dial a peripheral after a per-peer backoff with jitter. Without this, a
    /// failing L2CAP open recovers → disconnects → re-dials with no delay, pinning the
    /// CPU/radio in a reconnect storm (the "looping on status" symptom). Backoff grows
    /// 1→2→4…→20s; jitter de-syncs two devices that are dialing each other.
    private func scheduleReconnect(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        retained[id] = peripheral
        guard !reconnectScheduled.contains(id) else { return }
        reconnectScheduled.insert(id)
        let delay = backoff[id] ?? 1.0
        backoff[id] = min(delay * 2, 20.0)
        let jittered = delay + Double.random(in: 0...0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + jittered) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled.remove(id)
            if let p = self.retained[id] { self.centralMgr.connect(p) }
        }
    }
}

// MARK: - Wi-Fi bearer delegates (MultipeerConnectivity)

extension HopBearer: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, mcSession) // accept; role arbitration is on the browser side
    }

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        // Only the lexicographically-smaller address invites, so each pair forms one
        // session with a clear initiator/responder (matches Noise XX roles).
        guard let me = mcPeerID, me.displayName < peerID.displayName, let s = mcSession else { return }
        browser.invitePeer(peerID, to: s, withContext: nil, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("HOPLOG wifi advertise failed: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in self?.wifiBlocked = true; self?.refresh() }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("HOPLOG wifi browse failed: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in self?.wifiBlocked = true; self?.refresh() }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                guard self.mcLinkByPeer[peerID] == nil else { return }
                let id = self.mcNextLinkId; self.mcNextLinkId += 1
                self.mcLinkByPeer[peerID] = id
                self.mcPeerByLink[id] = peerID
                let initiator = (self.mcPeerID?.displayName ?? "") < peerID.displayName
                self.node.connected(link: id, initiator: initiator)
                self.status = "linked (wifi)"
                self.pump()
            case .notConnected:
                if let id = self.mcLinkByPeer[peerID] {
                    self.mcLinkByPeer[peerID] = nil
                    self.mcPeerByLink[id] = nil
                    self.node.disconnected(link: id)
                    self.refresh()
                }
            case .connecting: break
            @unknown default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let id = self.mcLinkByPeer[peerID] else { return }
            self.node.received(link: id, bytes: data)
            self.pump()
        }
    }

    // Unused transfer modes (protocol requires them).
    func session(_ s: MCSession, didReceive stream: InputStream, withName n: String, fromPeer p: MCPeerID) {}
    func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with progress: Progress) {}
    func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at u: URL?, withError e: Error?) {}
}

// MARK: - Location (iBeacon wake)

extension HopBearer: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startMonitoring(for: beaconRegion)
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        NSLog("HOPLOG beacon: entered region — woke")
        backgroundTick()
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        if state == .inside { NSLog("HOPLOG beacon: inside region"); backgroundTick() }
    }
}

// MARK: - Cloud relay (WebSocket)

extension HopBearer: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        relayStatus = "connected"
        node.connected(link: relayLinkId, initiator: true)   // dialer = Noise initiator
        receiveRelayWS()
        pump()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        relayStatus = "disconnected"
        node.disconnected(link: relayLinkId)
        relayWS = nil
        scheduleRelayReconnect()   // re-check-in (§28)
        pump()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === relayWS else { return }
        if let error { relayStatus = "failed: \(error.localizedDescription)" }
        node.disconnected(link: relayLinkId)
        relayWS = nil
        scheduleRelayReconnect()   // re-check-in (§28)
        pump()
    }
}
