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
    // GATT-data fallback (cross-platform, when L2CAP can't open — esp. Apple→Android): central
    // WRITEs frames here, peripheral INDICATEs frames back. Both acked → reliable, ordered.
    static let dataCharUUID = CBUUID(string: "F0900002-0000-4000-8000-000000000000")
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
        let address: Data; let name: String; var hops: UInt8
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
        var failed: Bool = false   // gave up (e.g. the queue was cleared before it sent)
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
    /// Privacy: when on, we stop broadcasting our presence advert (name + address), so we don't
    /// show up by name in others' nearby lists. We stay fully relay-capable and reachable by anyone
    /// who already has our address (e.g. via a scanned QR / manual add). Persisted.
    @Published var privateMode: Bool = UserDefaults.standard.bool(forKey: "hop.privateMode") {
        didSet {
            UserDefaults.standard.set(privateMode, forKey: "hop.privateMode")
            if privateMode { retractPresence() } else { publishPresence() }
        }
    }
    @Published var idNote = ""   // identity persistence outcome (diagnostic)
    @Published var status = "starting…" { didSet { NSLog("HOPLOG status: \(status)") } }
    @Published var reachable: [Peer] = []   // discovered now (direct + mesh)
    @Published var seen: [Peer] = []        // historical, not currently reachable
    @Published var secured: Set<Data> = []  // addresses we have a forward-secret session with
    @Published var routed: Set<Data> = []   // addresses we've learned a live route to (§27)
    @Published var transports: [TransportStatus] = []  // per-bearer status (all run at once)
    @Published var relayStatus = "not connected"        // cloud relay link state
    /// A relay the user pinned by direct address (persisted). A device only ever talks to ONE
    /// relay — routing is anycast — so pinning overrides the default anycast target for testing
    /// a specific relay, rather than publishing presence to several at once.
    @Published var pinnedRelay: String? = UserDefaults.standard.string(forKey: "hop.pinnedRelay")
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
    // hps:// pub/sub — services & channels (§32). Topics we host or subscribe to, the messages
    // per topic (one thread each), per-topic unread, and invites we've received.
    @Published var hpsTopics: [HpsTopic] = []
    @Published var hpsThreads: [String: [HpsMsgRow]] = [:] { didSet { scheduleChannelSave() } }   // topic id → its messages
    @Published var hpsUnread: [String: Int] = [:]            // topic id → unread count
    @Published var hpsInvites: [HpsInvite] = []              // invites received (FFI record)
    var activeTopic: String?                                 // topic on screen (not counted)

    /// An hps:// topic we host (`hosting`) or follow (`subscribed`), keyed by host+path.
    struct HpsTopic: Identifiable {
        var id: String { "\(HopBearer.base58(host))/\(path)" }
        let host: Data        // the node that hosts the topic (us, if hosting)
        let path: String
        let isChannel: Bool   // channel (anyone writes) vs service (only owner broadcasts)
        let hosting: Bool     // true = we registered it; false = we subscribed to it
        var access: HpsAccess = .open   // key-handoff policy (for topics we host)
        /// Whether we can post: a channel (anyone), or a service we host.
        var writable: Bool { isChannel || hosting }
    }
    /// One received hps:// message, decrypted + sender-verified (§32).
    struct HpsMsgRow: Identifiable, Codable {
        var id = UUID()
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
    @Published var messages: [Message] = [] { didSet { scheduleMessageSave() } }
    /// Latest hops:// result per domain, rendered for the UI ("200 · <body>" or an error).
    @Published var hopsResults: [String: String] = [:]   // domain → rendered text (§30)
    @Published var queue: [QueueRow] = []
    @Published var unread: [String: Int] = [:] { didSet { updateAppBadge() } }   // peer name → unread incoming count
    private var activePeer: String?              // chat currently on screen (not counted)
    private var loadingMessages = false          // suppress save while restoring history
    private var messageSaveWork: DispatchWorkItem?  // debounced history write
    private var channelSaveWork: DispatchWorkItem?  // debounced channel-thread write

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
        // The app secret isolates this app's hps:// channels/services from other apps
        // (DESIGN.md §32): only apps built with the same secret can discover/join them.
        return HopNode.open(dbPath: dbPath, secret: IdentityStore.deviceSeed(),
                            appSecret: HopBearer.appSecret)
    }()

    /// Shared app secret for Hop Debug — all our demo devices use it so they interoperate.
    /// A different app (different secret) can't see or join these channels. To test cross-app
    /// isolation, change this on one device.
    static let appSecret = Data(repeating: 0x48, count: 32) // "H" ×32 — dev build only
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
    // LAN bearer (mDNS/Bonjour + TCP) — the cross-platform high-bandwidth Wi-Fi path. We both
    // advertise a `_hoplan._tcp` service (instance name = our base58 address) AND browse for peers'
    // services; to avoid forming two links per pair, only the device with the lexicographically
    // lower base58 address dials — the higher one accepts. Works iOS↔iOS, iOS↔Android, Android↔
    // Android (plain TCP, unlike Apple-only MultipeerConnectivity/AWDL). Distinct link-id range.
    private var lanListener: NWListener?
    private var lanBrowser: NWBrowser?
    private var lanLinks: [UInt64: LanLink] = [:]
    private var lanLinkInitiator: [UInt64: Bool] = [:]   // pending node.connected role per link
    private var lanDialed: [String: UInt64] = [:]        // peer base58 → our outbound link id (dedup)
    private var lanNextLinkId: UInt64 = 40_000
    private static let lanServiceType = "_hoplan._tcp"
    private var l2capPsm: [UUID: CBL2CAPPSM] = [:]    // last PSM read per peripheral
    private var l2capAttempts: [UUID: Int] = [:]      // L2CAP open retry counter
    private var didSetupPeripheral = false            // peripheral published this power cycle
    // GATT-data fallback bearer.
    private var peripheralDataChar: CBMutableCharacteristic?
    private var gattLinks: [UInt64: GattDataLink] = [:]          // all GATT-data links (central + peripheral)
    private var gattLinkCentral: [UInt64: CBCentral] = [:]       // peripheral side: link → subscribed central
    private var gattLinkPeripheral: [UInt64: CBPeripheral] = [:] // central side: link → remote peripheral
    private var gattDataCharFor: [UUID: CBCharacteristic] = [:]  // central side: peripheral id → its DATA char
    private var centralGattLink: [UUID: UInt64] = [:]            // peripheral side: central id → link
    private var peripheralBackpressure: [UInt64: Data] = [:]     // peripheral side: chunk awaiting isReady
    private var nextGattLinkId: UInt64 = 60_000
    private var nameByAddr: [Data: String] = [:]
    private var contacts: [Data: Peer] = [:]   // app-side contact book (address → peer)
    /// Our own raw 32-byte address (for marking our own hps posts).
    var myAddressData: Data { node.address() }
    /// Contacts as a sorted list (for the invite picker).
    var contactList: [Peer] { contacts.values.sorted { $0.name.lowercased() < $1.name.lowercased() } }
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
        loadMessages()   // restore chat history from the previous run
        loadContacts()   // restore the address book so past conversations are reachable when offline
        loadChannels()   // restore channel (hps) message threads
        loadHpsTopics()  // restore hosted/subscribed channels (the node persists them)
        myName = name
        node.setName(name: name)   // what hop.identify reports for us (§29)
        // Set the node clock to real time BEFORE publishing any adverts. The node starts at
        // now_ms=0, and the first tick (1s away on the timer) runs directory.expire() — so a
        // prekey/presence advert stamped created_at=0 here would be judged expired (1970 + TTL)
        // and dropped instantly. Presence re-publishes every 20 ticks and recovers, but the
        // prekey is published once: without this, peers never learn our prekey, no forward-secret
        // session ever forms, and every message defers forever ("Sending…"). (DESIGN.md §25)
        node.tick(nowMs: HopBearer.nowMs())
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
        // checked in by auto-reconnecting on drop/foreground (DESIGN.md §28). If the user
        // pinned a specific relay, use that single endpoint instead of the anycast default.
        connectRelay(pinnedRelay ?? HopBearer.defaultRelay)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        #if canImport(UIKit)
        // Re-publish presence with our foreground/background state on each transition
        // (iOS suspends us shortly after backgrounding, so the "bg" advert is our last
        // word until we return — peers show that as our state).
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appActive = true; self?.publishPresence(); self?.restartWiFi(); self?.restartLan()
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
        startLan()

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
        guard !privateMode else { return }   // private: don't broadcast our name/address
        // summary carries app-level metadata: "state|platform|app".
        let meta = "\(appActive ? "fg" : "bg")|ios|\(HopBearer.appName)"
        _ = try? node.publishService(service: HopBearer.presenceService,
                                     title: myName, summary: meta, tags: [],
                                     ttlMs: HopBearer.presenceTtlMs)
    }

    /// Supersede our live presence with a near-instantly-expiring one so peers drop our name now
    /// (rather than waiting out the old advert's TTL) when we switch to private.
    private func retractPresence() {
        let meta = "\(appActive ? "fg" : "bg")|ios|\(HopBearer.appName)"
        _ = try? node.publishService(service: HopBearer.presenceService,
                                     title: myName, summary: meta, tags: [], ttlMs: 1000)
        pump()
    }

    func backgroundTick() {
        node.tick(nowMs: HopBearer.nowMs())
        tickCount += 1
        // Refresh presence periodically so it never lapses its TTL (link-up gossip
        // also shares it to new neighbours immediately).
        if tickCount % 20 == 0 { publishPresence() }
        // Re-publish our prekey periodically so a neighbour whose cached copy lapsed (or who
        // arrived after ours did) can always open a forward-secret session to us (§25).
        if tickCount % 120 == 0 { _ = try? node.publishPrekey() }
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
        maintainGattLinks()
        pump()
    }

    /// Keepalive + reaping for GATT-data links (the bearer drives these; GattDataLink has no timer
    /// of its own). Reap a half-open link (subscribed but never delivered a frame) or one silent
    /// past the liveness window; otherwise send an empty keepalive frame.
    private func maintainGattLinks() {
        guard !gattLinks.isEmpty else { return }
        for (id, link) in gattLinks {
            if link.isHalfOpen || link.idle > 20 {
                NSLog("HOPLOG GATT-data link reaped id=\(id)")
                closeGattLink(id)
            } else {
                link.send(Data())  // keepalive
            }
        }
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
        saveContacts(force: true)
        pump()
        return true
    }

    /// Clear the relay queue (our undelivered messages + bundles held for peers).
    /// Anything of ours still in flight is now abandoned, so mark those bubbles "not sent"
    /// instead of leaving them stuck on "Sending…".
    func clearQueue() {
        node.clearQueue()
        for i in messages.indices where !messages[i].incoming && !messages[i].delivered {
            messages[i].failed = true
        }
        pump()
    }

    func send(_ text: String, to peer: Peer) {
        rememberContact(peer)   // messaging someone adds them to your address book
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
        rememberContact(peer)
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

    /// Re-send a failed ("Not sent") message in place — rebuilds the same payload from its
    /// content type and dispatches fresh, so the node defers/ratchets + tracks delivery again.
    /// Recovery for a message that gave up (queue cleared, or still unsent at a restart).
    func retry(_ m: Message) {
        guard !m.incoming, let addr = m.peerAddr else { return }
        let body: Data
        let ct: String
        switch m.contentType {
        case let c where c.hasPrefix("image/"):
            guard let d = m.imageData else { return }
            body = d; ct = "image/jpeg"
        case "multipart/mixed":
            var parts: [(String, Data)] = []
            if !m.text.isEmpty { parts.append(("text/plain", Data(m.text.utf8))) }
            for img in (m.imageData.map { [$0] } ?? m.images) { parts.append(("image/jpeg", img)) }
            guard !parts.isEmpty else { return }
            body = HopBearer.encodeMultipart(parts); ct = "multipart/mixed"
        default:
            body = Data(m.text.utf8); ct = "text/plain; charset=utf-8"
        }
        let id = try? node.sendMessage(dst: addr, contentType: ct, body: body, requestAck: true)
        if let i = messages.firstIndex(where: { $0.id == m.id }) {
            messages[i].failed = false
            messages[i].delivered = false
            messages[i].bundleId = id
            messages[i].sentAt = Date()
        }
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

    // MARK: - LAN bearer (mDNS/Bonjour + TCP)

    /// Stand up the LAN transport: a Bonjour-advertised TCP listener named with our base58
    /// address, plus a browser that dials peers we should initiate to (lower base58 dials).
    /// Plain TCP + length framing, so it bridges to Android's NSD/ServerSocket on the same Wi-Fi.
    private func startLan() {
        // We keep LAN off AWDL/peer-to-peer (Apple-only); plain Wi-Fi/Ethernet keeps it cross-platform.
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        do {
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(name: myAddress, type: HopBearer.lanServiceType)
            listener.stateUpdateHandler = { state in
                if case .failed(let e) = state { NSLog("HOPLOG lan listener failed: \(e)") }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.addLanLink(conn, initiator: false, name: nil)   // we accept → Noise responder
            }
            listener.start(queue: .main)
            lanListener = listener
        } catch {
            NSLog("HOPLOG lan listener error: \(error)")
        }

        let browser = NWBrowser(for: .bonjour(type: HopBearer.lanServiceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                guard name != self.myAddress else { continue }                // not ourselves
                guard self.myAddress < name else { continue }                 // tiebreak: lower dials
                guard self.lanDialed[name] == nil else { continue }           // already dialing/linked
                let conn = NWConnection(to: r.endpoint, using: params)
                let id = self.addLanLink(conn, initiator: true, name: name)   // we dial → Noise initiator
                self.lanDialed[name] = id
                NSLog("HOPLOG lan dial \(name.prefix(8)) id=\(id)")
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let e) = state { NSLog("HOPLOG lan browser failed: \(e)") }
        }
        browser.start(queue: .main)
        lanBrowser = browser
        NSLog("HOPLOG lan start: \(myAddress.prefix(8))")
    }

    /// Re-stand-up the LAN listener/browser after a background suspension (Network.framework
    /// pauses them while we're suspended). Existing live links are left intact.
    private func restartLan() {
        lanListener?.cancel(); lanListener = nil
        lanBrowser?.cancel(); lanBrowser = nil
        lanDialed.removeAll()   // browser will re-report peers; live links stay in lanLinks
        startLan()
    }

    /// Wrap an NWConnection in a LanLink and register it. `node.connected` fires on `.ready`
    /// (TCP up); the dial side is the Noise initiator. Returns the assigned link id.
    @discardableResult
    private func addLanLink(_ conn: NWConnection, initiator: Bool, name: String?) -> UInt64 {
        let id = lanNextLinkId; lanNextLinkId += 1
        lanLinkInitiator[id] = initiator
        // LanLink runs its I/O on a background queue (so Wi-Fi never starves BLE on the main thread),
        // so every callback hops back to main before touching the node or @Published state.
        let link = LanLink(id: id, conn: conn,
            onReady: { [weak self] lid in
                DispatchQueue.main.async {
                    guard let self, let init0 = self.lanLinkInitiator.removeValue(forKey: lid) else { return }
                    NSLog("HOPLOG lan link up id=\(lid) initiator=\(init0)")
                    self.node.connected(link: lid, initiator: init0)
                    self.pump()
                }
            },
            onBytes: { [weak self] lid, data in
                DispatchQueue.main.async { self?.node.received(link: lid, bytes: data); self?.pump() }
            },
            onClose: { [weak self] lid in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lanLinks[lid] = nil
                    self.lanLinkInitiator[lid] = nil
                    if let n = name { self.lanDialed[n] = nil }
                    self.node.disconnected(link: lid); self.scheduleRefresh()
                }
            })
        lanLinks[id] = link
        return id
    }

    // MARK: - Cloud relay bearer (→ hop-relayd)

    /// Connect to a `hop-relayd`. Accepts either a `host:port` (raw TCP, path A) or a
    /// `ws://`/`wss://` URL (WebSocket, path B). The device dials, so it's the Noise
    /// initiator. Once connected, presence floods over this link, so two devices on the
    /// same relay discover and message each other across the internet (DESIGN.md §19, §21).
    /// Pin this device to a single relay by direct address (persisted), or pass nil to clear the
    /// pin and fall back to the anycast default. Switches the one relay connection over now; the
    /// old relay's presence simply lapses (we never publish to two at once).
    func setPinnedRelay(_ url: String?) {
        let trimmed = url?.trimmingCharacters(in: .whitespaces)
        let pinned = (trimmed?.isEmpty == false) ? trimmed : nil
        pinnedRelay = pinned
        if let pinned { UserDefaults.standard.set(pinned, forKey: "hop.pinnedRelay") }
        else { UserDefaults.standard.removeObject(forKey: "hop.pinnedRelay") }
        connectRelay(pinned ?? HopBearer.defaultRelay)   // connectRelay tears down the old link first
    }

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
                               self?.node.received(link: lid, bytes: data); self?.pump()
                           },
                           onClose: { [weak self] lid in
                               self?.links[lid] = nil; self?.node.disconnected(link: lid); self?.scheduleRefresh()
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
            } else if let lan = lanLinks[pkt.link] {
                lan.send(pkt.bytes)                         // LAN (Wi-Fi TCP) link
            } else if let gatt = gattLinks[pkt.link] {
                gatt.send(pkt.bytes)                        // GATT-data fallback (cross-platform BLE)
            } else if let ws = endpointWS[pkt.link] {
                ws.send(.data(pkt.bytes)) { _ in }         // direct hops:// endpoint link (§30)
            }
        }
        scheduleRefresh()
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
    func hpsRegister(path: String, channel: Bool, access: HpsAccess = .open,
                     discoverable: Bool = false) -> Data {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return Data() }
        let pk = node.registerService(path: p, kind: channel ? .channel : .service,
                                      access: access, visibility: discoverable ? .discoverable : .private)
        if !hpsTopics.contains(where: { $0.host == node.address() && $0.path == p }) {
            hpsTopics.insert(HpsTopic(host: node.address(), path: p, isChannel: channel,
                                      hosting: true, access: access), at: 0)
        }
        return pk
    }

    /// Subscribe to `hps://{hostBase58}/{path}` — request the topic's keys from its host.
    func hpsSubscribe(hostBase58: String, path: String) {
        let host = addressFromBase58(text: hostBase58.trimmingCharacters(in: .whitespacesAndNewlines))
        let p = path.trimmingCharacters(in: .whitespaces)
        guard host.count == 32, !p.isEmpty else { return }
        hpsSubscribe(host: host, path: p, isChannel: true)
    }

    private func hpsSubscribe(host: Data, path: String, isChannel: Bool) {
        _ = try? node.hpsSubscribe(host: host, path: path)
        if !hpsTopics.contains(where: { $0.host == host && $0.path == path }) {
            hpsTopics.insert(HpsTopic(host: host, path: path, isChannel: isChannel, hosting: false), at: 0)
        }
        pump()
    }

    /// Join a discoverable topic from a browse result.
    func hpsJoin(_ t: HpsTopicInfo) {
        hpsSubscribe(host: t.host, path: t.path, isChannel: t.kind == .channel)
    }

    /// Publish text to a topic we host or (for a channel) belong to. Floods to all subscribers.
    func hpsPublish(topic: HpsTopic, text: String) {
        guard !text.isEmpty, let body = text.data(using: .utf8) else { return }
        _ = try? node.hpsPublish(path: topic.path, body: body)
        // Echo our own post locally — broadcasts don't loop back to the sender.
        appendThread(topic.id, HpsMsgRow(path: topic.path, sender: node.address(), text: text, at: HopBearer.nowMs()))
        pump()
    }

    /// Host → contact: invite an address to a topic we host (Invite mode).
    func hpsInvite(topic: HpsTopic, to address: Data) {
        guard topic.hosting, address.count == 32 else { return }
        _ = try? node.hpsInvite(path: topic.path, dest: address)
        pump()
    }

    /// Accept an invite we received — joins the topic once the host seals us the keys.
    func hpsAcceptInvite(_ inv: HpsInvite) {
        _ = try? node.hpsAcceptInvite(host: inv.host, path: inv.path)
        hpsInvites.removeAll { $0.path == inv.path && $0.host == inv.host }
        if !hpsTopics.contains(where: { $0.host == inv.host && $0.path == inv.path }) {
            hpsTopics.insert(HpsTopic(host: inv.host, path: inv.path,
                                      isChannel: inv.kind == .channel, hosting: false), at: 0)
        }
        pump()
    }

    func hpsDeclineInvite(_ inv: HpsInvite) {
        try? node.hpsDeclineInvite(host: inv.host, path: inv.path)  // durable: won't reappear
        hpsInvites.removeAll { $0.path == inv.path && $0.host == inv.host }
    }

    /// Host: pending join requests (RequestToJoin) for a topic.
    func hpsPending(_ topic: HpsTopic) -> [Data] { node.hpsPending(path: topic.path) }
    func hpsApprove(_ topic: HpsTopic, _ who: Data) { _ = try? node.hpsApprove(path: topic.path, requester: who); pump() }
    func hpsDeny(_ topic: HpsTopic, _ who: Data) { try? node.hpsDeny(path: topic.path, requester: who) }
    /// Host: reach (unique acking members) + the retained-member set.
    func hpsReach(_ topic: HpsTopic) -> Int { Int(node.hpsReach(path: topic.path)) }
    func hpsMembers(_ topic: HpsTopic) -> [Data] { node.hpsMembers(path: topic.path) }
    /// Host: rotate keys, optionally removing members (revocation).
    func hpsRekey(_ topic: HpsTopic, remove: [Data] = []) { _ = try? node.hpsRekey(path: topic.path, newPath: "", remove: remove); pump() }

    /// Leave / unsubscribe a topic we follow.
    func hpsLeave(_ topic: HpsTopic) {
        _ = try? node.hpsLeave(path: topic.path)
        hpsTopics.removeAll { $0.id == topic.id }
        hpsThreads[topic.id] = nil
        hpsUnread[topic.id] = nil
        pump()
    }

    /// Discover same-app topics on the mesh (decrypted descriptors).
    func hpsBrowse() -> [HpsTopicInfo] { node.browseDiscoverable() }

    /// Rebuild the channel list from the node's persisted topics (hosted + subscribed) at startup.
    private func loadHpsTopics() {
        for t in node.hpsMyTopics() {
            let topic = HpsTopic(host: t.host, path: t.path, isChannel: t.kind == .channel,
                                 hosting: t.hosting, access: t.access)
            if !hpsTopics.contains(where: { $0.id == topic.id }) { hpsTopics.append(topic) }
        }
    }

    /// Mark a topic's thread as read (called when its screen is open).
    func openTopic(_ id: String) { activeTopic = id; hpsUnread[id] = 0 }
    func closeTopic() { activeTopic = nil }

    private func appendThread(_ id: String, _ row: HpsMsgRow) {
        hpsThreads[id, default: []].append(row)
        if hpsThreads[id]!.count > 500 { hpsThreads[id]!.removeFirst(hpsThreads[id]!.count - 500) }
    }

    /// Drain received pub/sub messages into per-topic threads, and surface new invites.
    private func drainHps() {
        for m in node.takeHpsMessages() {
            let text = String(data: m.body, encoding: .utf8) ?? "<\(m.body.count) bytes>"
            // Match the message to a topic we follow (by path; host is whoever we subscribed to).
            let topic = hpsTopics.first { $0.path == m.path }
            let id = topic?.id ?? m.path
            appendThread(id, HpsMsgRow(path: m.path, sender: m.sender, text: text, at: HopBearer.nowMs()))
            if id != activeTopic { hpsUnread[id, default: 0] += 1 }
            queueIdentify(m.sender)
        }
        for inv in node.takeHpsInvites() {
            if !hpsInvites.contains(where: { $0.path == inv.path && $0.host == inv.host }) {
                hpsInvites.append(inv)
                queueIdentify(inv.host)
            }
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
        if hop.node.allSatisfy({ $0 == 0 }) { return hop.appLabel }   // anonymized device hop (§27)
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
                scheduleRefresh()
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

    /// Mirror total unread onto the app icon badge so it shows even when the app is
    /// backgrounded/closed. iOS 16+ API; ignore the completion error (best-effort).
    private func updateAppBadge() {
        #if canImport(UIKit)
        let n = totalUnread
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(n)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = n
        }
        #endif
    }

    // MARK: - Message history persistence (survives app restart)

    /// On-disk form of a chat message. Omits `trace` (FFI type, incoming-path debug only) but KEEPS
    /// `bundleId`: the node persists undelivered own-bundles and keeps spraying them after a restart
    /// (node.rs rehydrate), and for an established session the bundle id is stable, so we re-query
    /// `messageStatus(bundleId)` on relaunch and the message flips to Delivered when its ACK lands.
    private struct StoredMessage: Codable {
        var peer: String; var text: String; var incoming: Bool
        var peerAddr: Data?; var contentType: String
        var imageData: Data?; var images: [Data]
        var hops: UInt8; var latencyMs: UInt64?
        var sentAt: Date; var deliveredAt: Date?
        var relayed: UInt32; var delivered: Bool; var deliveryHops: UInt8; var failed: Bool
        var bundleId: Data?
    }

    private static var messagesFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("messages.json")
    }

    /// Coalesce rapid mutations into one disk write (≤1 write/sec) so appending a burst of
    /// messages doesn't re-encode the whole history each time.
    private func scheduleMessageSave() {
        guard !loadingMessages else { return }   // don't echo the load back to disk
        messageSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveMessages() }
        messageSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func saveMessages() {
        let stored = messages.map {
            StoredMessage(peer: $0.peer, text: $0.text, incoming: $0.incoming,
                          peerAddr: $0.peerAddr, contentType: $0.contentType,
                          imageData: $0.imageData, images: $0.images,
                          hops: $0.hops, latencyMs: $0.latencyMs,
                          sentAt: $0.sentAt, deliveredAt: $0.deliveredAt,
                          relayed: $0.relayed, delivered: $0.delivered,
                          deliveryHops: $0.deliveryHops, failed: $0.failed,
                          bundleId: $0.bundleId)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: HopBearer.messagesFileURL, options: .atomic)
    }

    private static var channelsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("channels.json")
    }
    private func scheduleChannelSave() {
        guard !loadingMessages else { return }
        channelSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let data = try? JSONEncoder().encode(self.hpsThreads) else { return }
            try? data.write(to: HopBearer.channelsFileURL, options: .atomic)
        }
        channelSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
    private func loadChannels() {
        guard let data = try? Data(contentsOf: HopBearer.channelsFileURL),
              let stored = try? JSONDecoder().decode([String: [HpsMsgRow]].self, from: data) else { return }
        loadingMessages = true
        hpsThreads = stored
        loadingMessages = false
    }

    private func loadMessages() {
        guard let data = try? Data(contentsOf: HopBearer.messagesFileURL),
              let stored = try? JSONDecoder().decode([StoredMessage].self, from: data) else { return }
        loadingMessages = true
        // An outgoing message still in flight when we quit KEEPS sending: the node persists the
        // bundle and re-sprays it after restart until its delivery ACK (node.rs rehydrate). So we
        // restore it in-flight with its bundleId — refresh() re-queries messageStatus and it flips
        // to Delivered when the ACK lands — rather than falsely marking it "Not sent".
        messages = stored.map { s in
            Message(peer: s.peer, text: s.text, incoming: s.incoming, peerAddr: s.peerAddr,
                    contentType: s.contentType, imageData: s.imageData, images: s.images,
                    bundleId: s.bundleId,
                    hops: s.hops, latencyMs: s.latencyMs, sentAt: s.sentAt,
                    deliveredAt: s.deliveredAt, relayed: s.relayed, delivered: s.delivered,
                    deliveryHops: s.deliveryHops, failed: s.failed)
        }
        loadingMessages = false
    }

    // MARK: - Address book persistence (past conversations survive restart + going out of range)

    private struct StoredContact: Codable { var address: Data; var name: String; var platform: String; var app: String }
    private static var contactsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("contacts.json")
    }
    private var lastContactSaveAt = Date.distantPast
    /// Persist the address book, throttled (refresh runs often). Anyone we've seen, messaged, or
    /// been messaged by is kept, so their conversation is reachable even when offline / out of range.
    /// Add a peer to the address book and persist immediately (e.g. on send / manual add) so the
    /// conversation is reachable even if we quit before the next throttled save.
    func rememberContact(_ peer: Peer) {
        if contacts[peer.address] == nil { contacts[peer.address] = peer }
        nameByAddr[peer.address] = peer.name
        saveContacts(force: true)
    }
    private func saveContacts(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastContactSaveAt) > 4 else { return }
        lastContactSaveAt = Date()
        let snapshot = contacts.values.map {
            StoredContact(address: $0.address, name: $0.name, platform: $0.platform, app: $0.app)
        }
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: HopBearer.contactsFileURL, options: .atomic)
        }
    }
    private func loadContacts() {
        guard let data = try? Data(contentsOf: HopBearer.contactsFileURL),
              let stored = try? JSONDecoder().decode([StoredContact].self, from: data) else { return }
        for c in stored where contacts[c.address] == nil {
            contacts[c.address] = Peer(address: c.address, name: c.name, hops: 0,
                                       active: false, platform: c.platform, app: c.app)
            nameByAddr[c.address] = c.name
        }
    }

    private var refreshScheduled = false

    /// Coalesced UI refresh. `refresh()` does synchronous SQLite work (browse, queue, per-message
    /// status) and is far too expensive to run on every `pump()` — which fires on every received
    /// packet across BLE/Wi-Fi/LAN/relay. Running it per-packet saturates the main thread (watchdog
    /// 0x8BADF00D + cpu_resource kills, sluggish UI). Coalesce to ~4 Hz; the hot path still drains
    /// outgoing and the inbox immediately, only the heavy snapshot is throttled.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

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
        // Sort by the stable address, not last-seen hops/name — otherwise rows jump around as
        // hop counts fluctuate and generic names ("iPhone"/"iPad") tie. Address is fixed, so a
        // peer keeps its position.
        reachable = byAddr.values.sorted { $0.address.lexicographicallyPrecedes($1.address) }

        // Accumulate everyone we've ever seen into the (persisted) contact book; those not
        // currently reachable form the "seen" list — reachable across restarts + out-of-range.
        for (addr, peer) in byAddr { contacts[addr] = peer }
        let here = Set(byAddr.keys)
        seen = contacts.filter { !here.contains($0.key) }
            .map { Peer(address: $0.key, name: $0.value.name, hops: 0,
                        active: false, platform: $0.value.platform, app: $0.value.app) }
            .sorted { $0.address.lexicographicallyPrecedes($1.address) }
        saveContacts()   // throttled — persist the address book

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
        // Two distinct Wi-Fi transports: peer-to-peer (MultipeerConnectivity/AWDL, no router) and
        // local-network (the mDNS+TCP LAN bearer, shared Wi-Fi). They get different tags/icons.
        let p2pActive = !wifiBlocked && (wifiUp || !mcPeerByLink.isEmpty)
        let lanActive = wifiUp || !lanLinks.isEmpty
        let relayActive = (relayConn != nil || relayWS != nil) && relayStatus == "connected"
        let pls = node.peerLinks()
        transports = [
            TransportStatus(id: "Bluetooth", active: bleActive, links: links.count),
            TransportStatus(id: "Peer-to-Peer", active: p2pActive, links: mcPeerByLink.count),
            TransportStatus(id: "Local Net", active: lanActive, links: lanLinks.count),
            TransportStatus(id: "Relay", active: relayActive, links: relayActive ? 1 : 0),
        ]

        // Map each direct neighbour to the transport(s) carrying it (the route).
        var lt = [Data: Set<String>]()
        for pl in pls {
            let t: String
            switch pl.link {
            case ..<10_000:  t = "BT"
            case ..<20_000:  t = "P2P"       // MultipeerConnectivity / AWDL — peer-to-peer Wi-Fi, no router
            case ..<40_000:  t = "Relay"     // relay (20k) + hops:// endpoints (30k) aren't local
            default:          t = "LAN"        // 40k+ = LAN TCP over a shared network (mDNS)
            }
            lt[pl.address, default: []].insert(t)
        }
        linkTransports = lt

        // A live local radio link (BLE / Wi-Fi P2P) IS a 1-hop path, so force the hop count to 1
        // for those peers — even if a stale presence advert arrived via the relay at 2 hops. This
        // keeps "direct" honest: a peer is direct iff hops <= 1, so a live-linked peer shows
        // "1 hop · BT" (never "2 hops"), and a peer with no live link at 2 hops stays in the mesh.
        reachable = reachable.map { p in
            var p = p
            if let t = lt[p.address], t.contains("BT") || t.contains("P2P") || t.contains("LAN") { p.hops = 1 }
            return p
        }

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
        // GATT-data fallback: dynamic (value: nil) write+indicate characteristic.
        let dataChar = CBMutableCharacteristic(type: HopBearer.dataCharUUID, properties: [.write, .indicate],
                                               value: nil, permissions: [.writeable])
        peripheralDataChar = dataChar
        let service = CBMutableService(type: HopBearer.serviceUUID, primary: true)
        service.characteristics = [char, dataChar]
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

    // MARK: - GATT-data peripheral side (the L2CAP fallback)

    /// A central subscribed to our DATA characteristic → it's about to drive a GATT-data link to us.
    /// Bring up our peripheral (responder) side now.
    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == HopBearer.dataCharUUID else { return }
        _ = peripheralGattLink(for: central)
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == HopBearer.dataCharUUID else { return }
        if let id = centralGattLink[central.identifier] { closeGattLink(id) }
    }

    /// Inbound GATT-data chunks (ATT writes) from a central → reassemble into Hop frames.
    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for req in requests where req.characteristic.uuid == HopBearer.dataCharUUID {
            if let v = req.value { peripheralGattLink(for: req.central).received(v) }
        }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }

    /// The notify transmit queue drained → resume any back-pressured peripheral sends.
    func peripheralManagerIsReady(toUpdateSubscribers p: CBPeripheralManager) {
        for (id, chunk) in peripheralBackpressure {
            guard let ch = peripheralDataChar, let central = gattLinkCentral[id] else { continue }
            if p.updateValue(chunk, for: ch, onSubscribedCentrals: [central]) {
                peripheralBackpressure[id] = nil
                gattLinks[id]?.chunkSent()
            } else {
                break // still full — wait for the next isReady
            }
        }
    }

    private func peripheralGattLink(for central: CBCentral) -> GattDataLink {
        if let id = centralGattLink[central.identifier], let l = gattLinks[id] { return l }
        let id = nextGattLinkId; nextGattLinkId += 1
        let link = GattDataLink(
            id: id,
            usablePayload: { central.maximumUpdateValueLength },
            sendChunk: { [weak self] chunk in
                guard let self, let p = self.peripheralMgr, let ch = self.peripheralDataChar else { return false }
                if p.updateValue(chunk, for: ch, onSubscribedCentrals: [central]) {
                    DispatchQueue.main.async { self.gattLinks[id]?.chunkSent() } // queued → free for next
                } else {
                    self.peripheralBackpressure[id] = chunk  // full → resume in isReady
                }
                return true
            },
            onBytes: { [weak self] lid, data in self?.node.received(link: lid, bytes: data); self?.pump() },
            onClose: { [weak self] lid in self?.closeGattLink(lid) })
        gattLinks[id] = link
        gattLinkCentral[id] = central
        centralGattLink[central.identifier] = id
        node.connected(link: id, initiator: false)  // peripheral = Noise responder
        NSLog("HOPLOG GATT-data link UP id=\(id) initiator=false (peripheral)")
        pump()
        return link
    }

    func closeGattLink(_ id: UInt64) {
        gattLinks[id]?.close()
        gattLinks[id] = nil
        peripheralBackpressure[id] = nil
        if let c = gattLinkCentral[id] { centralGattLink[c.identifier] = nil }
        gattLinkCentral[id] = nil
        // Central link: drop the underlying GATT connection so scheduleReconnect rebuilds it
        // (a degraded link that just lingers never recovers — the "works then degrades" failure).
        if let p = gattLinkPeripheral[id] {
            gattDataCharFor[p.identifier] = nil
            centralMgr?.cancelPeripheralConnection(p)
        }
        gattLinkPeripheral[id] = nil
        node.disconnected(link: id); scheduleRefresh()
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
        // allowDuplicates: keep re-reporting peers so we get repeated connect chances. Without
        // it iOS reports each peripheral once per scan session, so a peer that wasn't connectable
        // at that instant (e.g. an Android peer mid-restart) is never re-discovered until a new
        // scan session — which is why the Pixel could be missed entirely.
        central.scanForPeripherals(withServices: [HopBearer.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
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
        // Read the peer's L2CAP PSM straight from the advert (manufacturer data: [2B company id]
        // [2B PSM big-endian]). It's fresh on every scan, so we never depend on iOS's cached GATT
        // — which serves a stale PSM after the peer (Android) restarts, the "connects but never
        // reads PSM" stall. Android peers carry this; iOS peers don't (iOS can't advertise mfg
        // data), so those fall back to the GATT read below.
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            let b = [UInt8](mfg)
            if b.count >= 4 {
                let psm = CBL2CAPPSM(UInt16(b[2]) << 8 | UInt16(b[3]))
                if psm != 0 { l2capPsm[peripheral.identifier] = psm }
            }
        }
        guard !connecting.contains(peripheral.identifier) else { return }
        connecting.insert(peripheral.identifier)
        retained[peripheral.identifier] = peripheral
        peripheral.delegate = self
        status = "found a device, connecting…"
        c.connect(peripheral)
    }

    func centralManager(_ c: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // ALWAYS discover services: we need the DATA characteristic for the GATT-data fallback (the
        // path that actually works to Android), even when the advert already gave us a PSM. Without
        // this the advert fast-path skipped discovery, so the fallback could never find DATA.
        peripheral.discoverServices([HopBearer.serviceUUID])
        // Fast path: PSM known from the advert → also kick off L2CAP now (skips waiting on the GATT
        // read). The `opened` guard stops the GATT-read path from double-opening.
        if let psm = l2capPsm[peripheral.identifier], !opened.contains(peripheral.identifier) {
            opened.insert(peripheral.identifier)
            l2capAttempts[peripheral.identifier] = 0
            status = "opening L2CAP (psm \(psm))…"
            openL2CAP(peripheral, psm)
        } else {
            status = "connected (GATT), reading PSM…"
        }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        scheduleReconnect(peripheral)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        opened.remove(peripheral.identifier)
        gattDataCharFor[peripheral.identifier] = nil
        // Tear down any GATT-data link that rode this connection.
        if let id = gattLinkPeripheral.first(where: { $0.value.identifier == peripheral.identifier })?.key {
            closeGattLink(id)
        }
        status = "peer left — awaiting return…"
        scheduleReconnect(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if error != nil { return recover(peripheral) }
        for s in peripheral.services ?? [] where s.uuid == HopBearer.serviceUUID {
            peripheral.discoverCharacteristics([HopBearer.psmCharUUID, HopBearer.dataCharUUID], for: s)
        }
    }

    /// The peer's GATT changed — almost always an Android peripheral that restarted and minted a
    /// NEW L2CAP PSM (`listenUsingInsecureL2capChannel` can't pin it). Without handling this we'd
    /// keep opening L2CAP with the stale cached PSM ("No such L2CAP connection"), so cross-platform
    /// BLE never re-links after the peer restarts. Drop the cached PSM and re-discover to read the
    /// fresh one.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        l2capPsm[peripheral.identifier] = nil
        l2capAttempts[peripheral.identifier] = nil
        opened.remove(peripheral.identifier)
        peripheral.discoverServices([HopBearer.serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if error != nil { return recover(peripheral) }
        for ch in service.characteristics ?? [] {
            if ch.uuid == HopBearer.dataCharUUID { gattDataCharFor[peripheral.identifier] = ch }
            if ch.uuid == HopBearer.psmCharUUID { peripheral.readValue(for: ch) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // GATT-data indication from a peripheral we fell back to → reassemble Hop frames.
        if characteristic.uuid == HopBearer.dataCharUUID {
            guard error == nil, let v = characteristic.value,
                  let id = gattLinkPeripheral.first(where: { $0.value.identifier == peripheral.identifier })?.key
            else { return }
            gattLinks[id]?.received(v)
            return
        }
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
            let id = peripheral.identifier
            let n = (l2capAttempts[id] ?? 0) + 1
            l2capAttempts[id] = n
            // TWO quick same-connection retries cover the transient XR-radio first-open glitch.
            // Beyond that the GATT connection itself is wedged — re-opening on the same handle just
            // keeps failing (CBErrorDomain "Unknown error") and leaves a half-open the Android peer
            // accepted but we abandoned. So tear the whole connection down and reconnect FRESH:
            // a clean GATT link + a freshly re-read PSM is what actually clears the wedge. The
            // scheduleReconnect backoff (1→20s) keeps this from hammering a flaky radio.
            if n <= 2, peripheral.state == .connected, let psm = l2capPsm[id] {
                status = "L2CAP retry \(n) (psm \(psm))…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, let p = self.retained[id], p.state == .connected else {
                        if let p = self?.retained[id] { self?.recover(p) }
                        return
                    }
                    self.openL2CAP(p, psm)
                }
            } else {
                l2capAttempts[id] = nil
                // L2CAP won't open (Apple→Android always fails this way). Fall back to GATT-data over
                // the SAME GATT connection — don't tear it down. Only if that can't start do we
                // reconnect fresh and retry L2CAP (covers a genuinely wedged iOS↔iOS connection).
                if peripheral.state == .connected, startCentralGattData(peripheral) {
                    NSLog("HOPLOG L2CAP failed after \(n) tries → GATT-data fallback")
                } else {
                    NSLog("HOPLOG L2CAP wedged after \(n) tries → full reconnect (fresh PSM)")
                    l2capPsm[id] = nil       // force a fresh PSM re-read via GATT on the new connection
                    recover(peripheral)       // cancel → didDisconnect → scheduleReconnect → rediscover → reopen
                }
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

    // MARK: - GATT-data central side (the L2CAP fallback)

    /// Subscribe to the peer's DATA characteristic (enable indications). The link comes up in
    /// didUpdateNotificationStateFor. Returns false if the characteristic wasn't discovered.
    private func startCentralGattData(_ peripheral: CBPeripheral) -> Bool {
        guard let ch = gattDataCharFor[peripheral.identifier] else { return false }
        peripheral.setNotifyValue(true, for: ch)
        return true
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == HopBearer.dataCharUUID else { return }
        if error != nil { return recover(peripheral) }
        guard characteristic.isNotifying else { return }
        // Already linked? (a duplicate callback) — ignore.
        if gattLinkPeripheral.contains(where: { $0.value.identifier == peripheral.identifier }) { return }
        let id = nextGattLinkId; nextGattLinkId += 1
        let link = GattDataLink(
            id: id,
            usablePayload: { peripheral.maximumWriteValueLength(for: .withResponse) },
            sendChunk: { [weak self] chunk in
                guard self != nil, peripheral.state == .connected else { return false }
                peripheral.writeValue(chunk, for: characteristic, type: .withResponse) // → didWriteValueFor
                return true
            },
            onBytes: { [weak self] lid, data in self?.node.received(link: lid, bytes: data); self?.pump() },
            onClose: { [weak self] lid in self?.closeGattLink(lid) })
        gattLinks[id] = link
        gattLinkPeripheral[id] = peripheral
        connecting.insert(peripheral.identifier)
        node.connected(link: id, initiator: true)   // central = Noise initiator
        NSLog("HOPLOG GATT-data link UP id=\(id) initiator=true (central)")
        backoff[peripheral.identifier] = nil
        pump()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == HopBearer.dataCharUUID else { return }
        guard let id = gattLinkPeripheral.first(where: { $0.value.identifier == peripheral.identifier })?.key
        else { return }
        if error != nil { closeGattLink(id); return }
        gattLinks[id]?.chunkSent()
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
                    self.scheduleRefresh()
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
