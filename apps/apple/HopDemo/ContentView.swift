import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import HopDriver
import HopDemoKit
#if canImport(UIKit)
import UIKit
#endif

/// Image helpers: keep image work OFF the render path and small on the wire.
enum HopImages {
    /// Decode-once cache keyed by the image bytes. SwiftUI re-evaluates view bodies constantly;
    /// calling `UIImage(data:)` inline re-decodes every image on every render, which pegged the
    /// CPU (cpu_resource_fatal) once there were photos in history. Decode once, reuse.
    private static let cache = NSCache<NSData, UIImage>()
    static func image(_ data: Data) -> UIImage? {
        let key = data as NSData
        if let c = cache.object(forKey: key) { return c }
        guard let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    /// Downscale + recompress a picked photo to a small JPEG using an ImageIO thumbnail. The
    /// decode+downscale (the low memory/CPU part that avoids loading a full 12MP+ image, and the
    /// bug-prone one) lives in HopDemoKit.downscaledCGImage and is unit-tested there; here we just
    /// JPEG-encode the result. Mirrors Android's jpegDownscale.
    static func downscaledJPEG(_ data: Data, maxPixel: CGFloat = 1280, quality: CGFloat = 0.6) -> Data? {
        guard let cg = DemoFormat.downscaledCGImage(data, maxPixel: maxPixel) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
    }
}

struct ContentView: View {
    @StateObject private var bearer = HopBearer.shared
    @State private var started = false
    @State private var nameField = ""
    @State private var relayField = ""
    @State private var hopsField = ""
    @State private var showAddContact = false
    @State private var showScan = false
    @State private var showMyQR = false

    private var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        "Hop device"
        #endif
    }

    /// A peer is "direct" if we reach it without the cloud relay, either a live local radio
    /// link (BLE / Wi-Fi P2P), OR its presence arrived at ≤1 hop (a direct-neighbour advert).
    /// Both are needed: the link signal catches a peer whose advert came via a longer relay
    /// path, and the hop signal is robust to local links momentarily churning in/out of
    /// `peerLinks` (otherwise direct peers flicker to "mesh" between link blips).
    /// Direct = a 1-hop neighbour. A live BT/Wi-Fi link is forced to 1 hop in refresh(), so this
    /// single rule covers both live links and direct adverts, and a 2-hop peer is never "direct".
    private func isDirect(_ p: HopBearer.Peer) -> Bool { DemoFormat.isDirect(hops: p.hops) }
    private var direct: [HopBearer.Peer] { bearer.reachable.filter { isDirect($0) } }
    private var mesh: [HopBearer.Peer] { bearer.reachable.filter { !isDirect($0) } }

    var body: some View {
        TabView {
            chatsTab.tabItem { Label("Chats", image: "ic_fa_comments") }
            channelsTab.tabItem { Label("Channels", image: "ic_fa_tower_broadcast") }
            webTab.tabItem { Label("Web", image: "ic_fa_globe") }
            statusTab.tabItem { Label("Status", image: "ic_fa_gear") }
        }
        .onAppear {
            guard !started else { return }
            started = true
            let name = HopBearer.savedName(default: deviceName)
            nameField = name
            bearer.start(name: name)
        }
    }

    // MARK: - Tab 1: Chats, people you can reach → chat thread (shared IA)
    @ViewBuilder private var chatsTab: some View {
        NavigationStack {
            List {
                Section("Nearby (direct)") {
                    if direct.isEmpty { Text("none").foregroundStyle(.secondary) }
                    ForEach(direct) { peer in peerRow(peer) }
                }
                Section("In the mesh (relayed)") {
                    if mesh.isEmpty { Text("none").foregroundStyle(.secondary) }
                    ForEach(mesh) { peer in peerRow(peer) }
                }
                if !bearer.seen.isEmpty {
                    Section("Conversations & seen (offline)") {
                        ForEach(bearer.seen) { peer in
                            NavigationLink(value: peer) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(peer.name)
                                        Text(HopBearer.shortHex(peer.address))
                                            .font(.caption2).monospaced().foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let n = bearer.unread[peer.name], n > 0 {
                                        Text("\(n)").font(.caption2).bold().foregroundStyle(.white)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.red).clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(bearer.totalUnread > 0 ? "Chats (\(bearer.totalUnread))" : "Chats")
            .navigationDestination(for: HopBearer.Peer.self) { peer in
                ChatView(bearer: bearer, peer: peer)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showMyQR = true } label: { FaIcon(name: "ic_fa_qrcode", size: 20) }
                        .accessibilityLabel("My QR code")
                    Button { showScan = true } label: { FaIcon(name: "ic_fa_qrcode", size: 20) }
                        .accessibilityLabel("Scan a contact")
                    Button { showAddContact = true } label: { FaIcon(name: "ic_fa_user_plus", size: 20) }
                        .accessibilityLabel("Add contact")
                }
            }
            .sheet(isPresented: $showAddContact) { AddContactView(bearer: bearer) }
            .sheet(isPresented: $showMyQR) { QRRevealView(address: bearer.myAddress, name: bearer.myName) }
            .sheet(isPresented: $showScan) { QRScanSheet(bearer: bearer) }
        }
    }

    // MARK: - Tab 2: Channels, hps:// pub/sub (stack nav: list → channel thread)
    @ViewBuilder private var channelsTab: some View {
        NavigationStack {
            ChannelsListView(bearer: bearer)
        }
    }

    // MARK: - Tab 3: Web, hops:// fetch + browser, HNS cache
    @ViewBuilder private var webTab: some View {
        NavigationStack {
            List {
                Section("hops://") {
                    HStack {
                        TextField("example.hopme.sh", text: $hopsField)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .onSubmit { fetchHops() }
                        Button("Fetch") { fetchHops() }
                            .disabled(hopsField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    NavigationLink {
                        HopBrowserView(bearer: bearer, start: hopsField.isEmpty ? "example.hopme.sh" : hopsField)
                    } label: {
                        Label("Open in hops:// browser", image: "ic_fa_globe")
                    }
                    ForEach(bearer.hopsResults.sorted(by: { $0.key < $1.key }), id: \.key) { domain, text in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(domain).font(.caption).monospaced().foregroundStyle(.secondary)
                            Text(text).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                if !bearer.hnsCache.isEmpty {
                    Section("HNS cache") {
                        ForEach(bearer.hnsCache) { rec in
                            HStack {
                                FaIcon(name: rec.address.isEmpty ? "ic_fa_xmark" : "ic_fa_magnifying_glass", size: 15)
                                    .foregroundStyle(rec.address.isEmpty ? .red : .green)
                                VStack(alignment: .leading) {
                                    Text(rec.domain).font(.callout)
                                    Text(rec.address.isEmpty ? "no record (negative)" : HopBearer.shortHex(rec.address))
                                        .font(.caption2).monospaced().foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("TTL \(rec.ttl)s")
                                    .font(.caption2).monospaced()
                                    .foregroundStyle(rec.ttl < 30 ? .orange : .secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Web")
        }
    }

    // MARK: - Tab 4: Status, device, relay, transports, backbone, queue
    @ViewBuilder private var statusTab: some View {
        NavigationStack {
            List {
                Section("This device") {
                    HStack {
                        TextField("Your name", text: $nameField)
                            .textInputAutocapitalization(.words)
                            .onSubmit { bearer.setName(nameField) }
                        if nameField != bearer.myName {
                            Button("Save") { bearer.setName(nameField) }
                        }
                    }
                    LabeledContent("Address", value: bearer.myAddress).monospaced()
                    LabeledContent("Status", value: bearer.status).font(.caption)
                    LabeledContent("Identity", value: bearer.idNote).font(.caption)
                    HStack {
                        Button { showMyQR = true } label: { Label("My QR", image: "ic_fa_qrcode") }
                        Spacer()
                        Button { showScan = true } label: { Label("Scan", image: "ic_fa_qrcode") }
                    }.buttonStyle(.bordered).font(.caption)
                }

                Section {
                    Toggle(isOn: $bearer.privateMode) {
                        Text("Private mode")
                        Text(bearer.privateMode
                             ? "Not broadcasting your name. Reachable only by people who have your address (scan your QR). Still relays for everyone."
                             : "Discoverable: broadcasting your name to nearby devices.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Privacy") }

                Section("Local history") {
                    if let error = bearer.persistenceError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    Button(role: .destructive) { bearer.deleteMedia() } label: {
                        Text("Delete all media")
                    }
                    Button(role: .destructive) { bearer.deleteHistory() } label: {
                        Text("Delete all history")
                    }
                }

                Section {
                    HStack {
                        TextField("host:port or wss://relay.hopme.sh/", text: $relayField)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Pin") {
                            let a = relayField.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !a.isEmpty { bearer.setPinnedRelay(a) }
                        }
                    }
                    LabeledContent("Relay", value: bearer.relayStatus).font(.caption)
                    if let pinned = bearer.pinnedRelay {
                        LabeledContent("Pinned", value: pinned).font(.caption).monospaced()
                        Button("Unpin (use anycast default)", role: .destructive) {
                            bearer.setPinnedRelay(nil); relayField = ""
                        }.font(.caption)
                    } else {
                        Text("Anycast (default). A device uses one relay at a time. Pin a direct address to test a specific relay.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } header: { Text("Cloud relay (backbone)") }

                Section("Transports") {
                    ForEach(bearer.transports) { t in
                        DisclosureGroup {
                            let addrs = peersOn(t.id)
                            ForEach(addrs, id: \.self) { addr in
                                HStack {
                                    FaIcon(name: transportIcon(transportTag(t.id)), size: 12)
                                        .foregroundStyle(.secondary)
                                    Text(bearer.displayName(addr))
                                    Spacer()
                                    Text(HopBearer.shortHex(addr))
                                        .font(.caption2).monospaced().foregroundStyle(.secondary)
                                }
                            }
                            // Links connected at the transport level but not yet through
                            // the Noise handshake (so we don't know the peer address yet).
                            let establishing = t.links - addrs.count
                            if establishing > 0 {
                                Text("\(establishing) establishing…")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if addrs.isEmpty {
                                Text("no peers").font(.caption).foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack {
                                Circle().fill(statusColor(t)).frame(width: 8, height: 8)
                                Text(t.id)
                                Spacer()
                                Text(statusText(t))
                                    .font(.caption).foregroundStyle(.secondary)
                                // A shared bearer carries a tag and can be switched off at runtime;
                                // Peer-to-Peer (Multipeer) is not a shared bearer, so it has none.
                                if let tag = t.tag {
                                    Toggle("", isOn: Binding(
                                        get: { t.enabled },
                                        set: { bearer.setTransportEnabled(tag, $0) }
                                    ))
                                    .labelsHidden()
                                    .accessibilityLabel("\(t.id) transport")
                                }
                            }
                        }
                    }
                    Text("Switching a transport off closes its live links, so the node stops routing over it. Not every integrator ships every radio.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if !bearer.relays.isEmpty {
                    Section("Relays (backbone)") {
                        ForEach(bearer.relays) { r in
                            HStack {
                                FaIcon(name: "ic_fa_cloud", size: 17).foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text(r.name)
                                    Text(HopBearer.shortHex(r.address))
                                        .font(.caption2).monospaced().foregroundStyle(.secondary)
                                }
                                Spacer()
                                if bearer.routed.contains(r.address) {
                                    FaIcon(name: "ic_fa_code_branch", size: 11)
                                        .foregroundStyle(.blue).help("learned route")
                                }
                            }
                        }
                    }
                }

                if !bearer.endpoints.isEmpty {
                    Section("hops:// endpoints") {
                        ForEach(bearer.endpoints) { e in
                            HStack {
                                FaIcon(name: "ic_fa_globe", size: 16).foregroundStyle(.green)
                                VStack(alignment: .leading) {
                                    Text(e.name)
                                    Text(HopBearer.shortHex(e.address))
                                        .font(.caption2).monospaced().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    if bearer.queue.isEmpty { Text("empty").foregroundStyle(.secondary) }
                    ForEach(bearer.queue) { row in
                        HStack {
                            FaIcon(name: row.own ? "ic_fa_thumbtack" : "ic_fa_right_left", size: 13)
                                .foregroundStyle(row.own ? .orange : .secondary)
                            Text(row.own ? "yours → \(row.to)" : "relay → \(row.to)")
                            Spacer()
                            Text("p\(row.priority) · \(row.hops)h").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Relay queue (\(bearer.queue.count))")
                        Spacer()
                        if !bearer.queue.isEmpty {
                            Button(role: .destructive) { bearer.clearQueue() } label: {
                                Label("Clear", image: "ic_fa_trash").labelStyle(.titleAndIcon)
                            }
                            .textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("Status")
        }
    }

    /// Fetch the entered hops:// URL (DESIGN.md §30).
    private func fetchHops() {
        let s = hopsField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        bearer.openHops(s)
    }

    /// Subtitle: address · platform · app (omitting empties). The join + platform-label logic lives
    /// in HopDemoKit; the short address comes from the driver's base58 helper.
    private func subline(_ peer: HopBearer.Peer) -> String {
        DemoFormat.subline(shortAddress: HopBearer.shortHex(peer.address),
                           platform: peer.platform, app: peer.app)
    }

    @ViewBuilder private func peerRow(_ peer: HopBearer.Peer) -> some View {
        NavigationLink(value: peer) {
            HStack {
                Circle().fill(peer.active ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                    .help(peer.active ? "foreground" : "backgrounded")
                VStack(alignment: .leading) {
                    HStack(spacing: 4) {
                        Text(peer.name)
                        if bearer.secured.contains(peer.address) {
                            FaIcon(name: "ic_fa_lock", size: 11).foregroundStyle(.green)
                        }
                        if bearer.routed.contains(peer.address) {
                            FaIcon(name: "ic_fa_code_branch", size: 11)
                                .foregroundStyle(.blue).help("learned route")
                        }
                    }
                    Text(subline(peer)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let n = bearer.unread[peer.name], n > 0 {
                    Text("\(n)")
                        .font(.caption2).bold().foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red).clipShape(Capsule())
                }
                // A symbol per live link (one per transport carrying this peer); the hop
                // count for a peer reached only through the mesh.
                let tags = bearer.linkTransports[peer.address] ?? []
                if !tags.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(tags.sorted(), id: \.self) { tag in
                            FaIcon(name: transportIcon(tag), size: 11)
                                .foregroundStyle(.secondary).help(tag)
                        }
                    }
                } else {
                    Text("\(peer.hops) hops").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Font Awesome (Light) asset name for a transport tag (logic in HopDemoKit, unit-tested).
    /// Rendered via FaIcon (template/tintable); bluetooth-b is a brand glyph.
    private func transportIcon(_ tag: String) -> String { DemoFormat.transportIcon(tag) }

    /// Three states, not two: off by choice, on but with no peers, on and carrying links. Collapsing
    /// the first two into one red dot would make a deliberate setting look like a failure.
    private func statusColor(_ t: HopBearer.TransportStatus) -> Color {
        if !t.enabled { return .secondary }
        return t.active ? .green : .orange
    }

    private func statusText(_ t: HopBearer.TransportStatus) -> String {
        if !t.enabled { return "disabled" }
        return t.active ? "\(t.links) linked" : "no links"
    }

    /// Map a TransportStatus id to the tag used in `linkTransports` (logic in HopDemoKit).
    private func transportTag(_ id: String) -> String { DemoFormat.transportTag(id) }

    /// Addresses currently linked over a given transport (by its status id).
    private func peersOn(_ id: String) -> [Data] {
        let tag = transportTag(id)
        return bearer.linkTransports.filter { $0.value.contains(tag) }.map { $0.key }
            .sorted { bearer.displayName($0) < bearer.displayName($1) }
    }
}

/// In-flight status for a message not yet handed to any peer: a pulsing dot + a live "Awaiting
/// peers · Ns" timer. Conveys "working on it, holding for a peer to appear" instead of a static,
/// alarming "Sending…". Flips to the peer hand-off count (in `meta`) once relayed > 0.
struct SendingIndicator: View {
    let sentAt: Date
    var peersReachable: Bool = false
    @State private var pulse = false
    var body: some View {
        // With peers around, the holdup is the recipient's forward-secret session, not peer availability.
        let label = peersReachable ? "Securing" : "Awaiting peers"
        HStack(spacing: 5) {
            Circle().fill(.orange).frame(width: 6, height: 6)
                .scaleEffect(pulse ? 1.0 : 0.55)
                .opacity(pulse ? 1.0 : 0.35)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text("\(label) · \(max(0, Int(ctx.date.timeIntervalSince(sentAt))))s")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { pulse = true }
    }
}

struct ChatView: View {
    @ObservedObject var bearer: HopBearer
    let peer: HopBearer.Peer
    @State private var draft = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var attached: [Data] = []   // staged images (JPEG) for one multipart send

    private var thread: [HopBearer.Message] {
        // Key by address (stable across renames); fall back to name for older messages.
        bearer.messages.filter {
            if let a = $0.peerAddr { return a == peer.address }
            return $0.peer == peer.name
        }
    }

    /// The origin send time under a bubble, or nil when there is nothing trustworthy to show.
    /// Outgoing: our own send clock. Incoming: the bundle's `created_at`, minute-granular on the
    /// private path by design (see DemoFormat.originStamp).
    private func originLabel(_ m: HopBearer.Message) -> String? {
        guard let origin = m.incoming ? m.originAt : m.sentAt else { return nil }
        return DemoFormat.originStamp(origin, now: Date())
    }

    /// One-line metadata under a bubble (formatting logic in HopDemoKit, unit-tested).
    /// Incoming: "2 hops, 1m" (path length + send→receive time).
    /// Outgoing: "Delivered, 10 hops, 2h" once acked, else "Sent · N peers".
    /// relayed == 0 is rendered by SendingIndicator (pulsing + live timer), not this string.
    private func meta(_ m: HopBearer.Message) -> String {
        DemoFormat.messageMeta(incoming: m.incoming, hops: m.hops, latencyMs: m.latencyMs,
                               delivered: m.delivered, deliveryHops: m.deliveryHops,
                               deliveryMs: m.deliveryMs, failed: m.failed, relayed: m.relayed)
    }

    var body: some View {
        VStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(thread) { m in
                        // Images: a single-image message, or each image of a multipart one.
                        let imgs: [Data] = m.imageData.map { [$0] } ?? m.images
                        VStack(alignment: m.incoming ? .leading : .trailing, spacing: 4) {
                            ForEach(Array(imgs.enumerated()), id: \.offset) { _, data in
                                if let img = HopImages.image(data) {
                                    Image(uiImage: img)
                                        .resizable().scaledToFit()
                                        .frame(maxWidth: 220, maxHeight: 220)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                            if !m.text.isEmpty {
                                Text(m.text)
                                    .padding(8)
                                    .background(m.incoming ? Color.gray.opacity(0.2) : Color.accentColor.opacity(0.25))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            if m.failed && !m.incoming {
                                Button { bearer.retry(m) } label: {
                                    Label("Not sent · tap to retry", image: "ic_fa_arrows_rotate")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                            } else if !m.incoming && !m.delivered && m.relayed == 0 {
                                // In flight, not yet handed to any peer. With peers around, the holdup is
                                // the recipient's forward-secret session, not peer availability, only with
                                // no reachable peers is it genuinely "Awaiting peers".
                                SendingIndicator(sentAt: m.sentAt, peersReachable: !bearer.reachable.isEmpty)
                            } else {
                                HStack(spacing: 6) {
                                    // When the ORIGINATING device sent it. For an outgoing message we
                                    // are the origin, so sentAt IS that; for an incoming one sentAt is
                                    // when WE received it, so originAt (the bundle's created_at) is the
                                    // only honest source and nil when the sender left it unset.
                                    if let stamp = originLabel(m) {
                                        Text(stamp).font(.caption2).monospacedDigit()
                                            .foregroundStyle(.secondary)
                                        Text("\u{00B7}").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Text(meta(m)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            // Provenance: who/what carried each hop, resolved to display
                            // names where known (DESIGN.md §27/§29).
                            if m.incoming, !m.trace.isEmpty {
                                Text("path: " + m.trace.map { bearer.traceLabel($0) }.joined(separator: " → "))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: m.incoming ? .leading : .trailing)
                    }
                }
                .padding()
            }
            // Staged-image tray (when one or more are attached for a multipart send).
            if !attached.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(attached.enumerated()), id: \.offset) { idx, data in
                            if let img = HopImages.image(data) {
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(alignment: .topTrailing) {
                                        Button { attached.remove(at: idx) } label: {
                                            FaIcon(name: "ic_fa_xmark", size: 14)
                                        }
                                    }
                            }
                        }
                    }.padding(.horizontal)
                }
            }
            HStack {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 8, matching: .images) {
                    FaIcon(name: "ic_fa_camera", size: 22)
                }
                TextField("Message \(peer.name)", text: $draft).textFieldStyle(.roundedBorder)
                Button("Send") {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !attached.isEmpty {
                        bearer.sendMultipart(text: t, images: attached, to: peer)
                        attached = []; draft = ""
                    } else if !t.isEmpty {
                        bearer.send(t, to: peer); draft = ""
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attached.isEmpty)
            }
            .padding()
            .onChange(of: photoItems) { items in
                guard !items.isEmpty else { return }
                Task {
                    var loaded: [Data] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let jpeg = HopImages.downscaledJPEG(data), jpeg.count <= 8 * 1024 * 1024 {
                            loaded.append(jpeg)
                        }
                    }
                    await MainActor.run { attached.append(contentsOf: loaded); photoItems = [] }
                }
            }
        }
        .onAppear { bearer.openChat(peer.name); bearer.identify(peer.address) }
        .onDisappear { bearer.closeChat() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 5) {
                    Text(peer.hops <= 1 ? peer.name : "\(peer.name) · \(peer.hops)h").font(.headline)
                    if let kind = bearer.identity(peer.address)?.kind, kind == "relay" {
                        FaIcon(name: "ic_fa_cloud", size: 13).foregroundStyle(.blue)
                    }
                    if bearer.secured.contains(peer.address) {
                        FaIcon(name: "ic_fa_lock", size: 13).foregroundStyle(.green)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) { bearer.deleteMedia(for: peer) } label: {
                        Label("Delete media", image: "ic_fa_trash")
                    }
                    Button(role: .destructive) { bearer.deleteConversation(peer) } label: {
                        Label("Delete conversation", image: "ic_fa_trash")
                    }
                } label: { FaIcon(name: "ic_fa_trash", size: 16) }
            }
        }
    }
}

/// Manually add a contact to the address book by base58 address (an empty name falls back
/// to the address; hop.identify fills in the device's own name if it has one).
struct AddContactView: View {
    @ObservedObject var bearer: HopBearer
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("New contact") {
                    TextField("Name (optional)", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Address (base58)", text: $address, axis: .vertical)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced)).lineLimit(1...4)
                    Button("Paste address") {
                        #if canImport(UIKit)
                        if let s = UIPasteboard.general.string { address = s }
                        #endif
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .navigationTitle("Add contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if bearer.addContact(name: name, address: address) {
                            dismiss()
                        } else {
                            error = "Invalid address: need a 32-byte base58 key (and not your own)."
                        }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// hps:// pub/sub (DESIGN.md §32): host a channel/service, subscribe to one by host+path,
/// publish to topics you can write to, and read incoming sender-verified messages.
// MARK: - Channels list (hps:// topics) → per-channel thread

struct ChannelsListView: View {
    @ObservedObject var bearer: HopBearer
    @State private var showAdd = false

    var body: some View {
        List {
            if !bearer.hpsInvites.isEmpty {
                Section("Invites") {
                    ForEach(bearer.hpsInvites, id: \.path) { inv in
                        HStack {
                            FaIcon(name: "ic_fa_envelope", size: 16).foregroundStyle(.orange)
                            VStack(alignment: .leading) {
                                Text(inv.path).font(.callout)
                                Text("from \(bearer.displayName(inv.host))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Accept") { bearer.hpsAcceptInvite(inv) }.buttonStyle(.borderless)
                            Button(role: .destructive) { bearer.hpsDeclineInvite(inv) } label: { Text("Decline") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section(bearer.hpsTopics.isEmpty ? "" : "Channels & services") {
                if bearer.hpsTopics.isEmpty {
                    Text("No channels yet. Tap + to host, subscribe, or browse.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(bearer.hpsTopics) { t in
                    NavigationLink(value: t.id) {
                        HStack {
                            FaIcon(name: t.isChannel ? "ic_fa_comment" : "ic_fa_bullhorn", size: 16)
                                .foregroundStyle(t.hosting ? .green : .blue)
                            VStack(alignment: .leading) {
                                Text(t.path).font(.callout)
                                Text((t.hosting ? "hosting" : "subscribed") + " · " + HopBearer.shortHex(t.host))
                                    .font(.caption2).monospaced().foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let n = bearer.hpsUnread[t.id], n > 0 {
                                Text("\(n)").font(.caption2).bold().foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.red).clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Channels")
        .navigationDestination(for: String.self) { id in
            ChannelView(bearer: bearer, topicId: id)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { FaIcon(name: "ic_fa_plus", size: 18) }
                    .accessibilityLabel("Add channel")
            }
        }
        .sheet(isPresented: $showAdd) { HpsAddView(bearer: bearer) }
    }
}

// MARK: - One channel/service thread

struct ChannelView: View {
    @ObservedObject var bearer: HopBearer
    let topicId: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showInfo = false

    private var topic: HopBearer.HpsTopic? { bearer.hpsTopics.first { $0.id == topicId } }

    var body: some View {
        Group {
            if let t = topic {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(bearer.hpsThreads[topicId] ?? []) { m in
                                let mine = m.sender == bearer.myAddressData
                                VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                                    Text(bearer.displayName(m.sender))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(m.text)
                                        .padding(8)
                                        .background(mine ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
                            }
                        }.padding()
                    }
                    if t.writable {
                        HStack {
                            TextField("Message #\(t.path)", text: $draft)
                                .textFieldStyle(.roundedBorder)
                            Button("Send") {
                                bearer.hpsPublish(topic: t, text: draft.trimmingCharacters(in: .whitespaces))
                                draft = ""
                            }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }.padding(8)
                    } else {
                        Text("Read-only (only the owner broadcasts)")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
                .navigationTitle(t.path)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showInfo = true } label: { FaIcon(name: "ic_fa_circle_info", size: 18) }
                    }
                }
                .sheet(isPresented: $showInfo) { ChannelInfoView(bearer: bearer, topic: t) }
                .onAppear { bearer.openTopic(topicId) }
                .onDisappear { bearer.closeTopic() }
            } else {
                Color.clear.onAppear { dismiss() }   // topic left/removed
            }
        }
    }
}

// MARK: - Channel info / management (invite, requests, members, leave, rekey)

struct ChannelInfoView: View {
    @ObservedObject var bearer: HopBearer
    let topic: HopBearer.HpsTopic
    @Environment(\.dismiss) private var dismiss

    // apple-10: reach/pending/members are snapshotted OFF the render path (fetched async on the core
    // queue via `hpsHostSnapshot`) and held here, so the body never does a synchronous core-queue read
    // that would block the main thread behind the packet drain.
    @State private var snapshot = HopBearer.HpsHostSnapshot()

    /// Re-fetch the host snapshot off-thread. Called on appear and after each mutating action.
    private func refreshSnapshot() {
        guard topic.hosting else { return }
        bearer.hpsHostSnapshot(topic) { snapshot = $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Topic") {
                    LabeledContent("Path", value: topic.path)
                    LabeledContent("Kind", value: topic.isChannel ? "Channel" : "Service")
                    LabeledContent("Role", value: topic.hosting ? "Hosting" : "Subscribed")
                    LabeledContent("Host", value: HopBearer.shortHex(topic.host)).monospaced()
                }

                if topic.hosting {
                    Section("Reach") {
                        LabeledContent("Members", value: "\(snapshot.reach)")
                    }
                    // Invite a contact (host-initiated; consent-based).
                    Section("Invite a contact") {
                        let contacts = bearer.contactList
                        if contacts.isEmpty { Text("No contacts yet").font(.caption).foregroundStyle(.secondary) }
                        ForEach(contacts) { p in
                            Button {
                                bearer.hpsInvite(topic: topic, to: p.address)
                            } label: {
                                Label(p.name, image: "ic_fa_user_plus")
                            }
                        }
                    }
                    // Pending join requests (RequestToJoin).
                    if !snapshot.pending.isEmpty {
                        Section("Join requests") {
                            ForEach(snapshot.pending, id: \.self) { who in
                                HStack {
                                    Text(bearer.displayName(who))
                                    Spacer()
                                    Button("Approve") { bearer.hpsApprove(topic, who); refreshSnapshot() }.buttonStyle(.borderless)
                                    Button(role: .destructive) { bearer.hpsDeny(topic, who); refreshSnapshot() } label: { Text("Deny") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    // Members + remove-and-rekey (revocation).
                    if !snapshot.members.isEmpty {
                        Section("Members (swipe to remove + rekey)") {
                            ForEach(snapshot.members, id: \.self) { who in
                                Text(bearer.displayName(who))
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            bearer.hpsRekey(topic, remove: [who]); refreshSnapshot()
                                        } label: { Label("Remove", image: "ic_fa_user_slash") }
                                    }
                            }
                        }
                        Section {
                            Button("Rotate keys (no removal)") { bearer.hpsRekey(topic); refreshSnapshot() }
                        }
                    }
                } else {
                    Section {
                        Button(role: .destructive) {
                            bearer.hpsLeave(topic); dismiss()
                        } label: { Text("Leave channel") }
                    }
                }
            }
            .navigationTitle(topic.path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { refreshSnapshot() }
        }
    }
}

// MARK: - Host / Subscribe / Browse sheet

struct HpsAddView: View {
    @ObservedObject var bearer: HopBearer
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    // Host
    @State private var newPath = ""
    @State private var isChannel = true
    @State private var access: HpsAccess = .open
    @State private var discoverable = false
    // Subscribe
    @State private var subHost = ""
    @State private var subPath = ""
    // Browse
    @State private var found: [HpsTopicInfo] = []

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $mode) {
                    Text("Host").tag(0); Text("Subscribe").tag(1); Text("Browse").tag(2)
                }.pickerStyle(.segmented)

                if mode == 0 {
                    Section("Host a topic") {
                        TextField("path (e.g. lobby)", text: $newPath)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Picker("Kind", selection: $isChannel) {
                            Text("Channel (anyone writes)").tag(true)
                            Text("Service (only you broadcast)").tag(false)
                        }
                        Picker("Access", selection: $access) {
                            Text("Open").tag(HpsAccess.open)
                            Text("Request to join").tag(HpsAccess.requestToJoin)
                            Text("Invite only").tag(HpsAccess.invite)
                        }
                        Toggle("Discoverable nearby", isOn: $discoverable)
                        Button("Create") {
                            bearer.hpsRegister(path: newPath, channel: isChannel,
                                               access: access, discoverable: discoverable)
                            dismiss()
                        }.disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else if mode == 1 {
                    Section("Subscribe by address") {
                        TextField("host address (base58)", text: $subHost)
                            .autocorrectionDisabled().textInputAutocapitalization(.never).font(.caption).monospaced()
                        TextField("path", text: $subPath)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Subscribe") {
                            bearer.hpsSubscribe(hostBase58: subHost, path: subPath)
                            dismiss()
                        }.disabled(subHost.trimmingCharacters(in: .whitespaces).isEmpty
                                   || subPath.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Section("Discoverable nearby") {
                        if found.isEmpty { Text("None found yet").font(.caption).foregroundStyle(.secondary) }
                        ForEach(found, id: \.path) { t in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(t.path).font(.callout)
                                    Text("\(t.kind == .channel ? "channel" : "service") · \(HopBearer.shortHex(t.host))")
                                        .font(.caption2).monospaced().foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(t.access == .open ? "Join" : "Request") {
                                    bearer.hpsJoin(t); dismiss()
                                }.buttonStyle(.borderless)
                            }
                        }
                        Button("Refresh") { bearer.hpsBrowse { found = $0 } }
                    }
                }
            }
            .navigationTitle("Add channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if mode == 2 { bearer.hpsBrowse { found = $0 } } }
            .onChange(of: mode) { _ in if mode == 2 { bearer.hpsBrowse { found = $0 } } }
        }
    }
}

/// A Font Awesome (Light) icon from the asset catalog, rendered as a tintable template inside a
/// square `size`×`size` frame with scaledToFit so the whole glyph is letterboxed and NEVER clipped
/// (FA paths span the full viewBox: the lock shackle sits at the top edge; constraining a single
/// axis clipped the extremes). Use like an SF Symbol: `FaIcon(name: "ic_fa_lock", size: 12).foregroundStyle(.green)`.
struct FaIcon: View {
    let name: String
    var size: CGFloat = 13
    var body: some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
