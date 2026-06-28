import Foundation

/// A transport link identifier, unique per (re)connection within a Bearer. The consumer keys its
/// own state (sessions, sinks, stats) on this — never on a BLE peripheral handle or MAC.
public typealias LinkId = UInt64

/// Which side opened the underlying connection. The Noise/securing layer in the production consumer
/// maps dialer → initiator, acceptor → responder; the clean-room consumer just logs it.
public enum LinkRole: Sendable {
    case dialer    // we scanned + connected out (central)
    case acceptor  // a peer connected in (peripheral)
}

/// What a Bearer delivers to its consumer. This is the ONLY seam between transport and consumer:
///   • the clean-room harness implements it as a PROOF pinger (counts rx/tx, logs link health);
///   • the production app implements it as the HopNode adapter (node.connected / received /
///     disconnected, then pumps node.drainOutgoing back through `Bearer.send`).
/// Same bearer, two sinks. Callbacks arrive on the bearer's work queue; the consumer hops to its own
/// queue/runloop as needed.
public protocol LinkSink: AnyObject {
    /// A link to `peerId` is up and identity-verified (post-HELLO). `link` is now usable for `send`.
    func linkUp(_ link: LinkId, role: LinkRole, peerId: Data)
    /// One application DATA frame arrived on `link` (transport keepalive/PING frames are consumed
    /// internally by the bearer and never surface here).
    func linkBytes(_ link: LinkId, _ bytes: Data)
    /// `link` is gone (peer/stream close, watchdog, dedup, or stop()). Drop any per-link state.
    func linkDown(_ link: LinkId)
}

/// A transport that discovers peers, forms links, and shuttles application bytes. The bearer owns
/// liveness (keepalive + watchdog) and one-pipe-per-peer dedup internally; the consumer only sees
/// up / bytes / down and calls `send`.
///
/// This is the WHOLE contract — uniform across every transport. It names nothing about BLE, Wi-Fi,
/// sockets, or any radio: a new transport is written purely against `start`/`stop`/`send`/`sink`, then
/// handed to a `BearerManager` via `register(_:)`. Nothing transport-specific crosses this boundary.
public protocol Bearer: AnyObject {
    /// Where this bearer reports link events. The consumer wires itself here directly for a single
    /// bearer; a `BearerManager` wires a per-bearer lane here so it can multiplex many bearers behind
    /// one sink. Implement as `weak` (the sink/manager owns the bearer, so a strong ref would cycle).
    var sink: LinkSink? { get set }
    /// A short, stable transport tag for this bearer (e.g. "BT", "LAN", "Relay") — the SHORT tag the
    /// consumer's per-peer transport map uses. Purely cosmetic: the consumer's UI uses it to label which
    /// radio a link rode in on. NOTHING in routing/dedup/securing depends on it.
    var transportName: String { get }
    /// Begin advertising/scanning (or the transport's equivalent) and forming links.
    func start()
    /// Tear down all links + radios; the sink gets `linkDown` for each live link.
    func stop()
    /// Queue one application DATA frame for delivery on `link`. No-op if `link` is closed.
    func send(_ bytes: Data, on link: LinkId)
}
