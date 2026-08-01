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

  @ReactMethod
  fun tick(handle: Int, nowMs: Double, promise: Promise) {
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
    val e = entry(handle, promise) ?: return
    val dst = HopAddress.fromBase58(toB58) ?: return promise.resolve(false)
    promise.resolve(e.node.sendServiceResponse(dst, dec(reqB64), status, dec(bodyB64)))
  }

  @ReactMethod
  fun acceptServiceResponse(handle: Int, reqB64: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    promise.resolve(e.node.acceptServiceResponse(dec(reqB64)))
  }

  // MARK: bearer seam

  @ReactMethod
  fun linkUp(handle: Int, link: Double, role: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    e.node.linkUp(link.toLong(), if (role == "dialer") HopRole.DIALER else HopRole.ACCEPTOR)
    promise.resolve(null)
  }

  @ReactMethod
  fun linkDown(handle: Int, link: Double, promise: Promise) {
    val e = entry(handle, promise) ?: return
    e.node.linkDown(link.toLong())
    promise.resolve(null)
  }

  @ReactMethod
  fun bytesReceived(handle: Int, link: Double, bytesB64: String, promise: Promise) {
    val e = entry(handle, promise) ?: return
    e.node.bytesReceived(link.toLong(), dec(bytesB64))
    promise.resolve(null)
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
