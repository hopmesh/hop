// The Android half of the @hop-mesh/react-native DRIVER bridge: a second React Native module, beside
// HopMesh, exposing the platform driver (sh.hopme.driver.HopBearer + HopService, the exact runtime
// apps/android/HopDemo is built on) to JavaScript.
//
// WHY A SECOND MODULE. HopMesh bridges node and link primitives only (linkUp / bytesReceived /
// startPump), so JavaScript has to supply its own transport. That is why the React Native demo never
// asked for Bluetooth permission and never saw a peer: nothing in it touched a radio. The driver is
// what owns the radios, the peer table, the message store and the presence advert, so bridging the
// driver is what gives the React Native demo the same mesh the native demos have.
//
// Peers, messages and transports are PUSHED to JavaScript as the three HopDriver:* events rather than
// polled from JavaScript, so a React screen re-renders when the mesh changes rather than on a timer it
// picked itself. See [mirror] for why the mirror reads driver state on a fixed cadence.

package sh.hop.reactnative

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import com.facebook.react.modules.core.PermissionAwareActivity
import com.facebook.react.modules.core.PermissionListener
import java.io.File
import sh.hopme.driver.HopBearer
import sh.hopme.driver.HopConfig
import sh.hopme.driver.HopService
import sh.hopme.driver.SendResult
import uniffi.hop.addressBase58
import uniffi.hop.addressFromBase58

class HopDriverModule(private val reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext), LifecycleEventListener {

  override fun getName() = NAME

  /** The driver publishes its state as Compose snapshot state, and it WRITES that state on the main
   *  thread, so every read here is marshalled to main for a consistent view. */
  private val main = Handler(Looper.getMainLooper())

  /** The configure-once driver singleton, held from [start] until [stop]. Null means JavaScript has not
   *  started the driver, which is a different thing from a driver that failed to start. */
  @Volatile private var bearer: HopBearer? = null

  /** The name [start] handed the driver. Kept here rather than read back from the driver's UI mirror so
   *  [setName] compares against an exact value instead of one that is briefly empty right after start. */
  @Volatile private var advertisedName: String? = null

  private var mirroring = false
  private var lastPeers: String? = null
  private var lastTransports: String? = null
  private val lastMessages = HashMap<String, String>()

  /** Counts mirror ticks so the state heartbeat is logged at a readable rate rather than at 4 Hz. */
  private var mirrorTicks = 0L

  /** A URL that arrived before JavaScript asked for it. onNewIntent can land while the React instance is
   *  still coming up, and dropping it there would lose exactly the automation command a harness just
   *  sent, so it is held until [launchURL] collects it or the event finds a listener. */
  @Volatile private var pendingLaunchURL: String? = null

  override fun initialize() {
    live = this
    reactContext.addLifecycleEventListener(this)
  }

  /** A JavaScript reload tears the module down and builds a new one. The driver deliberately survives
   *  that: it is a process singleton kept alive by the foreground service, exactly as the native demo's
   *  driver survives its Activity. So this releases only what belongs to the module. */
  override fun invalidate() {
    stopMirror()
    reactContext.removeLifecycleEventListener(this)
    super.invalidate()
  }

  // The host activity's foreground state changes what the driver advertises (fg / bg in the presence
  // summary) and clears the unread badge, so mirror React Native's host lifecycle onto it the way
  // MainActivity mirrors onResume / onPause. There is no promise to reject on this path, and a throw
  // on the main thread would take the app down, so a failure is logged instead.
  override fun onHostResume() = onMain { setForeground(true) }
  override fun onHostPause() = onMain { setForeground(false) }
  override fun onHostDestroy() = Unit

  private fun setForeground(fg: Boolean) {
    val b = bearer ?: return
    runCatching { b.setForeground(fg) }
      .onFailure { Log.w(TAG, "setForeground($fg) failed", it) }
  }

  // MARK: permissions

  /** Every permission the mesh asks for at runtime, matching apps/android/HopDemo's MainActivity: the
   *  Android 12+ Bluetooth trio, fine location on the older levels where a BLE scan needs it instead,
   *  and the Android 13+ notification permission. */
  private fun wantedPermissions(): List<String> {
    val perms = mutableListOf<String>()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      perms += listOf(
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_ADVERTISE,
        Manifest.permission.BLUETOOTH_CONNECT,
      )
    } else {
      perms += Manifest.permission.ACCESS_FINE_LOCATION
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      perms += Manifest.permission.POST_NOTIFICATIONS
    }
    return perms.distinct()
  }

  private fun granted(permission: String): Boolean =
    reactContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

  /** `granted` reports the HARD requirement only. The notification permission is best-effort in the
   *  native demo (a denial there never blocks the mesh), so a device that refuses notifications still
   *  reports granted = true while naming the refusal in `missing`. */
  private fun permissionResult(missing: List<String>): WritableMap = Arguments.createMap().apply {
    putBoolean("granted", missing.none { it !in OPTIONAL_PERMISSIONS })
    val arr = Arguments.createArray()
    missing.forEach { arr.pushString(it) }
    putArray("missing", arr)
  }

  @ReactMethod
  fun ensurePermissions(promise: Promise) {
    try {
      val wanted = wantedPermissions()
      val missing = wanted.filterNot(::granted)
      if (missing.isEmpty()) {
        promise.resolve(permissionResult(emptyList()))
        return
      }
      // Read through the react context, not the base class's getCurrentActivity(), which React Native
      // deprecated in 0.80 in favour of exactly this.
      val activity = reactContext.currentActivity
      if (activity == null) {
        promise.reject(
          E_NO_ACTIVITY,
          "cannot ask for Bluetooth permission with no activity attached: call ensurePermissions while a screen is up",
        )
        return
      }
      // ActivityCompat.requestPermissions has nowhere to deliver its answer inside a React Native
      // module: the result lands in the Activity's onRequestPermissionsResult, and ReactActivity
      // forwards that ONLY to a listener registered through PermissionAwareActivity. So this is the
      // request path that can actually resolve the promise after the user answers, and it is the one
      // React Native's own PermissionsModule uses.
      if (activity !is PermissionAwareActivity) {
        promise.reject(
          E_NO_ACTIVITY,
          "the host activity does not implement PermissionAwareActivity, so a permission result can never come back: make it a ReactActivity",
        )
        return
      }
      val listener = PermissionListener { code, _, _ ->
        if (code != PERMISSION_REQUEST_CODE) return@PermissionListener false
        // Re-read the live grant state rather than the result array: a permission that was already
        // granted is not in the array at all, and the user may have answered from a settings screen.
        runCatching { permissionResult(wanted.filterNot(::granted)) }
          .onSuccess { promise.resolve(it) }
          .onFailure { promise.reject(E_PERMISSIONS, it.message ?: it.toString(), it) }
        true
      }
      activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE, listener)
    } catch (t: Throwable) {
      promise.reject(E_PERMISSIONS, t.message ?: t.toString(), t)
    }
  }

  // MARK: driver lifecycle

  /** The driver's configuration, field for field the one apps/android/HopDemo's MainActivity builds:
   *  hardware-backed identity seed and db key (so the address survives a reinstall and hop.db is
   *  encrypted at rest), the shared dev app secret, on-device storage, and the backbone relay.
   *
   *  deviceName stays the OS device name, as it is there. The demo participant name is not a config
   *  field: it reaches the mesh through start(name), which is what sets the presence advert. */
  private fun config(): HopConfig {
    val ctx = reactContext.applicationContext
    // Persist the relay choice BEFORE building the config, so a START_STICKY service restart (which
    // builds HopConfig.default with no activity) resolves the SAME value this build chose.
    HopConfig.persistRelaysEnabled(ctx, true)
    return HopConfig(
      dbPath = File(ctx.filesDir, "hop.db").absolutePath,
      identitySecret = HopBearer.deviceSeed(ctx),
      appSecret = HopBearer.APP_SECRET,
      deviceName = HopConfig.deviceName(ctx),
      relayUrl = HopBearer.DEFAULT_RELAY,
      relaysEnabled = HopConfig.relaysEnabled(ctx),
      notificationIcon = android.R.drawable.ic_dialog_email,
      dbKey = HopBearer.dbKey(ctx),
    )
  }

  @ReactMethod
  fun start(name: String, promise: Promise) {
    if (name.isBlank()) {
      promise.reject(E_ARGUMENT, "start needs a non-empty display name: it is the name peers see")
      return
    }
    onMain(promise, E_START) {
      val ctx = reactContext.applicationContext
      val b = HopBearer.shared(ctx, config())
      bearer = b
      // start() BEFORE the service. HopService starts the same singleton under the OS device name,
      // and the driver's start is first-caller-wins on its serial core thread, so ours has to be
      // queued first for the participant name to be the one the presence advert carries.
      b.start(name)
      advertisedName = name
      HopService.start(ctx)
      b.setForeground(true)
      startMirror()
      promise.resolve(null)
    }
  }

  @ReactMethod
  fun stop(promise: Promise) = onMain(promise, E_STOP) {
    val b = bearer
    stopMirror()
    val ctx = reactContext.applicationContext
    // Stop the foreground service first: it is what holds the driver alive, so stopping it before the
    // teardown means the OS cannot restart it onto a driver that is closing.
    ctx.stopService(Intent(ctx, HopService::class.java))
    b?.teardown()
    bearer = null
    advertisedName = null
    lastPeers = null
    lastTransports = null
    lastMessages.clear()
    promise.resolve(null)
  }

  /** Set the demo name. Saved and applied while the driver is down; refused while it is up.
   *
   *  The Android driver publishes its presence name ONCE, inside HopBearer.start, and exposes no
   *  rename (iOS has setName; Android does not). So a rename on a live mesh is rejected with that
   *  reason instead of silently doing nothing and letting the UI claim a name change no peer will ever
   *  see. It refuses BEFORE writing anything, so a rejected call leaves no half-applied name behind;
   *  a caller that wants the new name on the next launch has savePersistedName for exactly that. */
  @ReactMethod
  fun setName(name: String, promise: Promise) {
    if (name.isBlank()) {
      promise.reject(E_ARGUMENT, "setName needs a non-empty display name")
      return
    }
    try {
      val live = advertisedName
      if (bearer != null && live != null && live != name) {
        promise.reject(
          E_RENAME,
          "the driver is advertising \"$live\" and cannot be renamed while it runs: the Android driver " +
            "publishes its presence name once in HopBearer.start and has no rename, so save the new " +
            "name with savePersistedName and it goes out the next time the driver starts",
        )
        return
      }
      if (saveName(name)) promise.resolve(null)
      else promise.reject(E_PERSIST, "could not write the demo name to SharedPreferences(\"$PREFS\")")
    } catch (t: Throwable) {
      promise.reject(E_PERSIST, t.message ?: t.toString(), t)
    }
  }

  // MARK: name persistence

  private fun prefs() =
    reactContext.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

  /** commit(), not apply(): the caller is told the name is saved, so it has to be on disk before the
   *  promise resolves rather than queued behind a process that may not survive. */
  private fun saveName(name: String): Boolean =
    prefs().edit().putString(KEY_NAME, name).commit()

  @ReactMethod
  fun persistedName(promise: Promise) {
    try {
      promise.resolve(prefs().getString(KEY_NAME, null)?.takeIf { it.isNotBlank() })
    } catch (t: Throwable) {
      promise.reject(E_PERSIST, t.message ?: t.toString(), t)
    }
  }

  @ReactMethod
  fun savePersistedName(name: String, promise: Promise) {
    if (name.isBlank()) {
      promise.reject(E_ARGUMENT, "savePersistedName needs a non-empty display name")
      return
    }
    try {
      if (saveName(name)) promise.resolve(null)
      else promise.reject(E_PERSIST, "could not write the demo name to SharedPreferences(\"$PREFS\")")
    } catch (t: Throwable) {
      promise.reject(E_PERSIST, t.message ?: t.toString(), t)
    }
  }

  // MARK: automation URL delivery
  //
  // React Native's own Linking does not deliver on this stack. Measured on a release build, React Native
  // 0.87 bridgeless: an activity started by `am start -a VIEW -d hopdemo://send?...` reaches the app (it
  // boots and reports HOPSELF), yet Linking.getInitialURL() yields nothing on a cold start and the warm
  // 'url' listener never fires on a redelivered intent. iOS behaves the same way even though the
  // AppDelegate forward into RCTLinkingManager is accepted, so this is the framework path rather than one
  // platform. The bridge therefore reads the intent itself, which is the only source that cannot lie.
  //
  // launchURL is the cold half: the activity's current intent, consumed ONCE so a relaunch of an already
  // started app does not replay a stale command. deliverURL is the warm half, called from MainActivity's
  // onNewIntent.
  @ReactMethod
  fun launchURL(promise: Promise) = onMain(promise, E_STATE) {
    val url = pendingLaunchURL ?: reactContext.currentActivity?.intent?.dataString
    pendingLaunchURL = null
    promise.resolve(url)
  }

  // MARK: mesh state

  @ReactMethod
  fun selfAddress(promise: Promise) = onMain(promise, E_STATE) {
    val b = requireBearer(promise) ?: return@onMain
    // The UI mirror is written during start; the node knows the address the moment it is open, and
    // node.address() is one of the reads the driver documents as safe from the main thread.
    promise.resolve(b.myAddress.value.ifEmpty { addressBase58(b.node.address()) })
  }

  @ReactMethod
  fun peers(promise: Promise) = onMain(promise, E_STATE) {
    val b = requireBearer(promise) ?: return@onMain
    val arr = Arguments.createArray()
    for ((p, reachable) in peerRows(b)) arr.pushMap(peerMap(p, reachable))
    logState(b)
    promise.resolve(arr)
  }

  @ReactMethod
  fun messages(peerAddressBase58: String, promise: Promise) = onMain(promise, E_STATE) {
    val b = requireBearer(promise) ?: return@onMain
    val arr = Arguments.createArray()
    for (m in b.messages.toList()) if (m.peer == peerAddressBase58) arr.pushMap(messageMap(m))
    promise.resolve(arr)
  }

  @ReactMethod
  fun send(text: String, toAddressBase58: String, promise: Promise) = onMain(promise, E_SEND) {
    val b = requireBearer(promise) ?: return@onMain
    val addr = runCatching { addressFromBase58(toAddressBase58.trim()) }.getOrNull()
    if (addr == null || addr.size != 32) {
      promise.resolve(sendResult("not a Hop address: \"$toAddressBase58\""))
      return@onMain
    }
    // Prefer the peer the driver already knows (its advertised name, hop count and reachability), so a
    // send does not downgrade a live peer to a bare address. contactList covers a peer that is offline
    // right now but was messaged before.
    val known = (b.peers.toList() + b.seen.toList() + b.contactList)
      .firstOrNull { it.address.contentEquals(addr) }
    val peer = known ?: HopBearer.Peer(addr, b.displayName(addr), 0u.toUByte(), active = false)
    val detail = when (b.send(text, peer)) {
      SendResult.QUEUED -> null
      SendResult.OVERLOADED ->
        "the driver's pending-message quota is full: wait for the queued messages to go out, or clear the relay queue"
      SendResult.INVALID -> "the driver rejected the message as invalid"
    }
    promise.resolve(sendResult(detail))
  }

  private fun sendResult(detail: String?): WritableMap = Arguments.createMap().apply {
    putBoolean("ok", detail == null)
    if (detail != null) putString("detail", detail)
  }

  // MARK: per-transport control

  @ReactMethod
  fun transports(promise: Promise) = onMain(promise, E_STATE) {
    val b = requireBearer(promise) ?: return@onMain
    promise.resolve(transportMap(transportRows(b)))
  }

  /** Switch one bearer on or off, the same control the native demo's Transports section exposes.
   *
   *  The promise stays pending until the BearerManager actually REPORTS the requested state, not merely
   *  until the driver has queued the change: the driver applies a toggle on a separate control thread
   *  because starting or stopping a radio can block, and a caller that awaits this is about to send
   *  over that bearer. Resolving early would race the executor and test the wrong transport. */
  @ReactMethod
  fun setTransportEnabled(transport: String, enabled: Boolean, promise: Promise) =
    onMain(promise, E_TRANSPORT) {
      val b = requireBearer(promise) ?: return@onMain
      val tag = resolveTransportTag(b, transport)
      if (tag == null) {
        promise.reject(
          E_TRANSPORT,
          "no transport called \"$transport\": this driver registered ${transportLabels(b)}",
        )
        return@onMain
      }
      if (!b.setTransportEnabled(tag, enabled)) {
        promise.reject(
          E_TRANSPORT,
          "the driver has no $tag bearer registered, so it cannot be switched; it registered ${transportLabels(b)}",
        )
        return@onMain
      }
      awaitTransportState(b, tag, enabled, promise, TRANSPORT_SETTLE_TRIES)
    }

  private fun transportLabels(b: HopBearer): String =
    transportRows(b).joinToString(", ") { it.first }.ifEmpty { "none yet" }

  /** Poll until the toggle looks applied, then emit the applied state and resolve. Bounded, so a bearer
   *  that never gets there fails the call with its real state instead of leaving the promise pending
   *  forever.
   *
   *  The Android driver's setTransportEnabled is fire and forget: it hands the change to its own control
   *  thread (starting or stopping a radio can block) and offers NO completion callback. So there is no
   *  signal here that strictly proves the work finished, and this waits on the three the public API does
   *  expose, which together are much harder to satisfy early than any one alone:
   *    - the bearer manager reports [want]. It flips this flag on its way through setEnabled, so on its
   *      own it can be true while a radio is still starting or links are still coming down.
   *    - the driver's own transport row reports [want]. The control thread writes that row after
   *      setEnabled returns, though the driver's periodic refresh also rebuilds the rows straight from
   *      manager state, so a row CAN match before the control call has returned.
   *    - switching OFF additionally waits for the live link count to reach zero. That is the one that
   *      matters for isolating a bearer: without it a caller that disables a transport and then sends
   *      could still have a link on it, the message would cross on the wrong transport, and the run
   *      would prove nothing. */
  private fun awaitTransportState(
    b: HopBearer,
    tag: String,
    want: Boolean,
    promise: Promise,
    triesLeft: Int,
  ) {
    val now = b.transportStates()[tag]
    val links = b.activeTransportCounts()[tag] ?: 0
    val row = b.transports.firstOrNull { it.tag == tag }?.enabled
    if (now == want && row == want && (want || links == 0)) {
      // Emit here as well as from the mirror, so a UI sees the toggle land the moment it lands. The
      // emit is diffed, so whichever of the two gets there first is the only one that sends.
      publishTransports(b)
      promise.resolve(null)
      return
    }
    if (triesLeft <= 0) {
      promise.reject(
        E_TRANSPORT,
        "the driver accepted switching $tag ${if (want) "on" else "off"} but after " +
          "${TRANSPORT_SETTLE_TRIES * TRANSPORT_SETTLE_MS}ms the bearer manager reports it " +
          "${if (now == true) "on" else "off"}, the driver's own row reports " +
          "${if (row == null) "nothing yet" else if (row) "on" else "off"}, and it has $links live link(s)",
      )
      return
    }
    main.postDelayed(
      {
        runCatching { awaitTransportState(b, tag, want, promise, triesLeft - 1) }
          .onFailure { promise.reject(E_TRANSPORT, it.message ?: it.toString(), it) }
      },
      TRANSPORT_SETTLE_MS,
    )
  }

  // MARK: state mirror

  /** React Native has no Compose composition, so nothing in the process advances the global snapshot
   *  or fires a snapshot apply observer: registering one would never be called. The driver already
   *  coalesces its own refresh to roughly 4 Hz, so the mirror reads at the same cadence and emits ONLY
   *  when the payload it would send has actually changed, which keeps an idle mesh silent. */
  private val mirror = object : Runnable {
    override fun run() {
      if (!mirroring) return
      val b = bearer
      if (b != null) {
        // One bad tick must not stop the mirror, or the UI silently stops tracking the mesh.
        runCatching {
          publishPeers(b)
          publishTransports(b)
          publishMessages(b)
          if (mirrorTicks++ % HEARTBEAT_TICKS == 0L) logState(b)
        }.onFailure { Log.w(TAG, "state mirror tick failed", it) }
      }
      main.postDelayed(this, MIRROR_MS)
    }
  }

  /** Counts, plus one opaque row per peer, so a bridge that holds peers the UI does not render can be
   *  told apart from a bridge that holds none. A row is an address PREFIX with hops and reachability,
   *  never a display name or message text, which keeps it safe in a release build (a peer's address is
   *  already visible to everyone on the mesh, and eight characters of it is not).
   *
   *  This is the line that separates "the driver's collections are empty" from "the event path is
   *  dead", and now also from "the app filtered every row it was given". The driver writes peers, seen
   *  and linkTransports in ONE onUi block at the end of its refresh, so linkTransports greater than
   *  zero with peers at zero means links exist but no presence advert has arrived, while everything at
   *  zero WHILE the driver is logging peerLinks lines means the driver's writes are not reaching this
   *  reader at all. */
  private fun logState(b: HopBearer) {
    val self = runCatching { addressBase58(b.node.address()) }.getOrNull() ?: ""
    val rows = peerRows(b).joinToString(" ") { (p, reachable) ->
      val addr = addressBase58(p.address)
      val tag = if (addr == self) "SELF" else if (reachable) "up" else "seen"
      "${addr.take(8)}/$tag/h${p.hops.toInt()}"
    }
    Log.i(
      TAG,
      "HOPBRIDGE state peers=${b.peers.size} seen=${b.seen.size} links=${b.linkTransports.size} " +
        "transports=${b.transports.size} messages=${b.messages.size} mirroring=$mirroring " +
        "self=${self.take(8)} rows=[$rows]",
    )
  }

  private fun startMirror() {
    if (mirroring) return
    mirroring = true
    main.post(mirror)
  }

  private fun stopMirror() {
    mirroring = false
    main.removeCallbacks(mirror)
  }

  /** Reachable peers first, then the ones only seen before, which is the order the native demo's chat
   *  list shows them in. The driver keeps the two lists disjoint.
   *
   *  The Boolean is the CONTRACT's `active`, meaning routable right now, and it comes from WHICH list the
   *  row was in. It is deliberately not the driver's own `Peer.active`, which means the far end's app is
   *  foregrounded: measured on device, every row in `b.peers` carried active=false while the mesh had
   *  four links up, so mapping that field put every reachable peer in the app's offline bucket and the
   *  chat list rendered "none" while the bridge was emitting three peers. The Apple bridge maps
   *  reachability the same way, so the two platforms agree. */
  private fun peerRows(b: HopBearer): List<Pair<HopBearer.Peer, Boolean>> =
    b.peers.toList().map { it to true } + b.seen.toList().map { it to false }

  private fun publishPeers(b: HopBearer) {
    val rows = peerRows(b)
    val sig = StringBuilder()
    for ((p, reachable) in rows) {
      sig.append(addressBase58(p.address)).append('\u0001').append(p.name)
        .append('\u0001').append(p.hops.toInt()).append('\u0001').append(p.platform)
        .append('\u0001').append(p.app).append('\u0001').append(reachable).append('\n')
    }
    val key = sig.toString()
    if (key == lastPeers) return
    val arr = Arguments.createArray()
    for ((p, reachable) in rows) arr.pushMap(peerMap(p, reachable))
    if (emit(EVENT_PEERS, arr, rows.size)) lastPeers = key
  }

  private fun peerMap(p: HopBearer.Peer, reachable: Boolean): WritableMap = Arguments.createMap().apply {
    putString("address", addressBase58(p.address))
    // Never empty. An advert with no name renders as a short base58 prefix, the same fallback the
    // driver's own displayName uses, so a peer is always addressable by something a human can read.
    putString("name", p.name.ifBlank { HopBearer.shortHex(p.address) })
    putInt("hops", p.hops.toInt())
    putString("platform", p.platform)
    putString("app", p.app)
    putBoolean("active", reachable)
  }

  private fun publishTransports(b: HopBearer) {
    val rows = transportRows(b)
    val key = rows.joinToString("\n") { "${it.first}\u0001${it.second}" }
    if (key == lastTransports) return
    if (emit(EVENT_TRANSPORTS, transportMap(rows), rows.size)) lastTransports = key
  }

  private fun transportMap(rows: List<Pair<String, String>>): WritableMap =
    Arguments.createMap().apply { for ((label, state) in rows) putString(label, state) }

  /** Every registered transport as (label, state), in the driver's own fixed display order so a row
   *  never jumps around.
   *
   *  enabled and the live link count come from transportStates / activeTransportCounts, the
   *  BearerManager itself, rather than from the driver's UI mirror: that mirror is written from the
   *  transport control thread and can lag a toggle that has already applied. The mirror is still what
   *  supplies the human LABEL for a tag, and a bearer the manager knows before the first refresh has
   *  listed it falls back to its tag, exactly as the driver's own row builder does. */
  private fun transportRows(b: HopBearer): List<Pair<String, String>> {
    val listed = b.transports.toList()
    val states = b.transportStates()
    val links = b.activeTransportCounts()
    val rows = ArrayList<Pair<String, String>>(states.size)
    for (row in listed) {
      val on = states[row.tag] ?: row.enabled
      rows += row.name to transportState(on, links[row.tag] ?: row.links)
    }
    for ((tag, on) in states) {
      if (listed.none { it.tag == tag }) rows += tag to transportState(on, links[tag] ?: 0)
    }
    return rows
  }

  /** Three states, agreed with the iOS bridge so JavaScript needs no per-platform branch: "off" when
   *  the host switched the transport off, "idle" when it is on with no live link, "active" when it is
   *  carrying links. */
  private fun transportState(enabled: Boolean, links: Int): String = when {
    !enabled -> "off"
    links > 0 -> "active"
    else -> "idle"
  }

  /** The BearerManager tag for a transport named by JavaScript. Accepts either the label the transports
   *  event carries ("Bluetooth") or the driver's own tag ("BT"), because a UI round-trips whatever it
   *  was given. The pairing comes from the driver's own rows, so there is no mapping table here to
   *  drift out of date. */
  private fun resolveTransportTag(b: HopBearer, transport: String): String? {
    val wanted = transport.trim()
    val listed = b.transports.toList()
    listed.firstOrNull { it.tag == wanted || it.name == wanted }?.let { return it.tag }
    listed.firstOrNull { it.tag.equals(wanted, true) || it.name.equals(wanted, true) }
      ?.let { return it.tag }
    return b.transportStates().keys.firstOrNull { it.equals(wanted, true) }
  }

  private fun publishMessages(b: HopBearer) {
    val byPeer = LinkedHashMap<String, MutableList<HopBearer.Message>>()
    for (m in b.messages.toList()) byPeer.getOrPut(m.peer) { ArrayList() }.add(m)
    for ((peer, thread) in byPeer) {
      val key = thread.joinToString("\n") {
        "${it.localId}\u0001${statusOf(it)}\u0001${it.sentAt}\u0001${it.text.length}"
      }
      if (key == lastMessages[peer]) continue
      val arr = Arguments.createArray()
      for (m in thread) arr.pushMap(messageMap(m))
      val sent = emit(
        EVENT_MESSAGES,
        Arguments.createMap().apply {
          putString("peer", peer)
          putArray("messages", arr)
        },
        thread.size,
      )
      if (sent) lastMessages[peer] = key
    }
    // A conversation the driver dropped (deleteConversation / deleteHistory) has to be reported as
    // empty, or JavaScript would keep rendering a thread that no longer exists.
    val gone = lastMessages.keys - byPeer.keys
    for (peer in gone) {
      val sent = emit(
        EVENT_MESSAGES,
        Arguments.createMap().apply {
          putString("peer", peer)
          putArray("messages", Arguments.createArray())
        },
        0,
      )
      if (sent) lastMessages.remove(peer)
    }
  }

  private fun messageMap(m: HopBearer.Message): WritableMap = Arguments.createMap().apply {
    putString("id", m.localId.toString())
    putString("body", m.text)
    putBoolean("mine", !m.incoming)
    // Epoch millis does not fit an Int, and the bridge has no putLong. For an incoming message the
    // driver stamps sentAt on arrival, so this is the local timeline in both directions.
    putDouble("at", m.sentAt.toDouble())
    putString("status", statusOf(m))
  }

  /** The five contract statuses, read off the same driver fields the native demo's message row reads:
   *  a message the node never accepted is still "sending", one it stamped with a bundle id is "sent",
   *  one a peer passed along is "relayed", and the recipient's ack makes it "delivered". An incoming
   *  message has by definition arrived. */
  private fun statusOf(m: HopBearer.Message): String = when {
    m.incoming -> "delivered"
    m.failed -> "failed"
    m.delivered -> "delivered"
    m.relayed > 0u -> "relayed"
    m.bundleId != null -> "sent"
    else -> "sending"
  }

  // MARK: plumbing

  /** NativeEventEmitter requires both of these on Android; without them React Native warns on every
   *  subscription.
   *
   *  addListener also drops the diff cache, so the next mirror tick re-sends the CURRENT peers,
   *  transports and message threads. The mirror only emits on change, so a listener that attaches while
   *  the mesh is already settled would otherwise receive nothing until something moved. This app's
   *  JavaScript subscribes before it starts the driver, so that is not what a silent bridge means here;
   *  it is for a re-subscribe (a reload, a remounted screen) landing on a mesh that has stopped
   *  changing. */
  @ReactMethod
  fun addListener(eventName: String) = onMain {
    Log.i(TAG, "HOPBRIDGE listener attached: $eventName, replaying state")
    lastPeers = null
    lastTransports = null
    lastMessages.clear()
  }

  @ReactMethod
  fun removeListeners(count: Int) = Unit

  /** Returns whether the event actually went out, so a caller only records the payload as sent when it
   *  was. Recording it regardless would poison the diff cache: the state would look "already sent" and
   *  never be emitted again, which is indistinguishable from an empty mesh. */
  /** Publish an event to JavaScript.
   *
   *  `getJSModule(RCTDeviceEventEmitter).emit` does NOT deliver on this stack. Measured on a release
   *  build, React Native 0.87 bridgeless: seven events logged as emitted with an active React instance
   *  and zero drops, while BOTH a NativeEventEmitter subscription and a DeviceEventEmitter subscription
   *  in JavaScript received nothing at all. `ReactContext.emitDeviceEvent` is the path that works in
   *  bridgeless and legacy alike, so it is the one used here.
   */
  private fun emit(event: String, body: Any, count: Int): Boolean {
    if (!reactContext.hasActiveReactInstance()) {
      // Worth a warning rather than a silent return: an event dropped here looks exactly like a mesh
      // with nothing in it.
      Log.w(TAG, "HOPBRIDGE dropped $event n=$count: no active react instance")
      return false
    }
    reactContext.emitDeviceEvent(event, body)
    Log.i(TAG, "HOPBRIDGE emit $event n=$count")
    return true
  }

  private fun requireBearer(promise: Promise): HopBearer? {
    val b = bearer
    if (b == null) {
      promise.reject(E_NOT_STARTED, "the driver is not running: call HopDriver.start(name) first")
    }
    return b
  }

  /** Run a bridged call's body on the main thread and turn ANY throw into a rejected promise. Without
   *  the catch, a throw from inside the posted block would surface on the main thread with the promise
   *  never settled, which takes the app down instead of failing one call. */
  private fun onMain(promise: Promise, code: String, block: () -> Unit) = onMain {
    try {
      block()
    } catch (t: Throwable) {
      promise.reject(code, t.message ?: t.toString(), t)
    }
  }

  private fun onMain(block: () -> Unit) {
    if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
  }

  companion object {
    private const val NAME = "HopDriver"
    private const val TAG = "HopDriverModule"
    private const val EVENT_PEERS = "HopDriver:peers"
    private const val EVENT_MESSAGES = "HopDriver:messages"
    private const val EVENT_TRANSPORTS = "HopDriver:transports"
    private const val EVENT_URL = "HopDriver:url"

    /** The live module, so the host Activity can hand a warm intent straight to the bridge. Set on
     *  construction because React Native builds exactly one instance per React context. */
    @Volatile private var live: HopDriverModule? = null

    /** Called from MainActivity.onNewIntent. Delivers the URL to JavaScript if a listener is attached,
     *  and otherwise parks it for the next [launchURL] read, so an automation command cannot be lost in
     *  the window before JavaScript subscribes. */
    @JvmStatic
    fun deliverURL(url: String?) {
      val target = live ?: return
      if (url.isNullOrBlank()) return
      target.pendingLaunchURL = url
      target.onMain {
        if (target.emit(EVENT_URL, url, 1)) target.pendingLaunchURL = null
      }
    }

    /** Where the demo participant name lives, so it survives a relaunch with no new JS dependency. */
    private const val PREFS = "hopdemo"
    private const val KEY_NAME = "participantName"

    /** Matches the driver's own coalesced refresh rate. */
    private const val MIRROR_MS = 250L

    /** Mirror ticks between state heartbeats, so a bridge holding an empty mesh says so on device
     *  roughly every five seconds without logging at the mirror's own rate. */
    private const val HEARTBEAT_TICKS = 20L

    /** How a transport toggle is confirmed: poll the bearer manager every [TRANSPORT_SETTLE_MS] up to
     *  [TRANSPORT_SETTLE_TRIES] times before failing the call. Bringing a radio up is not instant, and
     *  the ceiling is what stops a dead bearer from leaving a promise pending forever. */
    private const val TRANSPORT_SETTLE_MS = 50L
    private const val TRANSPORT_SETTLE_TRIES = 100

    /** Any 16-bit code the host does not reuse; Activity rejects anything wider. */
    private const val PERMISSION_REQUEST_CODE = 0x486F

    private val OPTIONAL_PERMISSIONS = setOf(Manifest.permission.POST_NOTIFICATIONS)

    private const val E_ARGUMENT = "hop_driver_bad_argument"
    private const val E_NOT_STARTED = "hop_driver_not_started"
    private const val E_NO_ACTIVITY = "hop_driver_no_activity"
    private const val E_PERMISSIONS = "hop_driver_permissions_failed"
    private const val E_PERSIST = "hop_driver_persist_failed"
    private const val E_RENAME = "hop_driver_rename_needs_restart"
    private const val E_SEND = "hop_driver_send_failed"
    private const val E_START = "hop_driver_start_failed"
    private const val E_STATE = "hop_driver_state_failed"
    private const val E_STOP = "hop_driver_stop_failed"
    private const val E_TRANSPORT = "hop_driver_transport_failed"
  }
}
