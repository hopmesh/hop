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
public protocol Bearer: AnyObject {
    /// Begin advertising/scanning (or the transport's equivalent) and forming links.
    func start()
    /// Tear down all links + radios; the sink gets `linkDown` for each live link.
    func stop()
    /// Queue one application DATA frame for delivery on `link`. No-op if `link` is closed.
    func send(_ bytes: Data, on link: LinkId)
}
