package sh.hopme.bearers

// The transport <-> consumer seam. The Android mirror of apple/HopBearers' LinkSink.swift, same
// semantics, byte-for-byte: a Bearer forms links to peers and shuttles application bytes; the
// consumer only ever sees up / bytes / down and calls send. This file names NOTHING transport- or
// BLE-specific: a new transport is written purely against start/stop/send/sink, then handed to a
// BearerManager via register().

/// A transport link identifier, unique per (re)connection within a Bearer. The consumer keys its own
/// state on this, never on a BLE peripheral handle or MAC. (Swift: `UInt64`.)
typealias LinkId = Long

/// Which side opened the underlying connection. The securing layer maps dialer -> initiator,
/// acceptor -> responder; the clean-room consumer just logs it.
enum class LinkRole { DIALER, ACCEPTOR }

/// What a Bearer delivers to its consumer. This is the ONLY seam between transport and consumer:
///   - the clean-room harness implements it as a PROOF pinger (counts rx/tx, logs link health);
///   - the production app implements it as the HopNode adapter.
/// Same bearer, two sinks.
///
/// NOTE (Android): unlike Apple's single-run-loop model, these callbacks arrive from MULTIPLE threads;
/// each transport surfaces them from its own workers (per-link rx threads, accept threads, discovery
/// callbacks, keepalive timers). Implementations MUST guard any shared state accordingly.
interface LinkSink {
    /// A link to `peerId` is up and identity-verified (post-HELLO). `link` is now usable for `send`.
    fun linkUp(link: LinkId, role: LinkRole, peerId: ByteArray)

    /// One application DATA frame arrived on `link`. Transport keepalive (PING/PONG) frames are
    /// consumed internally by the bearer and NEVER surface here.
    fun linkBytes(link: LinkId, bytes: ByteArray)

    /// `link` is gone (peer/stream close, watchdog, dedup, or stop()). Drop any per-link state.
    fun linkDown(link: LinkId)
}

/// A transport that discovers peers, forms links, and shuttles application bytes. The bearer owns
/// liveness (keepalive + watchdog) and one-pipe-per-peer dedup internally; the consumer only sees
/// up / bytes / down and calls `send`. This is the WHOLE contract, uniform across every transport.
interface Bearer {
    /// Where this bearer reports link events. The consumer wires itself here for a single bearer; a
    /// BearerManager wires a per-bearer lane here so it can multiplex many bearers behind one sink.
    var sink: LinkSink?

    /// A short, stable transport tag for this bearer (e.g. "BT", "LAN", "Wi-Fi Direct", "Relay"), the
    /// SHORT tag the consumer's per-peer transport map uses. Purely cosmetic: the consumer's UI uses it
    /// to label which radio a link rode in on. NOTHING in routing/dedup/securing depends on it.
    val transportName: String

    /// Begin advertising/scanning (or the transport's equivalent) and forming links.
    fun start()

    /// Tear down all links + radios; the sink gets `linkDown` for each live link.
    fun stop()

    /// Queue one application DATA frame for delivery on `link`. No-op if `link` is closed.
    fun send(bytes: ByteArray, link: LinkId)
}
