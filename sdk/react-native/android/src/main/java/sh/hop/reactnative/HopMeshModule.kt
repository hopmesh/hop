// The Android half of @hop-mesh/react-native: a React Native module that wraps the Kotlin Hop client
// SDK (sdk/android, the `sh.hop` package) and exposes it to JavaScript. Binary values cross the bridge
// as base64 strings and addresses as base58 strings, matching ios/ and src/native.ts.
//
// Node handles are integers minted here; the module keeps a handle -> (HopNode, pump future) registry.
// The pump ticks the clock, drains outbound packets, and polls the inbox and hops:// queues on an
// interval, emitting one event per item over the device event emitter.

package sh.hop.reactnative

import android.util.Base64
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import sh.hop.HopAddress
import sh.hop.HopNode
import sh.hop.HopRole
import sh.hop.HpsAccess
import sh.hop.HpsKind
import sh.hop.HpsVisibility

class HopMeshModule(private val reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  private class Entry(val node: HopNode) {
    @Volatile var pump: ScheduledFuture<*>? = null
  }

  private val nodes = ConcurrentHashMap<Int, Entry>()
  private val nextHandle = AtomicInteger(1)
  private val pumps = Executors.newScheduledThreadPool(1) { r ->
    Thread(r, "hop-reactnative-pump").apply { isDaemon = true }
  }

  override fun getName() = "HopMesh"

  private fun dec(b64: String): ByteArray = Base64.decode(b64, Base64.NO_WRAP)
  private fun enc(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

  private fun register(node: HopNode): Int {
    val handle = nextHandle.getAndIncrement()
    nodes[handle] = Entry(node)
    return handle
  }

  private fun entry(handle: Int, promise: Promise): Entry? {
    val e = nodes[handle]
    if (e == null) promise.reject("hop_error", "unknown node handle")
    return e
  }

  private fun emit(event: String, body: WritableMap) {
    if (!reactContext.hasActiveReactInstance()) return
    reactContext
      .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
      .emit(event, body)
  }

  // MARK: hps:// enum mapping
  //
  // Enums cross the bridge as lowercase strings, the same way `role` does. An UNRECOGNIZED string
  // returns null here and the calling method rejects the promise; it is NEVER coerced to OPEN or
  // CHANNEL, because reading a garbage access mode as Open would hand a topic's keys to anyone who
  // asks. The outbound direction (topics and invites going to JS) is total, so it needs no fallback.
  private fun hpsKind(text: String): HpsKind? = when (text) {
    "channel" -> HpsKind.CHANNEL
    "service" -> HpsKind.SERVICE
    else -> null
  }

  private fun hpsAccess(text: String): HpsAccess? = when (text) {
    "open" -> HpsAccess.OPEN
    "requestToJoin" -> HpsAccess.REQUEST_TO_JOIN
    "invite" -> HpsAccess.INVITE
    else -> null
  }

  private fun hpsVisibility(text: String): HpsVisibility? = when (text) {
    "private" -> HpsVisibility.PRIVATE
    "discoverable" -> HpsVisibility.DISCOVERABLE
    else -> null
  }

  private fun name(kind: HpsKind): String = when (kind) {
    HpsKind.CHANNEL -> "channel"
    HpsKind.SERVICE -> "service"
  }

  private fun name(access: HpsAccess): String = when (access) {
    HpsAccess.OPEN -> "open"
    HpsAccess.REQUEST_TO_JOIN -> "requestToJoin"
    HpsAccess.INVITE -> "invite"
  }

  private fun badEnum(promise: Promise, field: String, value: String) {
    promise.reject("hop_error", "unrecognized hps $field: $value")
  }

  private fun addresses(items: List<ByteArray>): WritableArray {
    val out = Arguments.createArray()
    for (addr in items) out.pushString(HopAddress.base58(addr))
    return out
  }

  private fun bundleIds(items: List<ByteArray>): WritableArray {
    val out = Arguments.createArray()
    for (id in items) out.pushString(enc(id))
    return out
  }

  // MARK: lifecycle

  @ReactMethod
  fun createEphemeral(promise: Promise) {
    try {
      promise.resolve(register(HopNode.ephemeral()))
    } catch (t: Throwable) {
      promise.reject("hop_error", t.message, t)
    }
  }

  @ReactMethod
  fun createWithSecret(secretB64: String, promise: Promise) {
    try {
      promise.resolve(register(HopNode.withSecret(dec(secretB64))))
    } catch (t: Throwable) {
      promise.reject("hop_error", t.message, t)
    }
  }

  @ReactMethod
  fun openPersistent(dbPath: String, secretB64: String, appSecretB64: String, promise: Promise) {
    val node = HopNode.open(dbPath, dec(secretB64), dec(appSecretB64))
    if (node == null) promise.resolve(-1) else promise.resolve(register(node))
  }

  @ReactMethod
  fun openKeyed(dbPath: String, keyB64: String, secretB64: String, appSecretB64: String, promise: Promise) {
    val node = HopNode.openKeyed(dbPath, dec(keyB64), dec(secretB64), dec(appSecretB64))
    if (node == null) promise.resolve(-1) else promise.resolve(register(node))
  }

  @ReactMethod
  fun closeNode(handle: Int, promise: Promise) {
    nodes.remove(handle)?.let { e ->
      e.pump?.cancel(false)
      e.node.close()
    }
    promise.resolve(null)
  }

  // MARK: identity + config

  @ReactMethod
  fun address(handle: Int, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(HopAddress.base58(e.node.address()))
  }

  @ReactMethod
  fun secret(handle: Int, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(enc(e.node.secret()))
  }

  @ReactMethod
  fun setName(handle: Int, name: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    e.node.setName(name)
    promise.resolve(null)
  }

  @ReactMethod
  fun subscribe(handle: Int, topic: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    e.node.subscribe(topic)
    promise.resolve(null)
  }

  @ReactMethod
  fun publishPrekey(handle: Int, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.publishPrekey())
  }

  private fun validateNumber(value: Double, name: String, promise: Promise): Boolean {
    if (value.isNaN() || value.isInfinite() || value < 0 || value > 9007199254740991.0 || value != Math.floor(value)) {
      promise.reject("hop_error", "$name must be a safe non-negative integer")
      return false
    }
    return true
  }

  @ReactMethod
  fun tick(handle: Int, nowMs: Double, promise: Promise) {
    if (!validateNumber(nowMs, "nowMs", promise)) return
    val e = entry(handle, promise) ?: return
    e.node.tick(nowMs.toLong())
    promise.resolve(null)
  }

  @ReactMethod
  fun isPersistent(handle: Int, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.isPersistent())
  }

  @ReactMethod
  fun isEncrypted(handle: Int, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.isEncrypted())
  }

  @ReactMethod
  fun rehydrateDropped(handle: Int, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.rehydrateDropped())
  }

  @ReactMethod
  fun isSecured(handle: Int, addrB58: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val addr = HopAddress.fromBase58(addrB58)
    promise.resolve(if (addr == null) false else e.node.isSecured(addr))
  }

  // MARK: messaging

  @ReactMethod
  fun send(handle: Int, toB58: String, contentType: String, bodyB64: String, requestAck: Boolean, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val dst = HopAddress.fromBase58(toB58) ?: return promise.resolve(null)
    val id = e.node.send(dst, contentType, dec(bodyB64), requestAck)
    promise.resolve(id?.let(::enc))
  }

  @ReactMethod
  fun sendTo(handle: Int, toB58: String, contentType: String, bodyB64: String, requestAck: Boolean, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val dst = HopAddress.fromBase58(toB58) ?: return promise.resolve(null)
    val id = e.node.sendTo(dst, contentType, dec(bodyB64), requestAck)
    promise.resolve(id?.let(::enc))
  }

  @ReactMethod
  fun status(handle: Int, idB64: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val s = e.node.status(dec(idB64))
    val map = Arguments.createMap()
    map.putInt("relayed", s.relayed)
    map.putBoolean("delivered", s.delivered)
    map.putInt("forwardHops", s.forwardHops.toInt())
    map.putInt("forwardMs", s.forwardMs)
    promise.resolve(map)
  }

  @ReactMethod
  fun acceptInbox(handle: Int, idB64: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.acceptInbox(dec(idB64)))
  }

  // MARK: hops:// request / response

  @ReactMethod
  fun sendServiceRequest(handle: Int, toB58: String, service: String, method: String, argsB64: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val dst = HopAddress.fromBase58(toB58) ?: return promise.resolve(null)
    val id = e.node.sendServiceRequest(dst, service, method, dec(argsB64))
    promise.resolve(id?.let(::enc))
  }

  @ReactMethod
  fun sendServiceResponse(handle: Int, toB58: String, reqB64: String, status: Int, bodyB64: String, promise: Promise) {
    if (status < 0 || status > 65535) {
      promise.reject("hop_error", "status must be between 0 and 65535")
      return
    }
    val e = entry(handle, promise) ?: return
    val dst = HopAddress.fromBase58(toB58) ?: return promise.resolve(false)
    promise.resolve(e.node.sendServiceResponse(dst, dec(reqB64), status, dec(bodyB64)))
  }

  @ReactMethod
  fun acceptServiceResponse(handle: Int, reqB64: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.acceptServiceResponse(dec(reqB64)))
  }

  @ReactMethod
  fun acceptServiceRequest(handle: Int, reqB64: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.acceptServiceRequest(dec(reqB64)))
  }

  @ReactMethod
  fun rejectServiceRequest(handle: Int, reqB64: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.rejectServiceRequest(dec(reqB64)))
  }

  // MARK: bearer seam

  @ReactMethod
  fun linkUp(handle: Int, link: Double, role: String, promise: Promise) {
    if (!validateNumber(link, "link", promise)) return
    val e = entry(handle, promise) ?: return
    e.node.linkUp(link.toLong(), if (role == "dialer") HopRole.DIALER else HopRole.ACCEPTOR)
    promise.resolve(null)
  }

  @ReactMethod
  fun linkDown(handle: Int, link: Double, promise: Promise) {
    if (!validateNumber(link, "link", promise)) return
    val e = entry(handle, promise) ?: return
    e.node.linkDown(link.toLong())
    promise.resolve(null)
  }

  @ReactMethod
  fun bytesReceived(handle: Int, link: Double, bytesB64: String, promise: Promise) {
    if (!validateNumber(link, "link", promise)) return
    val e = entry(handle, promise) ?: return
    e.node.bytesReceived(link.toLong(), dec(bytesB64))
    promise.resolve(null)
  }

  // MARK: section 19 relay pool

  @ReactMethod
  fun relayAdd(handle: Int, url: String, configured: Boolean, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.relayAdd(url, configured))
  }

  // null means nothing is dialable RIGHT NOW, which is not the same as offline: a non-zero relayPool
  // total with nothing dialable is the degraded "every candidate is backed off" state, and the JS
  // wrapper documents that distinction for the UI that has to render it.
  @ReactMethod
  fun relayNext(handle: Int, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.relayNext())
  }

  @ReactMethod
  fun relayReport(handle: Int, url: String, ok: Boolean, promise: Promise) {
    val e = entry(handle, promise) ?: return
    e.node.relayReport(url, ok)
    promise.resolve(null)
  }

  @ReactMethod
  fun relayPool(handle: Int, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val pool = e.node.relayPool()
    val m = Arguments.createMap()
    m.putInt("total", pool.total)
    m.putInt("available", pool.available)
    promise.resolve(m)
  }

  // MARK: hps:// pub/sub (section 32)
  //
  // A publication is a single content-key-encrypted, per-writer-signed message flooded once, not a
  // fan-out and not a multicast bundle. Membership, invites and revocation are properties of the
  // topic's key handoff, which is why hpsApprove and hpsRekey resolve bundle ids: each one is a key
  // handoff sealed to a member.

  @ReactMethod
  fun hpsRegister(handle: Int, path: String, kindText: String, accessText: String, visibilityText: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val kind = hpsKind(kindText) ?: return badEnum(promise, "kind", kindText)
    val access = hpsAccess(accessText) ?: return badEnum(promise, "access", accessText)
    val visibility = hpsVisibility(visibilityText) ?: return badEnum(promise, "visibility", visibilityText)
    // An EMPTY string is a channel's correct answer (a channel has no service signing key), so it is a
    // success; null is reserved for the register having failed.
    promise.resolve(e.node.hpsRegister(path, kind, access, visibility)?.let(::enc))
  }

  @ReactMethod
  fun hpsSubscribe(handle: Int, hostB58: String, path: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val host = HopAddress.fromBase58(hostB58) ?: return promise.resolve(null)
    promise.resolve(e.node.hpsSubscribe(host, path)?.let(::enc))
  }

  @ReactMethod
  fun hpsPublish(handle: Int, path: String, bodyB64: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.hpsPublish(path, dec(bodyB64))?.let(::enc))
  }

  @ReactMethod
  fun acceptHpsMessage(handle: Int, idB64: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.acceptHpsMessage(dec(idB64)))
  }

  @ReactMethod
  fun hpsInvite(handle: Int, path: String, destB58: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val dest = HopAddress.fromBase58(destB58) ?: return promise.resolve(null)
    promise.resolve(e.node.hpsInvite(path, dest)?.let(::enc))
  }

  @ReactMethod
  fun hpsAcceptInvite(handle: Int, hostB58: String, path: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val host = HopAddress.fromBase58(hostB58) ?: return promise.resolve(null)
    promise.resolve(e.node.hpsAcceptInvite(host, path)?.let(::enc))
  }

  @ReactMethod
  fun hpsDeclineInvite(handle: Int, hostB58: String, path: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val host = HopAddress.fromBase58(hostB58) ?: return promise.resolve(false)
    promise.resolve(e.node.hpsDeclineInvite(host, path))
  }

  // The native call also yields the leave bundle's id; JS gets only the ok flag, because an RN client
  // has nothing to correlate that id against.
  @ReactMethod
  fun hpsLeave(handle: Int, path: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.hpsLeave(path).ok)
  }

  @ReactMethod
  fun hpsPending(handle: Int, path: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(addresses(e.node.hpsPending(path)))
  }

  @ReactMethod
  fun hpsApprove(handle: Int, path: String, requesterB58: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val requester = HopAddress.fromBase58(requesterB58) ?: return promise.resolve(null)
    promise.resolve(e.node.hpsApprove(path, requester)?.let(::enc))
  }

  @ReactMethod
  fun hpsDeny(handle: Int, path: String, requesterB58: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val requester = HopAddress.fromBase58(requesterB58) ?: return promise.resolve(false)
    promise.resolve(e.node.hpsDeny(path, requester))
  }

  // An unparsable address in the remove list FAILS the whole call rather than being skipped. Skipping
  // it would rotate the key and report success while the member the caller asked to revoke still holds
  // a usable one, which is the worst possible outcome to report as an ok.
  @ReactMethod
  fun hpsRekey(handle: Int, path: String, newPath: String, removeB58: ReadableArray, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val remove = ArrayList<ByteArray>(removeB58.size())
    for (i in 0 until removeB58.size()) {
      // orEmpty() rather than a null check: ReadableArray.getString is @Nullable on some React Native
      // versions and non-null on others, and an empty string fails fromBase58 the same way a null
      // entry must, so this reads identically under either signature.
      val text = removeB58.getString(i).orEmpty()
      val addr = HopAddress.fromBase58(text)
      if (addr == null) {
        return promise.reject("hop_error", "unparsable address in the hps remove list: $text")
      }
      remove.add(addr)
    }
    promise.resolve(bundleIds(e.node.hpsRekey(path, newPath, remove)))
  }

  @ReactMethod
  fun hpsReach(handle: Int, path: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.hpsReach(path))
  }

  @ReactMethod
  fun hpsMembers(handle: Int, path: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(addresses(e.node.hpsMembers(path)))
  }

  @ReactMethod
  fun hpsMyTopics(handle: Int, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val out = Arguments.createArray()
    for (topic in e.node.hpsMyTopics()) {
      val m = Arguments.createMap()
      m.putString("host", HopAddress.base58(topic.host))
      m.putString("path", topic.path)
      m.putString("kind", name(topic.kind))
      m.putBoolean("hosting", topic.hosting)
      m.putString("access", name(topic.access))
      out.pushMap(m)
    }
    promise.resolve(out)
  }

  @ReactMethod
  fun hpsBrowse(handle: Int, promise: Promise) {
    val e = entry(handle, promise) ?: return
    val out = Arguments.createArray()
    for (topic in e.node.hpsBrowse()) {
      val m = Arguments.createMap()
      m.putString("host", HopAddress.base58(topic.host))
      m.putString("path", topic.path)
      m.putString("kind", name(topic.kind))
      m.putString("title", topic.title)
      m.putString("summary", topic.summary)
      m.putString("access", name(topic.access))
      out.pushMap(m)
    }
    promise.resolve(out)
  }

  // MARK: pump

  @ReactMethod
  fun startPump(handle: Int, intervalMs: Double, promise: Promise) {
    val e = entry(handle, promise) ?: return
    e.pump?.cancel(false)
    val period = maxOf(intervalMs.toLong(), 10L)
    e.pump = pumps.scheduleWithFixedDelay({ pump(handle) }, 0, period, TimeUnit.MILLISECONDS)
    promise.resolve(null)
  }

  @ReactMethod
  fun stopPump(handle: Int, promise: Promise) {
    nodes[handle]?.let { it.pump?.cancel(false); it.pump = null }
    promise.resolve(null)
  }

  private fun pump(handle: Int) {
    val e = nodes[handle] ?: return
    val node = e.node
    node.tick(System.currentTimeMillis())
    node.drainOutgoing { link, bytes ->
      val m = Arguments.createMap()
      m.putInt("node", handle)
      m.putDouble("link", link.toDouble())
      m.putString("bytes", enc(bytes))
      emit("HopMesh:outgoing", m)
    }
    node.pollInbox { msg ->
      val m = Arguments.createMap()
      m.putInt("node", handle)
      m.putString("id", enc(msg.id))
      m.putString("from", HopAddress.base58(msg.from))
      m.putString("contentType", msg.contentType)
      m.putString("body", enc(msg.body))
      m.putInt("hops", msg.hops.toInt())
      m.putDouble("createdAt", msg.createdAt.toDouble())
      emit("HopMesh:message", m)
    }
    node.pollServiceRequests { req ->
      val m = Arguments.createMap()
      m.putInt("node", handle)
      m.putString("from", HopAddress.base58(req.from))
      m.putString("requestId", enc(req.requestId))
      m.putString("service", req.service)
      m.putString("method", req.method)
      m.putString("args", enc(req.args))
      emit("HopMesh:serviceRequest", m)
    }
    node.pollServiceResponses { resp ->
      val m = Arguments.createMap()
      m.putInt("node", handle)
      m.putString("from", HopAddress.base58(resp.from))
      m.putString("forRequestId", enc(resp.forRequestId))
      m.putInt("status", resp.status)
      m.putString("body", enc(resp.body))
      emit("HopMesh:serviceResponse", m)
    }
    // The NON-accepting poll, exactly like pollInbox above: a publication stays queued until JS calls
    // acceptHpsMessage, so one that arrives while the JS side crashes is redelivered, not lost.
    node.pollHpsMessages { msg ->
      val m = Arguments.createMap()
      m.putInt("node", handle)
      m.putString("id", enc(msg.id))
      m.putString("path", msg.path)
      m.putString("sender", HopAddress.base58(msg.sender))
      m.putString("body", enc(msg.body))
      emit("HopMesh:hpsMessage", m)
    }
    // Take-and-clear, not accept-to-remove: a drained invite is gone, so the JS side must persist what
    // this hands it.
    node.pollHpsInvites { inv ->
      val m = Arguments.createMap()
      m.putInt("node", handle)
      m.putString("host", HopAddress.base58(inv.host))
      m.putString("path", inv.path)
      m.putString("kind", name(inv.kind))
      emit("HopMesh:hpsInvite", m)
    }
  }

  // MARK: address helpers

  @ReactMethod
  fun addressToBase58(bytesB64: String, promise: Promise) {
    promise.resolve(HopAddress.base58(dec(bytesB64)))
  }

  @ReactMethod
  fun addressFromBase58(text: String, promise: Promise) {
    promise.resolve(HopAddress.fromBase58(text)?.let(::enc))
  }

  // Required by NativeEventEmitter on the JS side; the pump is what actually drives delivery.
  @ReactMethod
  fun addListener(eventName: String) { /* no-op: events are always emitted when a pump runs */ }

  @ReactMethod
  fun removeListeners(count: Int) { /* no-op */ }

  override fun invalidate() {
    super.invalidate()
    nodes.values.forEach { it.pump?.cancel(false); it.node.close() }
    nodes.clear()
    pumps.shutdownNow()
  }
}
