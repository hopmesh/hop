import Foundation
import HopFFIBindings

/// The pure snapshot -> UI-row mapping, lifted out of `HopBearer.applyRefresh` (the single biggest method
/// in the driver). Everything here is a value-in / value-out transform with no node, no radio, and no
/// @Published mutation, so it is unit-testable in isolation and keeps `applyRefresh` down to the parts that
/// genuinely need instance state (the bearer-manager link ownership, the identity book, the @Published
/// assignment). Behavior is unchanged: the logic is moved verbatim.
enum RefreshMapper {

    /// Collapse the many retained presence adverts per publisher into one reachable `Peer` each, plus the
    /// name-by-address updates the caller merges. Rules (DESIGN.md §23), preserved exactly:
    ///   • nearest hop count wins for distance,
    ///   • the newest advert (max `createdAt`) wins for the display name/state/platform/app,
    ///   • the returned `names` map is last-write-in-browse-order (which can differ from the newest-advert
    ///     peer name (that pre-existing quirk is retained), keyed by publisher,
    ///   • the reachable list is sorted by the stable address so rows don't jump as hops/names churn.
    static func aggregatePresence(_ hits: [ServiceHit]) -> (reachable: [HopBearer.Peer], names: [Data: String]) {
        struct Agg { var minHops: UInt8; var newestAt: UInt64; var peer: HopBearer.Peer }
        var agg = [Data: Agg]()
        var names = [Data: String]()
        for p in hits {
            let name = p.title.isEmpty ? HopBearer.shortHex(p.publisher) : p.title
            let parts = p.summary.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let active = parts.indices.contains(0) ? parts[0] != "bg" : true
            let platform = parts.indices.contains(1) ? parts[1] : ""
            let app = parts.indices.contains(2) ? parts[2] : ""
            let hops = agg[p.publisher].map { min($0.minHops, p.hops) } ?? p.hops
            if let ex = agg[p.publisher], p.createdAt < ex.newestAt {
                agg[p.publisher] = Agg(minHops: hops, newestAt: ex.newestAt, peer: ex.peer) // older: just refresh hops
            } else {
                let peer = HopBearer.Peer(address: p.publisher, name: name, hops: hops,
                                          active: active, platform: platform, app: app)
                agg[p.publisher] = Agg(minHops: hops, newestAt: p.createdAt, peer: peer)
            }
            names[p.publisher] = name
        }
        var byAddr = [Data: HopBearer.Peer]()
        for (addr, a) in agg {
            let peer = a.peer
            byAddr[addr] = HopBearer.Peer(address: addr, name: peer.name, hops: a.minHops,
                                          active: peer.active, platform: peer.platform, app: peer.app)
        }
        let reachable = byAddr.values.sorted { $0.address.lexicographicallyPrecedes($1.address) }
        return (reachable, names)
    }

    /// The legacy link-id -> transport tag mapping, for a link the node still mints itself (Multipeer,
    /// legacy relay/endpoints) rather than the shared BearerManager. Kept as the fall-back the manager's
    /// real `transportName` takes priority over.
    static func legacyTransportTag(_ link: UInt64) -> String {
        switch link {
        case ..<10_000:  return "BT"
        case ..<20_000:  return "P2P"       // MultipeerConnectivity / AWDL - peer-to-peer Wi-Fi, no router
        case ..<40_000:  return "Relay"     // relay (20k) + hops:// endpoints (30k) aren't local
        default:          return "LAN"        // 40k+ = LAN TCP over a shared network (mDNS)
        }
    }

    /// Per-transport status rows: several bearers run at once, so the headline count is the actual
    /// transport-level connection count from the BearerManager (`active` short-tag -> live-link count),
    /// with Peer-to-Peer (Multipeer, not a shared bearer) added from its own live-link/radio signal.
    /// `states` is the authority on WHICH shared transports exist (every registered bearer, from
    /// `BearerManager.bearerStates()`); `active` only supplies live link counts.
    ///
    /// This used to key off `active` alone, so a transport with no links did not appear at all. That
    /// is fine for a read-only readout and fatal for a settings UI: switching a bearer off drops its
    /// links to zero, so the row you would use to switch it back on is exactly the row that vanishes.
    static func transportStatuses(active: [String: Int], states: [String: Bool],
                                  p2pActive: Bool, p2pLinks: Int) -> [HopBearer.TransportStatus] {
        // Fixed display order, so a toggle never makes rows jump around.
        // "P2P" must be in this list even though it is appended separately below: the trailing
        // unknown-transport loop filters against it, so omitting it made Peer-to-Peer appear TWICE,
        // once under its display name and again under its raw tag.
        let shared: [(tag: String, name: String)] = [
            ("BT", "Bluetooth"), ("P2P", "Peer-to-Peer"), ("LAN", "Local Net"), ("Relay", "Relay"),
        ]
        var ts: [HopBearer.TransportStatus] = []
        func appendShared(_ tag: String, _ name: String) {
            guard let on = states[tag] else { return }        // not registered at all
            let n = active[tag] ?? 0
            ts.append(HopBearer.TransportStatus(id: name, active: n > 0, links: n, tag: tag, enabled: on))
        }
        appendShared("BT", "Bluetooth")
        // Peer-to-Peer IS a shared bearer now, so it carries a real toggle handle instead of `nil`.
        // Until the extraction it was the one Apple transport with no switch, which meant a delivery
        // on an Apple device could never be attributed to BLE with confidence. `p2pActive` still comes
        // from the bearer's own blocked flag, because MultipeerConnectivity reports "cannot advertise"
        // while the Local Network prompt is pending and that is not the same as having no links.
        if let on = states["P2P"] {
            ts.append(HopBearer.TransportStatus(id: "Peer-to-Peer", active: p2pActive && p2pLinks > 0,
                                                links: p2pLinks, tag: "P2P", enabled: on))
        }
        appendShared("LAN", "Local Net")
        appendShared("Relay", "Relay")
        // Any transport a host registered that this display does not know by name still has to be
        // listed, or it would be untoggleable.
        for (tag, on) in states.sorted(by: { $0.key < $1.key }) where !shared.contains(where: { $0.tag == tag }) {
            let n = active[tag] ?? 0
            ts.append(HopBearer.TransportStatus(id: tag, active: n > 0, links: n, tag: tag, enabled: on))
        }
        return ts
    }

    /// Map the node's send/relay queue into display rows (an empty destination renders as "broadcast").
    static func mapQueue(_ items: [QueueItem]) -> [HopBearer.QueueRow] {
        items.map {
            HopBearer.QueueRow(id: $0.id, own: $0.own,
                               to: $0.to.isEmpty ? "broadcast" : HopBearer.shortHex($0.to),
                               priority: $0.priority, hops: $0.hops)
        }
    }

    /// Map the node's live HNS cache into display rows (ticks down each refresh as the node clock advances).
    static func mapHnsCache(_ entries: [HnsCacheEntry]) -> [HopBearer.HnsCacheRow] {
        entries.map { HopBearer.HnsCacheRow(domain: $0.domain, address: $0.address, ttl: $0.ttlSecs) }
    }
}
