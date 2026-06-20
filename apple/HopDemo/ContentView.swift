import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @StateObject private var bearer = HopBearer.shared
    @State private var started = false
    @State private var nameField = ""
    @State private var urlField = "https://example.com"
    @State private var relayField = ""

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

                Section("Cloud relay (backbone)") {
                    HStack {
                        TextField("host:port or wss://relay.hopme.sh/", text: $relayField)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        Button("Connect") {
                            let a = relayField.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !a.isEmpty { bearer.connectRelay(a) }
                        }
                    }
                    LabeledContent("Relay", value: bearer.relayStatus).font(.caption)
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

                Section("Web via gateway (Use Case A)") {
                    TextField("https://…", text: $urlField)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    if bearer.reachable.isEmpty {
                        Text("no gateway peer reachable").foregroundStyle(.secondary)
                    } else {
                        ForEach(bearer.reachable) { gw in
                            Button("Fetch via \(gw.name)") {
                                let u = urlField.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !u.isEmpty { bearer.fetch(u, via: gw) }
                            }
                        }
                    }
                    ForEach(Array(bearer.httpResults.prefix(6).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2).foregroundStyle(.secondary)
                    }
                }

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
            .navigationTitle(bearer.totalUnread > 0 ? "Hop (\(bearer.totalUnread))" : "Hop")
            .navigationDestination(for: HopBearer.Peer.self) { peer in
                ChatView(bearer: bearer, peer: peer)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            let name = HopBearer.savedName(default: deviceName)
            nameField = name
            bearer.start(name: name)
        }
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
        return m.relayed > 0 ? "Sent, \(m.relayed) peer\(m.relayed == 1 ? "" : "s")" : "Sending…"
    }

    var body: some View {
        VStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(thread) { m in
                        VStack(alignment: m.incoming ? .leading : .trailing, spacing: 2) {
                            HStack {
                                if !m.incoming { Spacer() }
                                Text(m.text)
                                    .padding(8)
                                    .background(m.incoming ? Color.gray.opacity(0.2) : Color.accentColor.opacity(0.25))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                if m.incoming { Spacer() }
                            }
                            Text(meta(m)).font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: m.incoming ? .leading : .trailing)
                            // Provenance: who/what carried each hop, resolved to display
                            // names where known (DESIGN.md §27/§29).
                            if m.incoming, !m.trace.isEmpty {
                                Text("path: " + m.trace.map { bearer.traceLabel($0) }.joined(separator: " → "))
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding()
            }
            HStack {
                TextField("Message \(peer.name)", text: $draft).textFieldStyle(.roundedBorder)
                Button("Send") {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    bearer.send(t, to: peer)
                    draft = ""
                }
            }
            .padding()
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
