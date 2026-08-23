// apple-07 / core-ffi-09: full-stack HopRuntime tests. A pair of loopback bearers registered with
// two HopRuntimes drives the real libhop node seam (linkUp/bytesReceived/drainOutgoing) and the §39
// send -> deliver(+ACK) path end to end, no radios. This exercises the exact multiplexer + node
// wiring every iOS bearer routes through, and also covers the F-26 NULL-on-panic ctor guard.

import XCTest
import Hop
import HopContract

/// A trivial in-memory bearer: it "links up" with a fixed partner on start, and `send` hands bytes
/// straight to the partner as inbound. Exercises the Bearer/LinkSink/Manager/Runtime path minus radio.
private final class LoopbackBearer: Bearer {
    weak var sink: LinkSink?
    let transportName = "LOOP"
    weak var partner: LoopbackBearer?
    private let isDialer: Bool
    private let myPeerId: Data
    private let linkId: LinkId = 1
    init(isDialer: Bool, peerId: Data) { self.isDialer = isDialer; self.myPeerId = peerId }
    func start() { sink?.linkUp(linkId, role: isDialer ? .dialer : .acceptor, peerId: partner?.myPeerId ?? Data()) }
    func stop() { sink?.linkDown(linkId) }
    func send(_ bytes: Data, on link: LinkId) { partner?.deliver(bytes) }
    fileprivate func deliver(_ bytes: Data) { sink?.linkBytes(linkId, bytes) }
}

/// Two nodes on ONE app fabric, wired straight to each other at the node seam, which is all the
/// hps:// paths need to run for real.
///
/// Two choices here are load-bearing. Both nodes get the SAME app secret, because an hps join proof
/// is bound to the app fabric: a pair built on different (or absent) secrets links, handshakes, and
/// then never keys each other, which reads exactly like a broken binding. And the store is
/// `:memory:` because the app-secret constructor is the only one that takes a fabric at all, and no
/// test here wants to survive a restart. This mirrors the core's own two-node hps harness so a Swift
/// failure means the wrapper, not the protocol.
private final class HpsPair {
    let host: HopNode
    let member: HopNode
    let hostAddress: Data
    let memberAddress: Data
    private let hostLink: UInt64 = 11
    private let memberLink: UInt64 = 22

    init?(app: UInt8) {
        let appSecret = Data(repeating: app, count: 32)
        guard let host = HopNode.open(dbPath: ":memory:", appSecret: appSecret),
              let member = HopNode.open(dbPath: ":memory:", appSecret: appSecret) else { return nil }
        self.host = host
        self.member = member
        self.hostAddress = host.address
        self.memberAddress = member.address
        // A real clock BEFORE the link comes up: a prekey advert with no clock is judged expired, and
        // then nothing gossips and no keys request can ever be sealed.
        host.tick(nowMs: 1_700_000_000_000)
        member.tick(nowMs: 1_700_000_000_000)
        host.linkUp(hostLink, role: .dialer)
        member.linkUp(memberLink, role: .acceptor)
        pumpUntilQuiet()
        host.publishPrekey()
        member.publishPrekey()
        pumpUntilQuiet()
    }

    /// Move bytes both directions across the drainOutgoing/bytesReceived seam until neither side has
    /// anything left to send. Bounded, so a regression stalls one test instead of hanging the suite.
    func pumpUntilQuiet(rounds: Int = 1000) {
        for _ in 0..<rounds {
            var moved = false
            host.drainOutgoing { _, bytes in
                moved = true
                self.member.bytesReceived(self.memberLink, bytes)
            }
            member.drainOutgoing { _, bytes in
                moved = true
                self.host.bytesReceived(self.hostLink, bytes)
            }
            if !moved { return }
        }
    }
}

final class HopRuntimeTests: XCTestCase {

    /// F-26: a healthy ephemeral() never returns nil, and the wrapper honors the optional contract.
    func testEphemeralConstructorIsNonNilOnAHealthyBuild() {
        XCTAssertNotNil(HopNode.ephemeral())
        XCTAssertNotNil(HopNode.with(secret: Data()))
    }

    func testEveryFixedWidthInputRejectsNon32ByteBoundaries() {
        guard let node = HopNode.ephemeral() else { return XCTFail("ephemeral nil") }
        let exact = Data(count: 32)
        for count in [0, 1, 31, 33] {
            let invalid = Data(count: count)
            XCTAssertNil(node.send(to: invalid, body: Data([1])), "send accepted \(count) bytes")
            XCTAssertNil(node.sendTo(peer: invalid, body: Data([1])), "sendTo accepted \(count) bytes")
            XCTAssertNil(
                node.sendServiceRequest(to: invalid, service: "svc", method: "get", args: Data()),
                "service request accepted \(count) bytes"
            )
            XCTAssertFalse(node.sendServiceResponse(to: invalid, forRequestId: exact, status: 200, body: Data()))
            XCTAssertFalse(node.sendServiceResponse(to: exact, forRequestId: invalid, status: 200, body: Data()))
            XCTAssertFalse(node.acceptInbox(invalid), "acceptInbox accepted \(count) bytes")
            XCTAssertFalse(node.isSecured(invalid), "isSecured accepted \(count) bytes")
            XCTAssertFalse(node.status(of: invalid).delivered, "status accepted \(count) bytes")
            XCTAssertEqual(HopAddress.base58(invalid), "", "base58 accepted \(count) bytes")
        }

        XCTAssertFalse(HopAddress.base58(exact).isEmpty, "an exact 32-byte address reaches libhop")
        _ = node.status(of: exact)
        _ = node.isSecured(exact)
        _ = node.acceptInbox(exact)
        _ = node.send(to: exact, body: Data([1]))
        _ = node.sendTo(peer: exact, body: Data([1]))
        _ = node.sendServiceRequest(to: exact, service: "svc", method: "get", args: Data())
        _ = node.sendServiceResponse(to: exact, forRequestId: exact, status: 200, body: Data())
    }

    func testRuntimeAndBearerDeliverAndAck() throws {
        guard let nodeA = HopNode.ephemeral(), let nodeB = HopNode.ephemeral() else {
            return XCTFail("ephemeral() returned nil")
        }
        let aId = randomNodeId(), bId = randomNodeId()
        let bearerA = LoopbackBearer(isDialer: nodeIdGreater(aId, bId), peerId: aId)
        let bearerB = LoopbackBearer(isDialer: nodeIdGreater(bId, aId), peerId: bId)
        bearerA.partner = bearerB; bearerB.partner = bearerA

        let rtA = HopRuntime(node: nodeA)
        let rtB = HopRuntime(node: nodeB)

        var now: UInt64 = 1_700_000_000_000
        rtA.tick(nowMs: now); rtB.tick(nowMs: now)
        rtA.node.publishPrekey(); rtB.node.publishPrekey()
        let aAddr = rtA.node.address
        let bAddr = rtB.node.address

        rtA.register(bearerA); rtB.register(bearerB)
        rtA.start(); rtB.start()

        func pump(_ rounds: Int, _ done: () -> Bool = { false }) -> Bool {
            for _ in 0..<rounds {
                rtA.pump(); rtB.pump()
                now += 100; rtA.tick(nowMs: now); rtB.tick(nowMs: now)
                if done() { return true }
            }
            return done()
        }

        _ = pump(50)   // handshake + prekey gossip through the loopback bearers

        let text = "hello through HopRuntime + a Bearer"
        guard let id = rtA.node.send(to: bAddr, body: Data(text.utf8), requestAck: true) else {
            return XCTFail("send returned nil")
        }

        var rejected: HopMessage?
        let sawRejected = pump(400) {
            rtB.node.pollInboxAccepting {
                rejected = $0
                return false
            }
            return rejected != nil
        }
        XCTAssertTrue(sawRejected, "host should see the durable inbox item")
        XCTAssertFalse(rtA.node.status(of: id).delivered, "a rejected host write must not emit the ACK")

        var got: HopMessage?
        var accepted = false
        let ok = pump(400) {
            rtB.node.pollInbox { got = $0 }
            if let message = got, !accepted {
                accepted = rtB.node.acceptInbox(message.id)
            }
            return got != nil && rtA.node.status(of: id).delivered
        }

        XCTAssertTrue(ok, "message should deliver and ACK within the pump budget")
        XCTAssertTrue(accepted, "host acceptance should succeed after persistence")
        XCTAssertEqual(got?.id, rejected?.id, "redelivery keeps the stable inbox id")
        XCTAssertEqual(got.flatMap { String(data: $0.body, encoding: .utf8) }, text)
        XCTAssertTrue(rtA.node.status(of: id).delivered, "sender sees delivered=true after ACK")
        XCTAssertFalse(rtB.node.acceptInbox(Data(count: 31)), "short inbox ids are rejected")
        XCTAssertFalse(rtB.node.acceptInbox(Data(count: 33)), "long inbox ids are rejected")

        guard let requestId = rtA.node.sendServiceRequest(
            to: bAddr, service: "weather", method: "get", args: Data("kar".utf8)
        ) else { return XCTFail("service request returned nil") }
        var request: HopServiceRequest? = nil
        XCTAssertTrue(pump(400) {
            rtB.node.pollServiceRequests { request = $0 }
            return request != nil
        })
        XCTAssertEqual(request?.from, aAddr)
        XCTAssertTrue(rtB.node.sendServiceResponse(
            to: request!.from,
            forRequestId: request!.requestId,
            status: 200,
            body: Data("sunny".utf8)
        ))
        var response: HopServiceResponse? = nil
        XCTAssertTrue(pump(400) {
            rtA.node.pollServiceResponses { response = $0 }
            return response != nil
        })
        XCTAssertEqual(response?.forRequestId, requestId)
        var redelivered: HopServiceResponse? = nil
        rtA.node.pollServiceResponses { redelivered = $0 }
        XCTAssertEqual(redelivered?.forRequestId, requestId)
        XCTAssertTrue(rtA.node.acceptServiceResponse(forRequestId: requestId))
        var afterAcceptance: HopServiceResponse? = nil
        rtA.node.pollServiceResponses { afterAcceptance = $0 }
        XCTAssertNil(afterAcceptance)
    }

    /// The runtime routes a global link id back to the owning bearer on pump().
    func testRuntimeTagsTheLinkTransport() {
        guard let node = HopNode.ephemeral() else { return XCTFail("ephemeral nil") }
        let rt = HopRuntime(node: node, baseLinkId: 1_000_000)
        let a = LoopbackBearer(isDialer: true, peerId: randomNodeId())
        let b = LoopbackBearer(isDialer: false, peerId: randomNodeId())
        a.partner = b; b.partner = a
        rt.register(a)
        rt.start()   // brings up global link 1_000_000
        XCTAssertEqual(rt.bearers.transportName(of: 1_000_000), "LOOP")
    }

    // MARK: §19 relay pool (PLAT-003)

    /// sdk/hop.h justified the v4 -> v5 ABI bump with the §19 relay-pool calls, and this wrapper
    /// asserted that level on first use while binding none of them, so an SDK-only integrator could
    /// not fail over: with no relay call on HopNode, the only usable RelayBearer constructor is the
    /// fixed-URL one, and one dead endpoint ended internet reach until the app restarted. The
    /// wrapper now pins ABI 6 and binds the relay pool, and this test is what makes the binding
    /// load-bearing rather than merely present.
    ///
    /// This drives the failover through the SAME closure shape RelayBearer's pooled constructor takes
    /// (`resolveURL` / `reportOutcome`), built ONLY from the published SDK, on one node that is never
    /// recreated. That is the SDK-only host surviving its configured relay going dark.
    func testRelayPoolFailsOverThroughAnSdkBuiltResolverWithoutRestarting() {
        guard let node = HopNode.ephemeral() else { return XCTFail("ephemeral nil") }
        node.tick(nowMs: 1_700_000_000_000)

        // Exactly what a host hands RelayBearer(resolveURL:reportOutcome:), with nothing but the SDK.
        let resolveURL: () -> String? = { node.relayNext() }
        let reportOutcome: (String, Bool) -> Void = { url, ok in node.relayReport(url, ok: ok) }

        // An empty pool is distinguishable from a backed-off one: nothing to dial, nothing pooled.
        XCTAssertNil(resolveURL())
        XCTAssertEqual(node.relayPool().total, 0)
        XCTAssertEqual(node.relayPool().available, 0)

        let a = "wss://relay-a.example/_hop"
        let b = "wss://relay-b.example/_hop"
        XCTAssertTrue(node.relayAdd(a), "a configured endpoint must be pooled")
        XCTAssertTrue(node.relayAdd(b), "a second configured endpoint must be pooled")
        XCTAssertEqual(node.relayPool().total, 2)
        XCTAssertEqual(node.relayPool().available, 2)

        guard let first = resolveURL() else { return XCTFail("a pooled endpoint should be dialable") }
        XCTAssertTrue(first == a || first == b, "unexpected first dial target \(first)")

        // A working relay is kept: no needless churn between two healthy candidates.
        reportOutcome(first, true)
        XCTAssertEqual(resolveURL(), first, "a healthy relay must not be abandoned")

        // It goes dark. The resolver must now hand back the other candidate, with no restart.
        reportOutcome(first, false)
        guard let second = resolveURL() else {
            return XCTFail("failover target missing after the configured relay died")
        }
        XCTAssertNotEqual(second, first, "no failover: still dialing the dead relay \(first)")

        // Everything down is WAIT, not offline, and the SDK can tell the two apart.
        for url in [first, first, second, second] { reportOutcome(url, false) }
        XCTAssertNil(resolveURL(), "every candidate is backed off, so there is nothing to dial")
        XCTAssertEqual(node.relayPool().total, 2)
        XCTAssertEqual(node.relayPool().available, 0)
    }

    // MARK: hps:// pub/sub (DESIGN.md section 32)

    /// The whole reason the hps surface was added to the C ABI, driven end to end through the SDK
    /// only: host a channel, join it from a second node, publish once, and the subscriber gets that
    /// ONE publication with the writer verified. One content-key-encrypted, per-writer-signed
    /// publication flooded once, not fan-out and not a bundle per member, so the subscriber count is
    /// exactly one no matter how the topic grows.
    func testAChannelPublicationReachesASubscriberAndIsGoneOnceAccepted() {
        guard let pair = HpsPair(app: 6) else { return XCTFail("HpsPair returned nil") }
        let path = "room"

        guard let key = pair.host.hpsRegister(path: path, kind: .channel,
                                              access: .open, visibility: .topicPrivate) else {
            return XCTFail("hpsRegister returned nil for a channel")
        }
        XCTAssertTrue(key.isEmpty, "a channel has no service key: its writers sign as themselves")
        pair.pumpUntilQuiet()

        guard let subscribeId = pair.member.hpsSubscribe(host: pair.hostAddress, path: path) else {
            return XCTFail("hpsSubscribe returned nil")
        }
        XCTAssertEqual(subscribeId.count, 32)
        XCTAssertNotEqual(subscribeId, Data(count: 32), "a real bundle id, not an untouched buffer")
        pair.pumpUntilQuiet()   // open access, so the host hands the keys back unprompted

        let body = Data("hello room".utf8)
        guard let publishId = pair.host.hpsPublish(path: path, body: body) else {
            return XCTFail("hpsPublish returned nil")
        }
        XCTAssertNotEqual(publishId, Data(count: 32))
        pair.pumpUntilQuiet()

        var received: [HopHpsMessage] = []
        pair.member.pollHpsMessagesAccepting { message in
            received.append(message)
            return true   // returning true IS the durable acceptance, no separate accept needed
        }
        XCTAssertEqual(received.count, 1, "one flooded publication reaches the subscriber")
        XCTAssertEqual(received.first?.path, path)
        XCTAssertEqual(received.first?.sender, pair.hostAddress, "sender is the VERIFIED writer")
        XCTAssertEqual(received.first?.body, body)

        var redelivered: [HopHpsMessage] = []
        pair.member.pollHpsMessagesAccepting { message in
            redelivered.append(message)
            return true
        }
        XCTAssertTrue(redelivered.isEmpty, "an accepted publication is durably removed, not requeued")
    }

    /// The invite-mode key handoff, and the revocation that ends it. An invite-only topic hands out
    /// nothing when it is browsed or invited: keys are sealed only after the destination accepts,
    /// which is why membership is a property of the key handoff rather than of a recipient list.
    ///
    /// This also pins the browse row's field order. `hop_hps_browse` hands a Swift callback SEVEN
    /// arguments, so a kind or access read out of the wrong slot would still compile and would show a
    /// closed topic as open: asserting both discriminants is what catches that.
    func testAnInviteKeysAMemberAndARekeyRevokesThem() {
        guard let pair = HpsPair(app: 8) else { return XCTFail("HpsPair returned nil") }
        let path = "vip"
        XCTAssertNotNil(pair.host.hpsRegister(path: path, kind: .channel,
                                              access: .invite, visibility: .discoverable))
        pair.pumpUntilQuiet()
        pair.pumpUntilQuiet()   // the discovery advert is a second round trip, as in the core harness

        guard let seen = pair.member.hpsBrowse().first(where: { $0.path == path }) else {
            return XCTFail("the discoverable topic never reached browse")
        }
        XCTAssertEqual(seen.host, pair.hostAddress)
        XCTAssertEqual(seen.kind, .channel, "browse decoded the kind slot")
        XCTAssertEqual(seen.access, .invite, "browse decoded the access slot, not the kind again")

        XCTAssertNotNil(pair.host.hpsInvite(path: path, dest: pair.memberAddress))
        pair.pumpUntilQuiet()
        var invites: [HopHpsInvite] = []
        pair.member.pollHpsInvites { invites.append($0) }
        XCTAssertEqual(invites.count, 1, "the member drains the invite")
        XCTAssertEqual(invites.first?.path, path)
        XCTAssertEqual(invites.first?.host, pair.hostAddress)
        XCTAssertEqual(invites.first?.kind, .channel)

        // Take-and-clear, unlike the publication queue: a second drain has nothing, so a host that
        // does not persist what it surfaced has silently lost the invite.
        var again: [HopHpsInvite] = []
        pair.member.pollHpsInvites { again.append($0) }
        XCTAssertTrue(again.isEmpty, "a drained invite is gone")

        XCTAssertNotNil(pair.member.hpsAcceptInvite(host: pair.hostAddress, path: path))
        pair.pumpUntilQuiet()
        XCTAssertTrue(pair.host.hpsMembers(path: path).contains(pair.memberAddress),
                      "accepting is what earns the keys, so the host now retains the member")

        // A mis-sized removal is DROPPED, so this is an ordinary rotation and the member is retained.
        // If the wrapper packed the short entry instead, the buffer would slide and this member would
        // be the one revoked by a call that named nobody.
        XCTAssertFalse(pair.host.hpsRekey(path: path, remove: [Data(count: 31)]).isEmpty,
                       "a rotation seals the new key to the retained member")
        pair.pumpUntilQuiet()
        XCTAssertTrue(pair.host.hpsMembers(path: path).contains(pair.memberAddress),
                      "a 31-byte entry revoked a member it had no right to name")

        // Naming them properly is the revocation: they keep the dead key and nothing published after.
        _ = pair.host.hpsRekey(path: path, remove: [pair.memberAddress])
        pair.pumpUntilQuiet()
        XCTAssertFalse(pair.host.hpsMembers(path: path).contains(pair.memberAddress),
                       "a rekey naming the member drops them from the retained set")
    }

    /// A publication the host REFUSES stays queued, and the standalone accept clears it later. A host
    /// that dies between the poll and its own persistence has to see the post again, or a channel
    /// silently drops it: that is why the sink's return value, not the poll, is the removal.
    func testARefusedPublicationIsRedeliveredUntilAcceptHpsMessageSucceeds() {
        guard let pair = HpsPair(app: 7) else { return XCTFail("HpsPair returned nil") }
        let path = "feed"
        XCTAssertNotNil(pair.host.hpsRegister(path: path, kind: .channel,
                                              access: .open, visibility: .topicPrivate))
        pair.pumpUntilQuiet()
        XCTAssertNotNil(pair.member.hpsSubscribe(host: pair.hostAddress, path: path))
        pair.pumpUntilQuiet()
        XCTAssertNotNil(pair.host.hpsPublish(path: path, body: Data("keep me".utf8)))
        pair.pumpUntilQuiet()

        var first: HopHpsMessage?
        pair.member.pollHpsMessages { first = $0 }   // the non-accepting poll refuses every row
        guard let queued = first else { return XCTFail("the subscriber never saw the publication") }

        var second: HopHpsMessage?
        pair.member.pollHpsMessages { second = $0 }
        XCTAssertEqual(second?.id, queued.id, "a refused publication keeps its stable id and returns")

        XCTAssertTrue(pair.member.acceptHpsMessage(queued.id))
        var afterAcceptance: HopHpsMessage?
        pair.member.pollHpsMessages { afterAcceptance = $0 }
        XCTAssertNil(afterAcceptance, "acceptHpsMessage removes the row the sink left queued")
    }

    /// `hpsRegister` reports success through its RESULT and the key length separately, so a channel
    /// is EMPTY data rather than nil. A wrapper that folded the two together would report every
    /// channel a host just created as a failed registration, and channels are the common case.
    func testRegisterSeparatesAServiceKeyFromAChannelsAbsentKey() {
        guard let node = HopNode.ephemeral() else { return XCTFail("ephemeral nil") }
        let service = node.hpsRegister(path: "feed", kind: .service,
                                       access: .requestToJoin, visibility: .discoverable)
        XCTAssertEqual(service?.count, 32, "a service exposes the key its broadcasts are signed with")

        let channel = node.hpsRegister(path: "room", kind: .channel,
                                       access: .open, visibility: .topicPrivate)
        XCTAssertNotNil(channel, "a channel registration SUCCEEDS")
        XCTAssertEqual(channel, Data(), "and carries no key, which is not a failure")
    }

    /// Every 32-byte hps argument is checked in the wrapper before it can reach native code as a
    /// short pointer, the same guard the §39 send path has. A mis-sized address is refused, never
    /// padded or truncated into a different valid address.
    func testHpsAddressArgumentsRejectNon32ByteBoundaries() {
        guard let node = HopNode.ephemeral() else { return XCTFail("ephemeral nil") }
        XCTAssertNotNil(node.hpsRegister(path: "room", kind: .channel,
                                         access: .requestToJoin, visibility: .topicPrivate))
        for count in [0, 1, 31, 33] {
            let invalid = Data(count: count)
            XCTAssertNil(node.hpsSubscribe(host: invalid, path: "room"), "subscribe took \(count) bytes")
            XCTAssertNil(node.hpsInvite(path: "room", dest: invalid), "invite took \(count) bytes")
            XCTAssertNil(node.hpsApprove(path: "room", requester: invalid), "approve took \(count) bytes")
            XCTAssertNil(node.hpsAcceptInvite(host: invalid, path: "room"), "accept took \(count) bytes")
            XCTAssertFalse(node.hpsDeclineInvite(host: invalid, path: "room"), "decline took \(count)")
            XCTAssertFalse(node.hpsDeny(path: "room", requester: invalid), "deny took \(count) bytes")
            XCTAssertFalse(node.acceptHpsMessage(invalid), "accept took \(count) bytes")
        }

        // A rekey drops a mis-sized removal rather than packing it: the C call reads count * 32 bytes
        // from one buffer, so a short entry would slide every later address and revoke a member nobody
        // named. Dropping it leaves an ordinary rotation, which on a memberless topic seals nothing.
        XCTAssertTrue(node.hpsRekey(path: "room", remove: [Data(count: 31)]).isEmpty)
    }

    /// `hpsMyTopics` is how an app rebuilds its channel list after a restart, since the node persists
    /// topics and an in-memory list does not. `hosting` and `access` are what a UI reads to decide
    /// whether to offer moderation at all, so a topic that came back with either one wrong would put
    /// approve/deny controls on a topic this node cannot moderate.
    func testMyTopicsReportsAHostedTopicWithItsAccessMode() {
        guard let node = HopNode.ephemeral() else { return XCTFail("ephemeral nil") }
        XCTAssertNotNil(node.hpsRegister(path: "lobby", kind: .channel,
                                         access: .requestToJoin, visibility: .topicPrivate))

        let mine = node.hpsMyTopics()
        guard let topic = mine.first(where: { $0.path == "lobby" }) else {
            return XCTFail("hpsMyTopics lost the hosted topic; saw \(mine.map(\.path))")
        }
        XCTAssertTrue(topic.hosting, "we registered it, so we host it")
        XCTAssertEqual(topic.kind, .channel)
        XCTAssertEqual(topic.access, .requestToJoin, "the access mode it was registered with")
        XCTAssertEqual(topic.host, node.address, "a hosted topic's host is this node")
        XCTAssertEqual(node.hpsReach(path: "lobby"), 0, "nothing has acked, so reach is honestly 0")
        XCTAssertTrue(node.hpsPending(path: "lobby").isEmpty, "nobody has asked to join yet")
        XCTAssertTrue(node.hpsMembers(path: "lobby").isEmpty)

        // Leaving a topic we HOST sends no bundle, so no id is a SUCCESS, not a failure.
        let left = node.hpsLeave(path: "lobby")
        XCTAssertTrue(left.ok, "leaving a hosted topic succeeds")
        XCTAssertNil(left.id, "and emits no bundle to report")
    }
}
