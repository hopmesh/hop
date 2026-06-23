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
    /// Longer background-processing task (runs idle/charging) to drain a backlog — e.g. a
    /// large image accumulating across wakes (DESIGN.md §22, §28).
    static let processTaskId = "net.waldrip.hop.process"
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
        var peerAddr: Data? = nil   // the other party's address — stable across renames
        var contentType: String = "text/plain"
        var imageData: Data? = nil  // raw bytes for a single-image message (content_type image/*)
        var images: [Data] = []     // one or more images (a multipart/mixed message)
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
    @Published var endpoints: [Peer] = []   // directly-dialed hops:// endpoints (§30; not relays)
    @Published var hnsCache: [HnsCacheRow] = []   // live HNS cache w/ ticking TTLs (§30, debug)

    /// One HNS cache entry for the debug view: domain → address, with remaining TTL (seconds).
    struct HnsCacheRow: Identifiable {
        var id: String { domain }
        let domain: String
        let address: Data    // empty = a cached negative (no such endpoint)
        let ttl: UInt32      // remaining lifetime, ticking down to expiry
    }
    // hps:// pub/sub — services & channels (§32). Topics we host or subscribe to, and the
    // decrypted, sender-verified messages we've received per path.
    @Published var hpsTopics: [HpsTopic] = []
    @Published var hpsInbox: [HpsMsgRow] = []

    /// An hps:// topic we host (`hosting`) or follow (`subscribed`), keyed by host+path.
    struct HpsTopic: Identifiable {
        var id: String { "\(HopBearer.base58(host))/\(path)" }
        let host: Data        // the node that hosts the topic (us, if hosting)
        let path: String
        let isChannel: Bool   // channel (anyone writes) vs service (only owner broadcasts)
        let hosting: Bool     // true = we registered it; false = we subscribed to it
    }
    /// One received hps:// message, decrypted + sender-verified (§32).
    struct HpsMsgRow: Identifiable {
        let id = UUID()
        let path: String
        let sender: Data
        let text: String
        let at: UInt64
    }

    /// Resolved display name per 8-byte short address, for resolving trace hops (§27/§29).
    @Published var nameByShort: [Data: String] = [:]
    @Published var serviceLog: [String] = []   // hop.identify + custom service-call activity (§29)
    private var identities: [Data: IdentityInfo] = [:]   // address → identify record
    private var identifyAsked = Set<Data>()              // addresses we've sent hop.identify to
    private var identifyReqs = Set<Data>()               // outstanding identify request bundle ids
    @Published var messages: [Message] = []
    /// Latest hops:// result per domain, rendered for the UI ("200 · <body>" or an error).
    @Published var hopsResults: [String: String] = [:]   // domain → rendered text (§30)
    @Published var queue: [QueueRow] = []
    @Published var unread: [String: Int] = [:]   // peer name → unread incoming count
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
    private var lastRelayDialMs: UInt64 = 0    // throttle background reconnect attempts
    private var relayReconnectScheduled = false
    private let relayLinkId: UInt64 = 20_000    // distinct id range from BLE/Wi-Fi
    // Direct WS links to hops:// endpoints (DESIGN.md §30). The client dials the endpoint at
    // wss://<domain> — it does NOT transit our relay (domain traffic stays off the fleet) — so
    // the endpoint authenticates via Noise as its HNS-published address and becomes a direct
    // peer we can seal requests to. Keyed by a distinct link-id range.
    private var endpointWS: [UInt64: URLSessionWebSocketTask] = [:]
    private var endpointLinkByDomain: [String: UInt64] = [:]
    private var nextEndpointLinkId: UInt64 = 30_000
    private var l2capPsm: [UUID: CBL2CAPPSM] = [:]    // last PSM read per peripheral
    private var l2capAttempts: [UUID: Int] = [:]      // L2CAP open retry counter
    private var didSetupPeripheral = false            // peripheral published this power cycle
    private var nameByAddr: [Data: String] = [:]
    private var contacts: [Data: Peer] = [:]   // app-side contact book (address → peer)
    private var userNamed = Set<Data>()        // contacts the user named (identify won't override)
    // hops:// fetches awaiting an HNS resolution: domain → the path to request once the
    // record resolves (DESIGN.md §30).
    private var pendingHops: [String: String] = [:]
    // In-flight hops:// requests: request id → the domain it's for, so a response can be
    // matched back and rendered into `hopsResults`.
    private var hopsReqs: [Data: String] = [:]
    // The hops:// WebView path (DESIGN.md §30): callback-style fetches that feed a WKWebView
    // (the manual `hopsResults` field above is for the text test box only). Request id →
    // completion, and per-domain queues for requests issued before HNS resolves.
    private var hopsWebReqs: [Data: (HopResponse) -> Void] = [:]
    private var hopsWebPending: [String: [(path: String, completion: (HopResponse) -> Void)]] = [:]
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
                guard let self else { return }
                self.wifiUp = path.status == .satisfied && path.usesInterfaceType(.wifi)
                // Declare whether we can reach the public internet (any interface — Wi-Fi,
                // cellular or wired). An internet-connected phone resolves HNS itself by
                // servicing `takeDnsLookups()` in `pump()` (DESIGN.md §30).
                self.node.setInternet(on: path.status == .satisfied)
                self.refresh()
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
        // Reconnect the relay if it dropped (iOS tears the socket down while suspended), so
        // this wake — BGAppRefresh, BGProcessing, or a beacon/BLE event — actually pulls
        // anything queued for us at the relay (DESIGN.md §28). Throttled so the 1s foreground
        // timer can't hammer the dial; "connecting…" is skipped to avoid overlapping dials.
        if relayStatus != "connected" && relayStatus != "connecting…" {
            let now = HopBearer.nowMs()
            if now &- lastRelayDialMs > 4000 {
                lastRelayDialMs = now
                connectRelay(relayURL ?? HopBearer.defaultRelay)
            }
        }
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

    /// Add a contact to the address book by base58 address. An empty `name` falls back to
    /// the address (and hop.identify will fill in the device's own name if it has one); a
    /// provided name is kept as your local alias. Returns false if the address is invalid.
    @discardableResult
    func addContact(name: String, address base58: String) -> Bool {
        let addr = addressFromBase58(text: base58.trimmingCharacters(in: .whitespacesAndNewlines))
        guard addr.count == 32, addr != node.address() else { return false }
        let alias = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = alias.isEmpty ? HopBearer.shortHex(addr) : alias
        nameByAddr[addr] = label
        contacts[addr] = Peer(address: addr, name: label, hops: 0)
        if alias.isEmpty {
            queueIdentify(addr)   // resolve their device name if they set one
        } else {
            userNamed.insert(addr) // keep my alias
        }
        pump()
        return true
    }

    /// Clear the relay queue (our undelivered messages + bundles held for peers).
    func clearQueue() {
        node.clearQueue()
        pump()
    }

    func send(_ text: String, to peer: Peer) {
        let id = try? node.sendMessage(dst: peer.address,
                                       contentType: "text/plain; charset=utf-8", body: Data(text.utf8),
                                       requestAck: true)
        messages.append(Message(peer: peer.name, text: text, incoming: false,
                                peerAddr: peer.address, bundleId: id))
        pump()
    }

    /// Send an image. It's just a message with an image content type and the raw bytes as
    /// the body — the core auto-streams it in chunks if it's too big for one bundle, and
    /// the far side reassembles it back into one message (DESIGN.md §20).
    func sendImage(_ data: Data, to peer: Peer) {
        let id = try? node.sendMessage(dst: peer.address,
                                       contentType: "image/jpeg", body: data,
                                       requestAck: true)
        messages.append(Message(peer: peer.name, text: "", incoming: false,
                                peerAddr: peer.address, contentType: "image/jpeg",
                                imageData: data, bundleId: id))
        pump()
    }

    /// Send text and/or one-or-more images as ONE message (`multipart/mixed`) — a single sealed
    /// payload, carrier-chunked + reassembled like any message (DESIGN.md §20). The wire format
    /// is shared with Android: `[u32 partCount][ per part: u16 ctLen, ct, u32 bodyLen, body ]`.
    func sendMultipart(text: String, images: [Data], to peer: Peer) {
        var parts: [(String, Data)] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(("text/plain", Data(trimmed.utf8))) }
        for img in images { parts.append(("image/jpeg", img)) }
        guard !parts.isEmpty else { return }
        let body = HopBearer.encodeMultipart(parts)
        let id = try? node.sendMessage(dst: peer.address,
                                       contentType: "multipart/mixed", body: body, requestAck: true)
        messages.append(Message(peer: peer.name, text: trimmed, incoming: false,
                                peerAddr: peer.address, contentType: "multipart/mixed",
                                images: images, bundleId: id))
        pump()
    }

    /// Encode `(contentType, bytes)` parts into the shared multipart wire format.
    static func encodeMultipart(_ parts: [(String, Data)]) -> Data {
        var out = Data()
        var count = UInt32(parts.count).bigEndian
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
        for (ct, body) in parts {
            let ctd = Data(ct.utf8)
            var cl = UInt16(ctd.count).bigEndian
            withUnsafeBytes(of: &cl) { out.append(contentsOf: $0) }
            out.append(ctd)
            var bl = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &bl) { out.append(contentsOf: $0) }
            out.append(body)
        }
        return out
    }

    /// Decode the shared multipart wire format into `(contentType, bytes)` parts.
    static func decodeMultipart(_ data: Data) -> [(String, Data)] {
        let b = [UInt8](data)
        var i = 0
        func u(_ n: Int) -> Int? {
            guard i + n <= b.count else { return nil }
            var v = 0
            for _ in 0..<n { v = (v << 8) | Int(b[i]); i += 1 }
            return v
        }
        var parts: [(String, Data)] = []
        guard let count = u(4) else { return [] }
        for _ in 0..<count {
            guard let cl = u(2), i + cl <= b.count else { break }
            let ct = String(decoding: b[i..<i + cl], as: UTF8.self); i += cl
            guard let bl = u(4), i + bl <= b.count else { break }
            parts.append((ct, Data(b[i..<i + bl]))); i += bl
        }
        return parts
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

    /// Open (or reuse) a direct WS link to a hops:// endpoint at `wss://<domain>/` (DESIGN.md
    /// §30). The endpoint authenticates via Noise as its HNS-published address, becoming a
    /// direct peer; the sealed hops request then delivers straight to it. Returns the link id.
    @discardableResult
    private func dialEndpoint(_ domain: String) -> UInt64 {
        if let id = endpointLinkByDomain[domain], endpointWS[id] != nil { return id }
        let id = nextEndpointLinkId; nextEndpointLinkId += 1
        endpointLinkByDomain[domain] = id
        guard let url = URL(string: "wss://\(domain)/") else { return id }
        let session = relaySession ?? URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        relaySession = session
        let task = session.webSocketTask(with: url)
        endpointWS[id] = task
        task.resume()   // node.connected fires in didOpenWithProtocol (we're the initiator)
        receiveEndpoint(id)
        return id
    }

    private func receiveEndpoint(_ id: UInt64) {
        endpointWS[id]?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .data(let d) = message {
                    DispatchQueue.main.async { self.node.received(link: id, bytes: d); self.pump() }
                }
                self.receiveEndpoint(id)
            case .failure:
                DispatchQueue.main.async {
                    self.node.disconnected(link: id); self.endpointWS[id] = nil; self.pump()
                }
            }
        }
    }

    /// The endpoint link id whose WS task is `task`, if any (used by the URLSession delegate).
    private func endpointLink(for task: URLSessionTask) -> UInt64? {
        endpointWS.first(where: { $0.value === task })?.key
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
            } else if let ws = endpointWS[pkt.link] {
                ws.send(.data(pkt.bytes)) { _ in }         // direct hops:// endpoint link (§30)
            }
        }
        refresh()
        for m in node.takeInbox() {
            let who = nameByAddr[m.from] ?? HopBearer.shortHex(m.from)
            let isImage = m.contentType.hasPrefix("image/")
            let isMultipart = m.contentType == "multipart/mixed"
            var text = isImage ? "" : (String(data: m.body, encoding: .utf8) ?? "<\(m.body.count) bytes>")
            var images: [Data] = []
            if isMultipart {
                let parts = HopBearer.decodeMultipart(m.body)
                text = parts.first(where: { $0.0.hasPrefix("text/") })
                    .flatMap { String(data: $0.1, encoding: .utf8) } ?? ""
                images = parts.filter { $0.0.hasPrefix("image/") }.map { $0.1 }
            }
            let now = HopBearer.nowMs()
            let latency = now >= m.createdAt ? now - m.createdAt : 0  // clamp clock skew
            messages.append(Message(peer: who, text: text, incoming: true,
                                    peerAddr: m.from, contentType: m.contentType,
                                    imageData: isImage ? m.body : nil, images: images,
                                    hops: m.hops, latencyMs: latency, trace: m.trace))
            // A sender that isn't in our nearby/contacts must still be reachable in the UI,
            // or the message vanishes. Make them a contact (so a row + chat exist) and run
            // hop.identify to resolve their name (their input, or their id if unset, §29).
            if contacts[m.from] == nil {
                contacts[m.from] = Peer(address: m.from, name: who, hops: m.hops)
            }
            queueIdentify(m.from)
            if who != activePeer { unread[who, default: 0] += 1 }  // badge unless viewing
            notifyIfBackgrounded(from: who, text: text)
        }
        drainServices()      // hop.identify replies + custom service calls (§29)
        drainHns()           // HNS lookups + hops:// responses (§30)
        drainHps()           // pub/sub messages (§32)
    }

    // MARK: - hps:// pub/sub (DESIGN.md §32)

    /// Host a new topic at `path`: a channel (anyone with the key reads + writes) or a service
    /// (only we broadcast). Keys are minted + persisted in the node. Returns the service public
    /// key for a service (empty for a channel).
    @discardableResult
    func hpsRegister(path: String, channel: Bool) -> Data {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return Data() }
        let pk = node.registerService(path: p, kind: channel ? .channel : .service)
        if !hpsTopics.contains(where: { $0.host == node.address() && $0.path == p }) {
            hpsTopics.insert(HpsTopic(host: node.address(), path: p, isChannel: channel, hosting: true), at: 0)
        }
        return pk
    }

    /// Subscribe to `hps://{hostBase58}/{path}` — request the topic's keys from its host. The
    /// host (if open) replies with the keys; messages then arrive in `hpsInbox`.
    func hpsSubscribe(hostBase58: String, path: String) {
        let host = addressFromBase58(text: hostBase58.trimmingCharacters(in: .whitespacesAndNewlines))
        let p = path.trimmingCharacters(in: .whitespaces)
        guard host.count == 32, !p.isEmpty else { return }
        _ = try? node.hpsSubscribe(host: host, path: p)
        // We don't yet know the kind until keys arrive; default to channel (the host's reply
        // carries the service pubkey, which governs publish rights on the core side).
        if !hpsTopics.contains(where: { $0.host == host && $0.path == p }) {
            hpsTopics.insert(HpsTopic(host: host, path: p, isChannel: true, hosting: false), at: 0)
        }
        pump()
    }

    /// Publish text to a topic we host or (for a channel) belong to. Floods to all subscribers.
    func hpsPublish(path: String, text: String) {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, let body = text.data(using: .utf8) else { return }
        _ = try? node.hpsPublish(path: p, body: body)
        // Echo our own post locally — broadcasts don't loop back to the sender.
        hpsInbox.insert(HpsMsgRow(path: p, sender: node.address(), text: text, at: HopBearer.nowMs()), at: 0)
        pump()
    }

    /// Drain received pub/sub messages into the inbox (already decrypted + sender-verified).
    private func drainHps() {
        for m in node.takeHpsMessages() {
            let text = String(data: m.body, encoding: .utf8) ?? "<\(m.body.count) bytes>"
            hpsInbox.insert(HpsMsgRow(path: m.path, sender: m.sender, text: text, at: HopBearer.nowMs()), at: 0)
            if hpsInbox.count > 200 { hpsInbox.removeLast(hpsInbox.count - 200) }
            queueIdentify(m.sender)   // learn the sender's display name
        }
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
                let addr = Data(info.address)
                let label = info.name.isEmpty ? HopBearer.shortHex(addr) : info.name
                // Keep the contact's display name in sync (the chat is keyed by address,
                // so renames are safe) — this is how an unknown sender gets its real name.
                // A contact the user named locally keeps that alias.
                if !userNamed.contains(addr) {
                    nameByAddr[addr] = label
                }
                if let c = contacts[addr], !userNamed.contains(addr) {
                    contacts[addr] = Peer(address: addr, name: label, hops: c.hops,
                                          active: c.active, platform: c.platform, app: c.app)
                }
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

    // Open-web HTTP fetch via a third-party gateway was removed: a gateway that fetches
    // https:// on your behalf terminates TLS = a MitM (DESIGN.md §25). The model is now
    // origin-run gateways reached via `hops://<domain>` (the gateway serves *its own*
    // service over the mesh, no third party in the middle).

    // MARK: - HNS & hops:// (DESIGN.md §30)

    /// Open a `hops://<domain>/<path>` URL (a bare `<domain>` is also accepted). Resolves
    /// the domain to its hops endpoint address via the Hop Name System, then sends a GET
    /// over the mesh. The endpoint validates `host`, so we always pass the bare domain.
    func openHops(_ urlString: String) {
        let (domain, path) = Self.parseHops(urlString)
        guard !domain.isEmpty else {
            hopsResults["?"] = "error: not a hops:// url"
            return
        }
        hopsResults[domain] = "resolving…"
        switch node.resolveHns(domain: domain) {
        case .cached(let address):
            if address.isEmpty {
                // A cached negative — the domain has no `_hopaddress` record.
                hopsResults[domain] = "error: no hops endpoint for \(domain)"
            } else {
                fireHops(domain: domain, path: path, endpoint: address)
            }
        case .pending:
            // A lookup was kicked off — either our own DNS (if we have internet) or, if not,
            // a query broadcast to our connected peers (a nearby internet phone/relay resolves
            // it). Fire the request when its record lands in `takeHnsResults()`.
            pendingHops[domain] = path
        case .needsResolver:
            // Genuinely isolated: no internet AND no connected peers to resolve through.
            hopsResults[domain] = "error: offline — no internet or peers to resolve \(domain)"
        }
        pump()
    }

    /// Issue the sealed hops:// GET to a resolved endpoint and remember the request id so
    /// the response can be matched back (DESIGN.md §30).
    private func fireHops(domain: String, path: String, endpoint: Data) {
        // We learned domain↔address from HNS, so label the endpoint by its domain right away
        // (no need to wait for a hop.identify round-trip) — shows in the endpoints list + traces.
        nameByAddr[endpoint] = domain
        // Open a direct link to the endpoint (wss://<domain>) so the sealed request has a path
        // to it — the endpoint doesn't transit our relay (§30). Spray-and-wait holds the
        // bundle and delivers it the moment the Noise handshake on this link completes.
        dialEndpoint(domain)
        guard let id = try? node.sendHopsRequest(endpoint: endpoint, host: domain,
                                                 method: "GET", url: path,
                                                 body: Data(), maxResp: 8 * 1024 * 1024) else {
            hopsResults[domain] = "error: could not send request to \(domain)"
            return
        }
        hopsReqs[id] = domain
        hopsResults[domain] = "fetching…"
        pump()
    }

    // MARK: - hops:// for the WebView (callback-style, per-resource)

    /// One hops:// HTTP response handed to the WebView's scheme handler.
    struct HopResponse {
        let status: Int
        let contentType: String
        let body: Data
    }

    /// Fetch a single hops:// resource (the WebView's document or any sub-resource) and call
    /// `completion` when the sealed response returns over the mesh. Resolves the domain via
    /// HNS (cached after the first hit, so sub-resources fire immediately), dials the endpoint
    /// if needed, and times out gracefully. Drives everything on the main queue.
    func hopsFetch(domain: String, path: String, completion: @escaping (HopResponse) -> Void) {
        guard !domain.isEmpty else {
            completion(HopResponse(status: 400, contentType: "text/plain; charset=utf-8", body: Data("bad hops url".utf8)))
            return
        }
        switch node.resolveHns(domain: domain) {
        case .cached(let address):
            if address.isEmpty {
                completion(HopResponse(status: 502, contentType: "text/plain; charset=utf-8",
                                       body: Data("no hops endpoint for \(domain)".utf8)))
            } else {
                fireHopsWeb(domain: domain, path: path, endpoint: address, completion: completion)
            }
        case .pending:
            // Our own DNS, or (no internet) a query broadcast to connected peers (§30).
            hopsWebPending[domain, default: []].append((path, completion))
        case .needsResolver:
            completion(HopResponse(status: 503, contentType: "text/plain; charset=utf-8",
                                   body: Data("offline — no internet or peers to resolve \(domain)".utf8)))
        }
        pump()
    }

    private func fireHopsWeb(domain: String, path: String, endpoint: Data,
                             completion: @escaping (HopResponse) -> Void) {
        nameByAddr[endpoint] = domain   // label by domain from HNS (no identify needed)
        dialEndpoint(domain)   // direct link to the endpoint (§30)
        guard let id = try? node.sendHopsRequest(endpoint: endpoint, host: domain,
                                                 method: "GET", url: path,
                                                 body: Data(), maxResp: 8 * 1024 * 1024) else {
            completion(HopResponse(status: 502, contentType: "text/plain; charset=utf-8",
                                   body: Data("could not send request".utf8)))
            return
        }
        hopsWebReqs[id] = completion
        // Fail gracefully if nothing comes back (the request is still held & retried by the
        // node, but the WebView shouldn't spin forever).
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, let done = self.hopsWebReqs.removeValue(forKey: id) else { return }
            done(HopResponse(status: 504, contentType: "text/plain; charset=utf-8",
                             body: Data("hops timeout for \(domain)\(path)".utf8)))
        }
        pump()
    }

    /// Split `hops://<domain>/<path>` (or a bare `<domain>`) into (domain, path). The path
    /// defaults to "/" and is path+query only — what `sendHopsRequest` expects.
    private static func parseHops(_ raw: String) -> (domain: String, path: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "hops://") { s.removeSubrange(s.startIndex..<r.upperBound) }
        guard let slash = s.firstIndex(of: "/") else { return (s, "/") }
        let domain = String(s[s.startIndex..<slash])
        let path = String(s[slash...])
        return (domain, path.isEmpty ? "/" : path)
    }

    /// Drain finished HNS resolutions (firing any queued hops:// fetch) and hops:// HTTP
    /// responses (matching them back to the in-flight request). The core caches records,
    /// so we keep no extra cache here. Also service the host DNS hook: any `_hopaddress`
    /// TXT lookups the node needs are resolved over DNS-over-HTTPS off the main queue and
    /// fed back via `provideDnsAnswer` (DESIGN.md §30).
    private func drainHns() {
        for rec in node.takeHnsResults() {
            // The manual text-box fetch (one path per domain).
            if let path = pendingHops.removeValue(forKey: rec.domain) {
                if rec.address.isEmpty {
                    hopsResults[rec.domain] = "error: no hops endpoint for \(rec.domain)"
                } else {
                    fireHops(domain: rec.domain, path: path, endpoint: rec.address)
                }
            }
            // WebView fetches queued on this domain's resolution (may be several).
            if let queued = hopsWebPending.removeValue(forKey: rec.domain) {
                for (path, completion) in queued {
                    if rec.address.isEmpty {
                        completion(HopResponse(status: 502, contentType: "text/plain; charset=utf-8",
                                               body: Data("no hops endpoint for \(rec.domain)".utf8)))
                    } else {
                        fireHopsWeb(domain: rec.domain, path: path, endpoint: rec.address,
                                    completion: completion)
                    }
                }
            }
        }
        for resp in node.takeHttpResponses() {
            // WebView completion (per-resource) takes priority over the text box.
            if let completion = hopsWebReqs.removeValue(forKey: resp.forRequestId) {
                completion(HopResponse(status: Int(resp.status),
                                       contentType: resp.contentType, body: resp.body))
                continue
            }
            guard let domain = hopsReqs.removeValue(forKey: resp.forRequestId) else { continue }
            let text = String(data: resp.body, encoding: .utf8) ?? "<\(resp.body.count) bytes>"
            hopsResults[domain] = "\(resp.status) · \(text)"
        }
        // Host DNS hook (DESIGN.md §30): for each domain the node wants resolved, fetch its
        // full DNSSEC chain over DoH and hand core the raw response bodies — core validates the
        // chain to the root anchors and decides the address; the app never does.
        for domain in node.takeDnsLookups() {
            fetchDnssecChain(domain)
        }
    }

    /// Fetch a domain's full DNSSEC chain over DNS-over-HTTPS and feed the raw JSON bodies to
    /// core via `provideDnsProof`: the `_hopaddress.<domain>` TXT plus DNSKEY + DS for every
    /// zone up to the root, all with `do=1`. Runs the GETs concurrently, then marshals back to
    /// the main queue (where the node is driven) once they're all in.
    private func fetchDnssecChain(_ domain: String) {
        // The DoH queries: TXT for the record, then DNSKEY+DS for each zone up to root.
        var queries: [(String, Int)] = [("_hopaddress.\(domain)", 16)]
        var zone = domain
        while true {
            queries.append((zone, 48)) // DNSKEY
            if zone == "." { break }
            queries.append((zone, 43)) // DS
            zone = zone.contains(".") ? String(zone[zone.index(after: zone.firstIndex(of: ".")!)...]) : "."
        }

        let group = DispatchGroup()
        var bodies: [String] = []
        let lock = NSLock()
        for (name, qtype) in queries {
            guard let url = URL(string: "https://dns.google/resolve?name=\(name)&type=\(qtype)&do=1") else { continue }
            group.enter()
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data, let body = String(data: data, encoding: .utf8) {
                    lock.lock(); bodies.append(body); lock.unlock()
                }
                group.leave()
            }.resume()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.node.provideDnsProof(domain: domain, bodies: bodies)
            self.pump()
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

        // Connected cloud relays (the relay-link range 20_000–29_999), named by their region
        // domain via hop.identify (§29). Endpoints (≥30_000) are NOT relays — they're dialed
        // directly and never join the backbone (§30) — so they're listed separately below.
        relays = pls.filter { (20_000..<30_000).contains($0.link) }.map { pl in
            let name = identities[pl.address]?.name.isEmpty == false
                ? identities[pl.address]!.name
                : (nameByAddr[pl.address] ?? HopBearer.shortHex(pl.address))
            return Peer(address: pl.address, name: name, hops: 1, platform: "cloud", app: "Hop Relay")
        }
        .sorted { $0.name < $1.name }

        // Connected hops:// endpoints (the directly-dialed origin links, ≥30_000). These are
        // not part of the relay backbone; we reach them straight (DESIGN.md §30). Named by the
        // domain they back via hop.identify.
        endpoints = pls.filter { $0.link >= 30_000 }.map { pl in
            let name = identities[pl.address]?.name.isEmpty == false
                ? identities[pl.address]!.name
                : (nameByAddr[pl.address] ?? HopBearer.shortHex(pl.address))
            return Peer(address: pl.address, name: name, hops: 1, platform: "cloud", app: "hops endpoint")
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
        // Live HNS cache snapshot (ticks down each refresh as the node clock advances, §30).
        hnsCache = node.hnsCache().map {
            HnsCacheRow(domain: $0.domain, address: $0.address, ttl: $0.ttlSecs)
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
        // CoreBluetooth raises an NSAssertion (→ SIGABRT) if openL2CAPChannel is
        // called on a peripheral that isn't connected. The peripheral can drop
        // between readValue and this callback, so verify state before opening.
        guard peripheral.state == .connected else { return recover(peripheral) }
        guard !opened.contains(peripheral.identifier) else { return }
        opened.insert(peripheral.identifier)
        let psm = CBL2CAPPSM(UInt16(v[0]) << 8 | UInt16(v[1]))
        l2capPsm[peripheral.identifier] = psm
        l2capAttempts[peripheral.identifier] = 0
        status = "opening L2CAP (psm \(psm))…"
        openL2CAP(peripheral, psm)
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
                    // Peripheral may have dropped during the retry delay; openL2CAPChannel
                    // asserts (→ crash) if it isn't connected.
                    guard p.state == .connected else { self.recover(p); return }
                    self.openL2CAP(p, psm)
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

    /// Open an L2CAP channel without crashing. CoreBluetooth raises an
    /// uncatchable (from Swift) NSException via NSAssert when the peripheral is in
    /// a transient bad state at the moment of the call — the `.connected` guard
    /// closes the common window but not every race. Route any thrown exception to
    /// `recover()` so a bad handshake retries instead of aborting the process.
    private func openL2CAP(_ peripheral: CBPeripheral, _ psm: CBL2CAPPSM) {
        do {
            try HopObjCExceptionCatcher.run { peripheral.openL2CAPChannel(psm) }
        } catch {
            NSLog("HOPLOG openL2CAPChannel threw: \(error.localizedDescription) — recovering")
            recover(peripheral)
        }
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
        if let id = endpointLink(for: webSocketTask) {   // a hops:// endpoint link (§30)
            node.connected(link: id, initiator: true)    // dialer = Noise initiator
            pump()
            return
        }
        relayStatus = "connected"
        node.connected(link: relayLinkId, initiator: true)   // dialer = Noise initiator
        receiveRelayWS()
        pump()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if let id = endpointLink(for: webSocketTask) {
            node.disconnected(link: id); endpointWS[id] = nil; pump()
            return
        }
        relayStatus = "disconnected"
        node.disconnected(link: relayLinkId)
        relayWS = nil
        scheduleRelayReconnect()   // re-check-in (§28)
        pump()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let id = endpointLink(for: task) {
            node.disconnected(link: id); endpointWS[id] = nil; pump()
            return
        }
        guard task === relayWS else { return }
        if let error { relayStatus = "failed: \(error.localizedDescription)" }
        node.disconnected(link: relayLinkId)
        relayWS = nil
        scheduleRelayReconnect()   // re-check-in (§28)
        pump()
    }
}
