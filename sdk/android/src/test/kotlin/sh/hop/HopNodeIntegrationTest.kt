package sh.hop

import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * cov/kotlin: drives the REAL libhop through [HopNode] over an in-memory loopback, covering the
 * JNA/native surface (HopNode + its Companion + lifecycle owner + HopAddress base58) that the radio-free
 * unit tests deliberately can't reach. Each native-touching test skips (assumeLibhop) when the lib
 * isn't built, so the pure-Kotlin suite still runs standalone.
 */
class HopNodeIntegrationTest {

    @Test
    fun ephemeralExposesA32ByteAddress() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            assertEquals(32, n.address().size)
        }
    }

    @Test
    fun withSecretRestoresTheSameIdentity() {
        assumeLibhop()
        HopNode.ephemeral().use { a ->
            val secret = a.secret()
            assertEquals(32, secret.size)
            HopNode.withSecret(secret).use { b ->
                assertTrue(
                    a.address().contentEquals(b.address()),
                    "the same identity secret must restore the same address",
                )
            }
        }
    }

    @Test
    fun openIsPersistentForARealPathAndFallsBackForABadOne() {
        assumeLibhop()
        val dir = Files.createTempDirectory("hop-kt-open").toFile()
        try {
            val node = HopNode.open(File(dir, "node.db").absolutePath)
            assertNotNull(node)
            node!!.use {
                assertTrue(it.isPersistent(), "a real path opens with durable storage")
                assertEquals(0, it.rehydrateDropped(), "a fresh db drops nothing on rehydrate")
            }
            // F-26: a path under a non-existent directory can't be opened. A valid-UTF-8 path never
            // returns null, so the node still comes back but runs EPHEMERALLY (isPersistent == false).
            val fallback = HopNode.open("/no/such/hop-kt-dir/node.db")
            assertNotNull(fallback)
            fallback!!.use { assertFalse(it.isPersistent(), "an unusable path falls back to ephemeral") }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun openKeyedYieldsAPersistentNode() {
        assumeLibhop()
        val dir = Files.createTempDirectory("hop-kt-keyed").toFile()
        try {
            val key = ByteArray(32) { (it * 7).toByte() }
            val node = HopNode.openKeyed(File(dir, "node.db").absolutePath, key)
            assertNotNull(node)
            node!!.use { assertTrue(it.isPersistent()) }
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun sendDeliversAcksAndReportsFullStatus() {
        assumeLibhop()
        HopNode.ephemeral().use { a ->
            HopNode.ephemeral().use { b ->
                val loop = DirectLoopback(a, b)
                loop.handshake()
                val bAddr = b.address()

                val text = "hello over the C ABI from a Kotlin integration test"
                val id = a.send(bAddr, body = text.toByteArray(), requestAck = true)
                assertNotNull(id)
                assertEquals(32, id!!.size)

                var rejected: HopMessage? = null
                val sawRejected = loop.pump(400) {
                    b.pollInboxAccepting {
                        rejected = it
                        false
                    }
                    rejected != null
                }
                assertTrue(sawRejected, "the host should see the durable inbox item")
                assertFalse(a.delivered(id), "a rejected host write must not emit the ACK")

                var got: HopMessage? = null
                var accepted = false
                val ok = loop.pump(400) {
                    b.pollInbox { got = it }
                    if (!accepted) got?.let { accepted = b.acceptInbox(it.id) }
                    got != null && a.delivered(id)
                }
                assertTrue(ok, "the message should deliver and ack over loopback")
                assertTrue(accepted, "host acceptance should succeed after persistence")

                val msg = got!!
                assertTrue(msg.id.contentEquals(rejected!!.id), "redelivery keeps the stable inbox id")
                assertEquals(text, String(msg.body))
                assertTrue(msg.hops >= 0u)
                assertEquals(msg.body.toList(), msg.bodyCopy().toList()) // defensive-copy accessors
                assertEquals(32, msg.fromCopy().size)

                // status() reads ALL FOUR out-params (relayed / delivered / forwardHops / forwardMs).
                val st = a.status(id)
                assertTrue(st.delivered)
                assertTrue(st.relayed >= 1, "at least one peer was handed a copy")
                assertTrue(st.forwardHops >= 0u)
                assertTrue(st.forwardMs >= 0)
                assertFailsWith<IllegalArgumentException> { b.acceptInbox(ByteArray(31)) }
                assertFailsWith<IllegalArgumentException> { b.acceptInbox(ByteArray(33)) }

                // a forward-secret ratchet session now exists to B (the lock indicator).
                assertTrue(a.isSecured(bAddr))

                // sendTo: a directed send to the now directly-connected peer.
                val tracedId = a.sendTo(bAddr, body = "traced".toByteArray())
                assertNotNull(tracedId)
                assertEquals(32, tracedId!!.size)
            }
        }
    }

    @Test
    fun singleNodeIdentityAndPubSubSurface() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            n.setName("kotlin-integration")
            n.subscribe("hps://weather/kar")
            assertTrue(n.publishPrekey())
            assertEquals(0, n.rehydrateDropped())
            assertFalse(n.isPersistent(), "an ephemeral node has no durable storage")
            assertEquals(32, n.secret().size)
            assertFalse(n.isSecured(ByteArray(32) { 9 }), "no session to an unknown address")
        }
    }

    @Test
    fun serviceRequestResponseRoundTrips() {
        assumeLibhop()
        HopNode.ephemeral().use { a ->
            HopNode.ephemeral().use { b ->
                val loop = DirectLoopback(a, b)
                loop.handshake()
                val aAddr = a.address()
                val bAddr = b.address()

                val reqId = a.sendServiceRequest(bAddr, "weather", "get", "kar".toByteArray())
                assertNotNull(reqId)

                var req: HopServiceRequest? = null
                val gotReq = loop.pump(400) { b.pollServiceRequests { req = it }; req != null }
                assertTrue(gotReq, "B should receive the service request")
                val r = req!!
                assertTrue(r.from.contentEquals(aAddr))
                assertEquals("weather", r.service)
                assertEquals("get", r.method)
                assertEquals("kar", String(r.args))
                assertEquals(32, r.requestIdCopy().size)
                assertEquals(32, r.fromCopy().size)
                assertEquals("kar", String(r.argsCopy()))

                assertTrue(b.sendServiceResponse(r.from, r.requestId, 200, "sunny".toByteArray()))

                var resp: HopServiceResponse? = null
                val gotResp = loop.pump(400) { a.pollServiceResponses { resp = it }; resp != null }
                assertTrue(gotResp, "A should receive the service response")
                val rr = resp!!
                assertTrue(rr.from.contentEquals(bAddr))
                assertTrue(rr.forRequestId.contentEquals(reqId!!))
                assertEquals(200, rr.status)
                assertEquals("sunny", String(rr.body))
                assertEquals(32, rr.fromCopy().size)
                assertEquals(32, rr.forRequestIdCopy().size)
                assertEquals("sunny", String(rr.bodyCopy()))
                var redelivered: HopServiceResponse? = null
                a.pollServiceResponses { redelivered = it }
                assertNotNull(redelivered, "a non-accepting callback must leave the response queued")
                assertTrue(a.acceptServiceResponse(rr.forRequestId))
                var afterAcceptance: HopServiceResponse? = null
                a.pollServiceResponses { afterAcceptance = it }
                assertNull(afterAcceptance, "explicit acceptance must stop redelivery")
            }
        }
    }

    // ---- F-27 safety: idempotent close + handle guard ----

    @Test
    fun doubleCloseIsANoOp() {
        assumeLibhop()
        val n = HopNode.ephemeral()
        n.close()
        n.close() // idempotent: must not double-free the native handle or throw
    }

    @Test
    fun useAfterCloseThrows() {
        assumeLibhop()
        val n = HopNode.ephemeral()
        n.close()
        val ex = assertFailsWith<IllegalStateException> { n.address() }
        assertEquals("HopNode used after close()", ex.message)
    }

    @Test
    fun deprecatedFreeDelegatesToClose() {
        assumeLibhop()
        val n = HopNode.ephemeral()
        @Suppress("DEPRECATION")
        n.free()
        // free() delegated to close(); the handle is now null, so any further use trips the guard.
        assertFailsWith<IllegalStateException> { n.publishPrekey() }
    }

    // ---- HopAddress base58 (the native encode/decode path) ----

    @Test
    fun base58RoundTripsAndRejectsGarbage() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            val addr = n.address()
            val b58 = HopAddress.base58(addr)
            assertTrue(b58.isNotEmpty())
            assertTrue(HopAddress.fromBase58(b58)?.contentEquals(addr) == true, "base58 must round-trip")
            assertNull(HopAddress.fromBase58("garbage"), "a non-address string decodes to null")
            assertNull(HopAddress.fromBase58("not valid base58 !!!"), "invalid base58 chars decode to null")
        }
    }

    // ---- §19 relay pool (PLAT-003) ----

    /**
     * sdk/hop.h justified the v4 -> v5 ABI bump with the §19 relay-pool calls, and the wrapper that
     * now pins ABI 7 asserted its level at load while binding none of them, so a host built on the
     * published SDK could not fail over: the only reachable behavior was retrying one configured URL
     * forever. Drives the failover the header describes on ONE node that is never recreated.
     */
    @Test
    fun relayPoolFailsOverToAnotherEndpointWithoutRecreatingTheNode() {
        assumeLibhop()
        HopNode.ephemeral().use { n ->
            n.tick(1_700_000_000_000L)
            // An empty pool is distinguishable from a backed-off one: nothing to dial, nothing pooled.
            assertNull(n.relayNext(), "an empty pool has nothing to dial")
            assertEquals(HopRelayPool(total = 0, available = 0), n.relayPool())

            val a = "wss://relay-a.example/_hop"
            val b = "wss://relay-b.example/_hop"
            assertTrue(n.relayAdd(a), "a configured endpoint must be pooled")
            assertTrue(n.relayAdd(b), "a second configured endpoint must be pooled")
            assertEquals(HopRelayPool(total = 2, available = 2), n.relayPool())

            val first = n.relayNext()
            assertTrue(first == a || first == b, "unexpected first dial target: $first")

            // A working relay is kept: no needless churn between two healthy candidates.
            n.relayReport(first, true)
            assertEquals(first, n.relayNext(), "a healthy relay must not be abandoned")

            // It goes dark. THIS is the case the header promised and the wrapper could not reach.
            n.relayReport(first, false)
            val second = n.relayNext()
            assertNotNull(second, "failover target missing after the configured relay died")
            assertTrue(second != first, "no failover: still dialing the dead relay $first")

            // Everything down is WAIT, not offline, and the wrapper can tell the two apart.
            for (url in listOf(first, first, second, second)) n.relayReport(url, false)
            assertNull(n.relayNext(), "every candidate is backed off, so there is nothing to dial")
            assertEquals(HopRelayPool(total = 2, available = 0), n.relayPool())
        }
    }

    // ---- §32 hps:// pub/sub (PLAT-005) ----
    //
    // The v5 -> v6 bump exists because the C ABI exported NONE of §32, so this wrapper could not
    // reach channels or group chat at all while the protocol had shipped in both UniFFI drivers for
    // as long as it existed. These tests drive the whole handoff over the real library: hosting,
    // joining, one flooded publication, moderation, invites, revocation and discovery.
    //
    // A publication is ONE content-key-encrypted, per-writer-signed message flooded once, not a
    // per-member fan-out and not a multicast bundle. Membership is therefore a property of the key
    // handoff, which is exactly what the pumps below are shuttling.

    /**
     * Two nodes on the SAME app secret. hps join proofs are keyed to the app fabric, so two nodes on
     * different (or absent) app secrets link happily and then never key each other, which would fail
     * every test below for a reason that has nothing to do with the binding.
     */
    private fun hpsPair(app: Byte): Pair<HopNode, HopNode> {
        val appSecret = ByteArray(32) { app }
        val a = HopNode.open(":memory:", appSecret = appSecret)
        val b = HopNode.open(":memory:", appSecret = appSecret)
        assertNotNull(a, "node A must open")
        assertNotNull(b, "node B must open")
        return Pair(a!!, b!!)
    }

    /** [hpsPair] plus the loopback handshake, closing both nodes afterwards. */
    private fun withHpsPair(app: Byte, body: (HopNode, HopNode, DirectLoopback) -> Unit) {
        val (a, b) = hpsPair(app)
        a.use {
            b.use {
                val loop = DirectLoopback(a, b)
                loop.handshake()
                body(a, b, loop)
            }
        }
    }

    @Test
    fun aHostedChannelReachesASubscriberOnAnotherNode() {
        assumeLibhop()
        withHpsPair(6) { a, b, loop ->
            val aAddr = a.address()

            // Host. A channel has no service key, so an EMPTY array is the SUCCESS case: the bool
            // return, not the key length, is what says the topic was registered, and collapsing an
            // empty key to null would report a hosted channel as a failure.
            val channelKey = a.hpsRegister("room", HpsKind.CHANNEL, HpsAccess.OPEN, HpsVisibility.PRIVATE)
            assertNotNull(channelKey, "hosting a channel must succeed")
            assertEquals(0, channelKey!!.size, "a channel exposes no service key")
            loop.pump(20)

            // Join. OPEN access means the host hands the keys over unprompted.
            val subId = b.hpsSubscribe(aAddr, "room")
            assertNotNull(subId)
            assertEquals(32, subId!!.size)
            assertFalse(subId.all { it == 0.toByte() }, "a real subscribe bundle id, not a zero buffer")
            loop.pump(20)

            // Publish once. ONE flooded publication, whatever the member count.
            val pubId = a.hpsPublish("room", "hello room".toByteArray())
            assertNotNull(pubId)
            assertEquals(32, pubId!!.size)

            var got: HopHpsMessage? = null
            val arrived = loop.pump(400) {
                b.pollHpsMessagesAccepting { m ->
                    got = m
                    true
                }
                got != null
            }
            assertTrue(arrived, "the subscriber should receive the publication")
            val msg = got!!
            assertEquals("room", msg.path)
            assertTrue(msg.sender.contentEquals(aAddr), "sender is the VERIFIED writer, not the relay")
            assertEquals("hello room", String(msg.body))
            assertEquals(32, msg.idCopy().size)                     // defensive-copy accessors
            assertEquals(32, msg.senderCopy().size)
            assertEquals("hello room", String(msg.bodyCopy()))

            // Accepted synchronously, so it is durably gone. That is the queue contract the poll
            // model rests on, identical to the inbox.
            var again: HopHpsMessage? = null
            b.pollHpsMessages { again = it }
            assertNull(again, "an accepted publication must not be redelivered")

            // A flood has no per-recipient receipt, so reach is the only honest delivery number, and
            // it can never exceed this topic's single subscriber. An unknown path has none at all.
            assertTrue(a.hpsReach("room") <= 1, "reach cannot exceed the one subscriber")
            assertEquals(0, a.hpsReach("no-such-room"), "an unknown path has no reach")

            // The subscriber's own list carries the followed topic, which is what an app rebuilds
            // its channel list from after a restart.
            val followed = b.hpsMyTopics().firstOrNull { it.path == "room" }
            assertNotNull(followed, "the subscriber's topic list should carry the followed channel")
            assertFalse(followed!!.hosting, "the subscriber does not host it")
            assertEquals(HpsKind.CHANNEL, followed.kind)
        }
    }

    @Test
    fun anUnacceptedPublicationIsRedeliveredUntilAcceptedById() {
        assumeLibhop()
        withHpsPair(7) { a, b, loop ->
            assertNotNull(a.hpsRegister("feed", HpsKind.CHANNEL, HpsAccess.OPEN, HpsVisibility.PRIVATE))
            loop.pump(20)
            assertNotNull(b.hpsSubscribe(a.address(), "feed"))
            loop.pump(20)
            assertNotNull(a.hpsPublish("feed", "keep me".toByteArray()))

            // Refusing acceptance leaves the row queued: a host that dies between surfacing a post
            // and persisting it has to see the post again, or a channel silently drops it.
            var first: HopHpsMessage? = null
            val queued = loop.pump(400) {
                b.pollHpsMessages { first = it }
                first != null
            }
            assertTrue(queued, "the subscriber should receive the publication")
            var second: HopHpsMessage? = null
            b.pollHpsMessages { second = it }
            assertNotNull(second, "a refused publication must be redelivered")
            assertTrue(first!!.id.contentEquals(second!!.id), "redelivery keeps the stable queue id")
            assertEquals(first, second, "content-based equality over the same publication")
            assertEquals(first.hashCode(), second.hashCode())

            // Accept it out of band, by id, the way a host that persisted asynchronously would.
            assertTrue(b.acceptHpsMessage(first!!.id))
            var afterAcceptance: HopHpsMessage? = null
            b.pollHpsMessages { afterAcceptance = it }
            assertNull(afterAcceptance, "explicit acceptance must stop redelivery")
            assertFalse(b.acceptHpsMessage(first!!.id), "accepting twice is a clean false, not a throw")
        }
    }

    @Test
    fun requestToJoinNeedsHostApprovalAndRevocationIsAKeyRotation() {
        assumeLibhop()
        withHpsPair(8) { a, b, loop ->
            val bAddr = b.address()
            assertNotNull(a.hpsRegister("lobby", HpsKind.CHANNEL, HpsAccess.REQUEST_TO_JOIN, HpsVisibility.PRIVATE))
            loop.pump(20)
            assertNotNull(b.hpsSubscribe(a.address(), "lobby"))

            // Queued, NOT keyed: the whole point of the mode.
            var pending: List<ByteArray> = emptyList()
            val asked = loop.pump(400) {
                pending = a.hpsPending("lobby")
                pending.isNotEmpty()
            }
            assertTrue(asked, "the requester should be queued for approval")
            assertEquals(1, pending.size)
            assertTrue(pending[0].contentEquals(bAddr))
            assertTrue(a.hpsMembers("lobby").none { it.contentEquals(bAddr) }, "queued is not a member")

            // Approve: only now are the keys sealed, and the request leaves the queue.
            val keysId = a.hpsApprove("lobby", bAddr)
            assertNotNull(keysId)
            assertEquals(32, keysId!!.size)
            loop.pump(50)
            assertTrue(a.hpsPending("lobby").isEmpty(), "an approved request leaves the queue")
            assertTrue(a.hpsMembers("lobby").any { it.contentEquals(bAddr) }, "approval makes them a member")

            // A rotation with nothing removed re-keys the retained member: one bundle per member.
            val kept = a.hpsRekey("lobby")
            assertEquals(1, kept.size, "the retained member is re-keyed")
            assertEquals(32, kept[0].size)
            loop.pump(50)

            // Revocation IS the rotation: there is no per-member copy to delete, so removing a member
            // means minting a key they never receive. Nothing is left to re-key here.
            assertTrue(a.hpsRekey("lobby", remove = listOf(bAddr)).isEmpty(), "no retained member to re-key")
            assertTrue(a.hpsMembers("lobby").none { it.contentEquals(bAddr) },
                       "a removed member is no longer re-keyed")

            // A path this node already holds keys for cannot be re-requested: the keys are already
            // here, so core refuses the join rather than re-queueing an existing member.
            assertNull(b.hpsSubscribe(a.address(), "lobby"),
                       "a second subscribe to an already-keyed path must fail")

            // Deny drops a request without sealing anything, on a path B has never joined.
            assertNotNull(a.hpsRegister("green-room", HpsKind.CHANNEL, HpsAccess.REQUEST_TO_JOIN,
                                        HpsVisibility.PRIVATE))
            loop.pump(20)
            assertNotNull(b.hpsSubscribe(a.address(), "green-room"))
            val queuedAgain = loop.pump(400) { a.hpsPending("green-room").isNotEmpty() }
            assertTrue(queuedAgain, "the requester should be queued on the new path")
            assertTrue(a.hpsDeny("green-room", bAddr))
            assertTrue(a.hpsPending("green-room").isEmpty(), "a denied request leaves the queue")
            assertTrue(a.hpsMembers("green-room").none { it.contentEquals(bAddr) }, "deny seals no keys")
        }
    }

    @Test
    fun anInviteReachesTheDestinationAndAcceptingItKeysThem() {
        assumeLibhop()
        withHpsPair(9) { a, b, loop ->
            val aAddr = a.address()
            val bAddr = b.address()
            assertNotNull(a.hpsRegister("vip", HpsKind.CHANNEL, HpsAccess.INVITE, HpsVisibility.DISCOVERABLE))
            loop.pump(50)

            val inviteId = a.hpsInvite("vip", bAddr)
            assertNotNull(inviteId)
            assertEquals(32, inviteId!!.size)

            val invites = ArrayList<HopHpsInvite>()
            val delivered = loop.pump(400) {
                b.pollHpsInvites { invites.add(it) }
                invites.isNotEmpty()
            }
            assertTrue(delivered, "the destination should receive the invite")
            assertEquals(1, invites.size)
            assertTrue(invites[0].host.contentEquals(aAddr))
            assertEquals("vip", invites[0].path)
            assertEquals(HpsKind.CHANNEL, invites[0].kind)
            assertEquals(32, invites[0].hostCopy().size)

            // Take-and-clear, not accept-to-remove: an invite this drain surfaced is GONE, which is
            // why a host has to persist what it shows.
            val drainedTwice = ArrayList<HopHpsInvite>()
            b.pollHpsInvites { drainedTwice.add(it) }
            assertTrue(drainedTwice.isEmpty(), "a drained invite must not come back")

            assertNotNull(b.hpsAcceptInvite(aAddr, "vip"))
            loop.pump(50)
            assertTrue(a.hpsMembers("vip").any { it.contentEquals(bAddr) },
                       "accepting an invite makes the destination a member")

            // The host's own list reports it hosting, with the access mode it registered.
            val hosted = a.hpsMyTopics().firstOrNull { it.path == "vip" }
            assertNotNull(hosted)
            assertTrue(hosted!!.hosting, "the host reports hosting == true")
            assertEquals(HpsAccess.INVITE, hosted.access, "the registered access mode survives the round trip")
            assertEquals(HpsKind.CHANNEL, hosted.kind)
            assertTrue(hosted.host.contentEquals(aAddr))
            assertEquals(32, hosted.hostCopy().size)
            assertTrue(b.hpsMyTopics().any { it.path == "vip" && !it.hosting },
                       "the member's list carries the followed topic")

            // Declining is durable: it is dropped from storage, so it cannot reappear.
            assertNotNull(a.hpsInvite("vip", bAddr))
            loop.pump(50)
            assertTrue(b.hpsDeclineInvite(aAddr, "vip"))
            val afterDecline = ArrayList<HopHpsInvite>()
            b.pollHpsInvites { afterDecline.add(it) }
            assertTrue(afterDecline.isEmpty(), "a declined invite leaves nothing to drain")
        }
    }

    @Test
    fun aServiceKeyIsRealAndADiscoverableTopicIsBrowsableBySameAppPeers() {
        assumeLibhop()
        withHpsPair(10) { a, b, loop ->
            // A SERVICE has a signing key (only its owner broadcasts, signed by it). That is the
            // other half of the register contract: a real 32-byte key here, an empty array for a
            // channel, and null for neither.
            val serviceKey = a.hpsRegister("town-square", HpsKind.SERVICE, HpsAccess.OPEN, HpsVisibility.DISCOVERABLE)
            assertNotNull(serviceKey, "hosting a service must succeed")
            assertEquals(32, serviceKey!!.size, "a service exposes its signing key")
            assertFalse(serviceKey.all { it == 0.toByte() }, "a real key, not a zeroed buffer")
            loop.pump(50)

            // Browse only ever surfaces same-app topics: the descriptor is encrypted to the app secret.
            var seen: List<HopHpsTopicInfo> = emptyList()
            val browsable = loop.pump(400) {
                seen = b.hpsBrowse()
                seen.any { it.path == "town-square" }
            }
            assertTrue(browsable, "a discoverable topic should be browsable by a same-app peer, saw $seen")
            val info = seen.first { it.path == "town-square" }
            assertEquals(HpsKind.SERVICE, info.kind)
            assertEquals(HpsAccess.OPEN, info.access, "browse carries what joining would cost")
            assertTrue(info.host.contentEquals(a.address()))
            assertEquals(32, info.hostCopy().size)

            // Leaving a topic we HOST sends no bundle: ok with a null id is a SUCCESS, not a failure.
            val leftHosted = a.hpsLeave("town-square")
            assertTrue(leftHosted.ok, "leaving a hosted topic succeeds")
            assertNull(leftHosted.id, "a hosted topic has no leave bundle to send")
            assertNull(leftHosted.idCopy())

            // Leaving one we FOLLOW does send a bundle, so the host stops re-keying us.
            assertNotNull(a.hpsRegister("hall", HpsKind.CHANNEL, HpsAccess.OPEN, HpsVisibility.PRIVATE))
            loop.pump(20)
            assertNotNull(b.hpsSubscribe(a.address(), "hall"))
            val joined = loop.pump(400) { b.hpsMyTopics().any { it.path == "hall" } }
            assertTrue(joined, "the subscriber should be following the channel")
            val leftFollowed = b.hpsLeave("hall")
            assertTrue(leftFollowed.ok)
            assertNotNull(leftFollowed.id, "leaving a followed topic sends a leave bundle")
            assertEquals(32, leftFollowed.id!!.size)
            assertEquals(32, leftFollowed.idCopy()!!.size)
        }
    }

    @Test
    fun aMisSizedAddressIsRejectedBeforeItReachesNativeCode() {
        assumeLibhop()
        // require32's whole reason for existing: every one of these C calls reads EXACTLY 32 bytes
        // from the pointer regardless of the Kotlin array's length, so a short array reads out of
        // bounds in native code and a long one is silently truncated. Fail loudly instead.
        HopNode.ephemeral().use { n ->
            assertFailsWith<IllegalArgumentException> { n.hpsSubscribe(ByteArray(31), "room") }
            assertFailsWith<IllegalArgumentException> { n.hpsInvite("room", ByteArray(33)) }
            assertFailsWith<IllegalArgumentException> { n.hpsAcceptInvite(ByteArray(0), "room") }
            assertFailsWith<IllegalArgumentException> { n.hpsDeclineInvite(ByteArray(31), "room") }
            assertFailsWith<IllegalArgumentException> { n.hpsApprove("room", ByteArray(31)) }
            assertFailsWith<IllegalArgumentException> { n.hpsDeny("room", ByteArray(33)) }
            assertFailsWith<IllegalArgumentException> { n.acceptHpsMessage(ByteArray(31)) }
            // A mis-sized entry in the packed remove buffer matters more than most: the addresses go
            // back to back and the COUNT is what native reads, so one short entry would shift every
            // later address by a few bytes and revoke the WRONG members.
            assertFailsWith<IllegalArgumentException> {
                n.hpsRekey("room", remove = listOf(ByteArray(32), ByteArray(4)))
            }
        }
    }

    @Test
    fun hpsValueTypesAreContentBasedWithIndependentCopies() {
        // The §32 value types carry mutable ByteArrays, so they hand-roll content equality and expose
        // *Copy() accessors (a data class cannot copy from its generated getters). These two contracts
        // are what a forensic or aliasing bug would break, and neither is reachable from the mesh
        // tests above: they live here rather than in HopValueTypesTest because §32 ownership keeps the
        // whole hps surface, wrapper and proof, in one place.
        val host = ByteArray(32) { 3 }
        val msg = HopHpsMessage(id = ByteArray(32) { 1 }, path = "room", sender = host, body = "hi".toByteArray())
        assertEquals(msg, HopHpsMessage(ByteArray(32) { 1 }, "room", ByteArray(32) { 3 }, "hi".toByteArray()))
        assertEquals(msg.hashCode(), HopHpsMessage(ByteArray(32) { 1 }, "room", ByteArray(32) { 3 }, "hi".toByteArray()).hashCode())
        assertNotEquals(msg, msg.copy(path = "other"))
        assertNotEquals(msg, msg.copy(id = ByteArray(32) { 9 }))
        assertNotEquals(msg, msg.copy(sender = ByteArray(32) { 9 }))
        assertNotEquals(msg, msg.copy(body = "bye".toByteArray()))
        assertFalse(msg.equals(null))
        assertFalse(msg.equals("not a publication"))
        assertTrue(msg.equals(msg))
        msg.idCopy()[0] = 0x7f
        msg.senderCopy()[0] = 0x7f
        msg.bodyCopy()[0] = 0x7f
        assertEquals(1.toByte(), msg.id[0], "idCopy must not alias the publication")
        assertEquals(3.toByte(), msg.sender[0], "senderCopy must not alias the publication")
        assertEquals('h'.code.toByte(), msg.body[0], "bodyCopy must not alias the publication")

        val invite = HopHpsInvite(host = host, path = "vip", kind = HpsKind.CHANNEL)
        assertEquals(invite, HopHpsInvite(ByteArray(32) { 3 }, "vip", HpsKind.CHANNEL))
        assertEquals(invite.hashCode(), HopHpsInvite(ByteArray(32) { 3 }, "vip", HpsKind.CHANNEL).hashCode())
        assertNotEquals(invite, invite.copy(kind = HpsKind.SERVICE))
        assertNotEquals(invite, invite.copy(path = "other"))
        assertNotEquals(invite, invite.copy(host = ByteArray(32) { 9 }))
        assertFalse(invite.equals(null))
        assertFalse(invite.equals(42))
        assertTrue(invite.equals(invite))
        invite.hostCopy()[0] = 0x7f
        assertEquals(3.toByte(), invite.host[0])

        val topic = HopHpsTopic(host, "room", HpsKind.CHANNEL, hosting = true, access = HpsAccess.INVITE)
        assertEquals(topic, HopHpsTopic(ByteArray(32) { 3 }, "room", HpsKind.CHANNEL, true, HpsAccess.INVITE))
        assertEquals(topic.hashCode(),
                     HopHpsTopic(ByteArray(32) { 3 }, "room", HpsKind.CHANNEL, true, HpsAccess.INVITE).hashCode())
        assertNotEquals(topic, topic.copy(hosting = false))
        assertNotEquals(topic, topic.copy(access = HpsAccess.OPEN))
        assertNotEquals(topic, topic.copy(kind = HpsKind.SERVICE))
        assertNotEquals(topic, topic.copy(path = "other"))
        assertNotEquals(topic, topic.copy(host = ByteArray(32) { 9 }))
        assertFalse(topic.equals(null))
        assertFalse(topic.equals("x"))
        assertTrue(topic.equals(topic))
        topic.hostCopy()[0] = 0x7f
        assertEquals(3.toByte(), topic.host[0])

        val info = HopHpsTopicInfo(host, "town-square", HpsKind.SERVICE, "Town Square", "everyone", HpsAccess.OPEN)
        assertEquals(info, HopHpsTopicInfo(ByteArray(32) { 3 }, "town-square", HpsKind.SERVICE, "Town Square",
                                           "everyone", HpsAccess.OPEN))
        assertEquals(info.hashCode(),
                     HopHpsTopicInfo(ByteArray(32) { 3 }, "town-square", HpsKind.SERVICE, "Town Square",
                                     "everyone", HpsAccess.OPEN).hashCode())
        assertNotEquals(info, info.copy(title = "other"))
        assertNotEquals(info, info.copy(summary = "other"))
        assertNotEquals(info, info.copy(access = HpsAccess.REQUEST_TO_JOIN))
        assertNotEquals(info, info.copy(kind = HpsKind.CHANNEL))
        assertNotEquals(info, info.copy(path = "other"))
        assertNotEquals(info, info.copy(host = ByteArray(32) { 9 }))
        assertFalse(info.equals(null))
        assertFalse(info.equals(1.0))
        assertTrue(info.equals(info))
        info.hostCopy()[0] = 0x7f
        assertEquals(3.toByte(), info.host[0])

        // A leave with no id is a hosted-topic success, so null-vs-null must compare equal and a
        // present id must not compare equal to an absent one.
        val hostedLeave = HopHpsLeave(ok = true, id = null)
        val followedLeave = HopHpsLeave(ok = true, id = ByteArray(32) { 5 })
        assertEquals(hostedLeave, HopHpsLeave(true, null))
        assertEquals(hostedLeave.hashCode(), HopHpsLeave(true, null).hashCode())
        assertEquals(followedLeave, HopHpsLeave(true, ByteArray(32) { 5 }))
        assertEquals(followedLeave.hashCode(), HopHpsLeave(true, ByteArray(32) { 5 }).hashCode())
        assertNotEquals(hostedLeave, followedLeave)
        assertNotEquals(followedLeave, hostedLeave)
        assertNotEquals(followedLeave, followedLeave.copy(ok = false))
        assertNotEquals(followedLeave, followedLeave.copy(id = ByteArray(32) { 9 }))
        assertFalse(hostedLeave.equals(null))
        assertFalse(hostedLeave.equals("x"))
        assertTrue(hostedLeave.equals(hostedLeave))
        assertNull(hostedLeave.idCopy())
        followedLeave.idCopy()!![0] = 0x7f
        assertEquals(5.toByte(), followedLeave.id!![0], "idCopy must not alias the value")
    }

    @Test
    fun hpsEnumsCarryTheExactWireDiscriminants() {
        // These ints ARE the C ABI contract (HopHpsKind / HopHpsAccess / HopHpsVisibility in hop.h).
        // An out-of-range discriminant FAILS the native call rather than defaulting, because reading
        // a garbage int as OPEN would hand a topic's content key to anyone who asks; an exhaustive
        // enum is what keeps a bad value unreachable from this side.
        assertEquals(0, HpsKind.CHANNEL.c)
        assertEquals(1, HpsKind.SERVICE.c)
        assertEquals(0, HpsAccess.OPEN.c)
        assertEquals(1, HpsAccess.REQUEST_TO_JOIN.c)
        assertEquals(2, HpsAccess.INVITE.c)
        assertEquals(0, HpsVisibility.PRIVATE.c)
        assertEquals(1, HpsVisibility.DISCOVERABLE.c)
    }
}
