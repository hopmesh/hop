import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @StateObject private var bearer = HopBearer.shared
    @State private var started = false
    @State private var nameField = ""
    @State private var relayField = ""
    @State private var hopsField = ""
    @State private var showAddContact = false

    private var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        "Hop device"
        #endif
    }

    private var direct: [HopBearer.Peer] { bearer.reachable.filter { $0.hops <= 1 } }
    private var mesh: [HopBearer.Peer] { bearer.reachable.filter { $0.hops >= 2 } }

    var body: some View {
        TabView {
            chatsTab.tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            channelsTab.tabItem { Label("Channels", systemImage: "dot.radiowaves.left.and.right") }
            webTab.tabItem { Label("Web", systemImage: "globe") }
            statusTab.tabItem { Label("Status", systemImage: "gearshape") }
        }
        .onAppear {
            guard !started else { return }
            started = true
            let name = HopBearer.savedName(default: deviceName)
            nameField = name
            bearer.start(name: name)
        }
    }

    // MARK: - Tab 1: Chats — people you can reach → chat thread (shared IA)
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
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddContact = true } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Add contact")
                }
            }
            .sheet(isPresented: $showAddContact) { AddContactView(bearer: bearer) }
        }
    }

    // MARK: - Tab 2: Channels — hps:// pub/sub
    @ViewBuilder private var channelsTab: some View {
        NavigationStack {
            HpsView(bearer: bearer).navigationTitle("Channels")
        }
    }

    // MARK: - Tab 3: Web — hops:// fetch + browser, HNS cache
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
                        Label("Open in hops:// browser", systemImage: "globe")
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
                                Image(systemName: rec.address.isEmpty ? "xmark.circle" : "magnifyingglass")
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

    // MARK: - Tab 4: Status — device, relay, transports, backbone, queue
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
                        Text("Anycast (default). A device uses one relay at a time — pin a direct address to test a specific relay.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } header: { Text("Cloud relay (backbone)") }

                Section("Transports") {
                    ForEach(bearer.transports) { t in
                        DisclosureGroup {
                            let addrs = peersOn(t.id)
                            ForEach(addrs, id: \.self) { addr in
                                HStack {
                                    Image(systemName: transportIcon(transportTag(t.id)))
                                        .font(.caption2).foregroundStyle(.secondary)
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
                                Circle().fill(t.active ? Color.green : Color.red).frame(width: 8, height: 8)
                                Text(t.id)
                                Spacer()
                                Text(t.active ? "\(t.links) linked" : "off")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !bearer.relays.isEmpty {
                    Section("Relays (backbone)") {
                        ForEach(bearer.relays) { r in
                            HStack {
                                Image(systemName: "cloud.fill").foregroundStyle(.blue)
                                VStack(alignment: .leading) {
                                    Text(r.name)
                                    Text(HopBearer.shortHex(r.address))
                                        .font(.caption2).monospaced().foregroundStyle(.secondary)
                                }
                                Spacer()
                                if bearer.routed.contains(r.address) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.caption2).foregroundStyle(.blue).help("learned route")
                                }
                            }
                        }
                    }
                }

                if !bearer.endpoints.isEmpty {
                    Section("hops:// endpoints") {
                        ForEach(bearer.endpoints) { e in
                            HStack {
                                Image(systemName: "globe").foregroundStyle(.green)
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
                            Image(systemName: row.own ? "pin.fill" : "arrow.triangle.swap")
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
                                Label("Clear", systemImage: "trash").labelStyle(.titleAndIcon)
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

    /// "iOS" / "Android" / "" from the raw platform tag.
    private func platformLabel(_ p: String) -> String {
        switch p { case "ios": return "iOS"; case "android": return "Android"; default: return p }
    }

    /// Subtitle: address · platform · app (omitting empties).
    private func subline(_ peer: HopBearer.Peer) -> String {
        [HopBearer.shortHex(peer.address), platformLabel(peer.platform), peer.app]
            .filter { !$0.isEmpty }.joined(separator: " · ")
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
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.green)
                        }
                        if bearer.routed.contains(peer.address) {
                            Image(systemName: "arrow.triangle.branch").font(.caption2)
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
                            Image(systemName: transportIcon(tag)).font(.caption2)
                                .foregroundStyle(.secondary).help(tag)
                        }
                    }
                } else {
                    Text("\(peer.hops) hops").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// SF Symbol for a transport tag ("BT" / "Wi-Fi" / "Relay").
    private func transportIcon(_ tag: String) -> String {
        switch tag {
        case "BT": return "dot.radiowaves.left.and.right"
        case "Wi-Fi": return "wifi"
        case "Relay": return "cloud.fill"
        default: return "link"
        }
    }

    /// Map a TransportStatus id to the tag used in `linkTransports`.
    private func transportTag(_ id: String) -> String { id == "Bluetooth" ? "BT" : id }

    /// Addresses currently linked over a given transport (by its status id).
    private func peersOn(_ id: String) -> [Data] {
        let tag = transportTag(id)
        return bearer.linkTransports.filter { $0.value.contains(tag) }.map { $0.key }
            .sorted { bearer.displayName($0) < bearer.displayName($1) }
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

    /// One-line metadata under a bubble.
    /// Incoming: "2 hops, 1m" (path length + send→receive time).
    /// Outgoing: "Delivered, 10 hops, 2h" once acked, else "Sent, 2 peers" / "Sending…".
    private func meta(_ m: HopBearer.Message) -> String {
        if m.incoming {
            var s = HopBearer.hopsLabel(m.hops)
            if let lat = m.latencyMs { s += ", \(HopBearer.compactDuration(lat))" }
            return s
        }
        if m.delivered, let d = m.deliveredAt {
            let dur = HopBearer.compactDuration(UInt64(max(0, d.timeIntervalSince(m.sentAt)) * 1000))
            return "Delivered, \(HopBearer.hopsLabel(m.deliveryHops)), \(dur)"
        }
        if m.failed { return "Not sent" }
        return m.relayed > 0 ? "Sent, \(m.relayed) peer\(m.relayed == 1 ? "" : "s")" : "Sending…"
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
                                if let img = UIImage(data: data) {
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
                            Text(meta(m)).font(.caption2).foregroundStyle(.secondary)
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
                            if let img = UIImage(data: data) {
                                Image(uiImage: img).resizable().scaledToFill()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(alignment: .topTrailing) {
                                        Button { attached.remove(at: idx) } label: {
                                            Image(systemName: "xmark.circle.fill").font(.caption2)
                                        }
                                    }
                            }
                        }
                    }.padding(.horizontal)
                }
            }
            HStack {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 8, matching: .images) {
                    Image(systemName: "photo.on.rectangle").imageScale(.large)
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
                           let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.7) {
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
                        Image(systemName: "cloud.fill").font(.caption).foregroundStyle(.blue)
                    }
                    if bearer.secured.contains(peer.address) {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.green)
                    }
                }
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
                            error = "Invalid address — need a 32-byte base58 key (and not your own)."
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
struct HpsView: View {
    @ObservedObject var bearer: HopBearer

    @State private var newPath = ""
    @State private var newIsChannel = true
    @State private var subHost = ""
    @State private var subPath = ""
    @State private var pubText = ""
    @State private var pubPath = ""

    var body: some View {
        List {
            Section("Host a topic") {
                TextField("path (e.g. lobby)", text: $newPath)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Picker("Kind", selection: $newIsChannel) {
                    Text("Channel (anyone writes)").tag(true)
                    Text("Service (only you broadcast)").tag(false)
                }
                .pickerStyle(.segmented)
                Button("Register") {
                    bearer.hpsRegister(path: newPath, channel: newIsChannel)
                    newPath = ""
                }
                .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("Subscribe") {
                TextField("host address (base58)", text: $subHost)
                    .autocorrectionDisabled().textInputAutocapitalization(.never).font(.caption).monospaced()
                TextField("path", text: $subPath)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Subscribe") {
                    bearer.hpsSubscribe(hostBase58: subHost, path: subPath)
                    subPath = ""
                }
                .disabled(subHost.trimmingCharacters(in: .whitespaces).isEmpty
                          || subPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !bearer.hpsTopics.isEmpty {
                Section("Topics") {
                    ForEach(bearer.hpsTopics) { t in
                        HStack {
                            Image(systemName: t.isChannel ? "bubble.left.and.bubble.right" : "megaphone")
                                .foregroundStyle(t.hosting ? .green : .blue)
                            VStack(alignment: .leading) {
                                Text(t.path).font(.callout)
                                Text(t.hosting ? "hosting · \(HopBearer.shortHex(t.host))"
                                               : "subscribed · \(HopBearer.shortHex(t.host))")
                                    .font(.caption2).monospaced().foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Writable: a channel (anyone), or a service we host.
                            if t.isChannel || t.hosting {
                                Button { pubPath = t.path } label: { Image(systemName: "square.and.pencil") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            Section("Publish") {
                if pubPath.isEmpty {
                    Text("Tap ✎ on a writable topic above").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("→ \(pubPath)").font(.caption).monospaced().foregroundStyle(.secondary)
                    HStack {
                        TextField("message", text: $pubText).onSubmit(publish)
                        Button("Send", action: publish)
                            .disabled(pubText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            Section("Messages") {
                if bearer.hpsInbox.isEmpty {
                    Text("none yet").foregroundStyle(.secondary)
                }
                ForEach(bearer.hpsInbox) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(m.path).font(.caption2).monospaced().foregroundStyle(.secondary)
                            Spacer()
                            Text(bearer.displayName(m.sender)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(m.text).font(.callout).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("hps:// pub/sub")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func publish() {
        bearer.hpsPublish(path: pubPath, text: pubText)
        pubText = ""
    }
}
