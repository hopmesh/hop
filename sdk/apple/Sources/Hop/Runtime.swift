// Runtime: ties a HopNode (libhop) to the BearerManager. Lives in Hop (needs the node); the
// bearer contract it drives lives in HopContract.
import Foundation
import HopContract

/// Ties a HopNode (the C ABI) to a BearerManager: every bearer link drives the node's seam, and
/// `pump()` drains the node's outbound packets back to the owning bearer. A host creates a node, adds
/// the bearer packages it wants, then start() + pump() on its loop.
public final class HopRuntime {
    public let node: HopNode
    public let bearers: BearerManager

    private final class NodeSink: LinkSink {
        unowned let node: HopNode
        init(_ node: HopNode) { self.node = node }
        func linkUp(_ link: LinkId, role: HopRole, peerId: Data) { node.linkUp(link, role: role) }  // node learns identity via Noise
        func linkBytes(_ link: LinkId, _ bytes: Data) { node.bytesReceived(link, bytes) }
        func linkDown(_ link: LinkId) { node.linkDown(link) }
    }
    private lazy var nodeSink = NodeSink(node)

    public init(node: HopNode, baseLinkId: LinkId = 1_000_000) {
        self.node = node
        self.bearers = BearerManager(baseLinkId: baseLinkId)
        self.bearers.sink = nodeSink
    }

    public func register(_ bearer: Bearer) { bearers.register(bearer) }
    public func start() { bearers.start() }
    public func stop() { bearers.stop() }

    /// Drain the node's queued outbound packets, routing each to the bearer that owns its link.
    public func pump() { node.drainOutgoing { link, bytes in self.bearers.send(bytes, on: link) } }
    public func tick(nowMs: UInt64) { node.tick(nowMs: nowMs) }
}
