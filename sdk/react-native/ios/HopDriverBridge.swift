// The iOS half of the React Native `HopDriver` module: the Apple platform DRIVER
// (drivers/apple/HopDriver) exposed to JavaScript, so a React Native app gets the same radios, peers
// and chat threads the native SwiftUI demo gets.
//
// WHY A SECOND MODULE ALONGSIDE HopMesh. HopMesh bridges the node/link PRIMITIVES (linkUp,
// bytesReceived, startPump) and nothing else, which leaves JavaScript to supply its own transport.
// JavaScript has none, so the React Native demo could only ever talk to an in-process loopback stub:
// no Bluetooth prompt, a single "Unknown loopback peer", and no way to send a message. The native
// demos are not built that way at all, they are built on `HopBearer`, which owns CoreBluetooth,
// Multipeer, LAN and the cloud relay. Bridging the bearer is what makes a React Native app a real
// peer on the mesh instead of a mock of one. HopMesh is untouched, it is still the right surface for
// a host that wants to drive a bare node.
//
// The bearer is constructed exactly the way apps/apple/HopDemo constructs it (HopDemoApp.swift): the
// Keychain-backed identity and db key from `IdentityStore.secrets()`, `hop.db` in Application
// Support, the dev app secret, the anycast default relay, `.full` role. Mirroring it matters, a
// different app secret or db path would put this app on its own island and the two demos would stop
// seeing each other, which is the whole thing being tested.

import Combine
import CoreBluetooth
import Foundation
import HopDriver
import React
import UIKit

@objc(HopDriver)
final class HopDriverBridge: RCTEventEmitter {
  private static let peersEvent = "HopDriver:peers"
  private static let messagesEvent = "HopDriver:messages"
  private static let transportsEvent = "HopDriver:transports"

  /// The UserDefaults key the batch contract fixes for the demo participant name. Deliberately NOT
  /// the driver's own `hop.displayName`: this one is written by JavaScript (which owns generating the
  /// random name) and read back on the next launch, while `hop.displayName` is the driver's record of
  /// the name it is currently advertising. They hold the same string in practice and are set through
  /// different calls (`savePersistedName` vs `setName`), so coupling them here would make one call
  /// silently do the other's job.
  private static let participantNameKey = "participantName"

  private var bearer: HopBearer?
  /// Kept so a construction failure is reported to every later call instead of being retried into a
  /// second Keychain prompt or a second open handle on hop.db.
  private var bearerFailure: Error?
  private var cancellables: Set<AnyCancellable> = []
  private var hasListeners = false
  /// A native heartbeat is the device-side oracle when JavaScript console output is unavailable.
  /// It is deliberately independent of JS listeners and contains counts only.
  private var heartbeat: DispatchSourceTimer?


  /// Transports `stop()` switched off, so `start()` can put back exactly those and not clobber a
  /// per-transport preference it never set. The Apple driver has no public teardown (unlike Android,
  /// whose bearer stops synchronously), going radio silent is per-bearer, so that is what stop means
  /// here.
  private var stoppedTags: [String] = []

  /// Per-peer thread signature of the last `HopDriver:messages` emission, so a change to one chat
  /// does not re-emit every other chat. `bearer.messages` is one flat array that changes on every
  /// send, receive and delivery report.
  private var emittedThreads: [String: Int] = [:]
  /// Thread sizes from emissions that ACTUALLY crossed the React bridge. Separate from the content
  /// signature so a delivery-state-only emission does not look like a newly arrived message.
  private var emittedThreadCounts: [String: Int] = [:]


  // MARK: React Native plumbing

  override static func requiresMainQueueSetup() -> Bool { false }

  override func supportedEvents() -> [String]! {
    [HopDriverBridge.peersEvent, HopDriverBridge.messagesEvent, HopDriverBridge.transportsEvent]
  }

  override func startObserving() { hasListeners = true }
  override func stopObserving() { hasListeners = false }

  /// Emit one native line for every event attempt. Counts only, never peer names, addresses or bodies,
  /// so it is safe in a release build. Returning whether the event crossed matters to the message diff
  /// cache: recording a payload as sent while no listener existed would suppress the first real event
  /// when JavaScript attaches later.
  @discardableResult
  private func emit(_ event: String, _ body: Any, count: Int) -> Bool {
    guard hasListeners else {
      NSLog("HOPBRIDGE dropped \(event) n=\(count): no JS listeners")
      return false
    }
    sendEvent(withName: event, body: body)
    NSLog("HOPBRIDGE emit \(event) n=\(count)")
    return true
  }

  /// Roughly every five seconds, state whether the DRIVER has anything and whether this bridge is
  /// mirroring it. This separates "the driver holds nothing" from "events are not crossing" without a
  /// debugger or JavaScript console. The five fields and wording match Android's HOPBRIDGE heartbeat.
  private func startHeartbeat(_ bearer: HopBearer) {
    guard heartbeat == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .seconds(5), leeway: .milliseconds(250))
    timer.setEventHandler { [weak self, weak bearer] in
      guard let self, let bearer else { return }
      NSLog(
        "HOPBRIDGE state peers=\(bearer.reachable.count) seen=\(bearer.seen.count) "
          + "links=\(bearer.linkTransports.count) transports=\(bearer.transports.count) "
          + "messages=\(bearer.messages.count) mirroring=\(self.heartbeat != nil)"
      )
    }
    heartbeat = timer
    timer.resume()
  }

  private func stopHeartbeat() {
    heartbeat?.cancel()
    heartbeat = nil
  }


  /// Run bearer work on the main queue and hand back its result.
  ///
  /// `HopBearer` publishes and mutates its state on main (`send(_:to:)` appends to `messages`,
  /// `flushPendingSaves` and the shutdown path assert `.onQueue(.main)`), and React Native calls a
  /// classic bridge module on a background queue it owns. This is the same hop the driver already
  /// does for its own address-based send, rather than an override of the deprecated `methodQueue`
  /// property, so a bridged method stays synchronous and its promise resolves in one turn.
  private func onMain<T>(_ work: () throws -> T) rethrows -> T {
    Thread.isMainThread ? try work() : try DispatchQueue.main.sync(execute: work)
  }

  // MARK: the bearer

  /// Lazily build the one bearer this process owns, mirroring HopDemoApp.swift. The native app calls
  /// `fatalError` when secure storage fails; a bridge must not take the React Native host down with
  /// it, so the error is surfaced as a rejected promise instead. Nothing is faked, a caller that
  /// cannot get an identity gets told so.
  private func liveBearer() throws -> HopBearer {
    if let bearer { return bearer }
    if let bearerFailure { throw bearerFailure }
    do {
      let secrets = try IdentityStore.secrets()
      let dbPath = try HopStorage.applicationSupportURL(fileName: "hop.db").path
      let built = HopBearer(config: .init(
        dbPath: dbPath,
        deviceSeed: secrets.identity,
        appSecret: HopBearer.appSecret,
        // `HopBearer.savedName(default:)` verbatim, the same helper HopDemoApp.swift passes, reading
        // the driver's own `hop.displayName`. This is the INITIAL name only, and `start(name:)`
        // immediately overrides it with the name JavaScript chose. `participantName` is deliberately
        // not consulted here: it belongs to the two persistence methods the contract defines, and
        // reading it at construction would give this bridge a different configuration from the native
        // demo for no gain, when the very next call sets the name anyway.
        displayName: HopBearer.savedName(default: UIDevice.current.name),
        defaultRelay: HopBearer.defaultRelay,
        role: .full,
        dbKey: secrets.database))
      bearer = built
      observe(built)
      return built
    } catch {
      bearerFailure = error
      throw error
    }
  }

  private func savedParticipantName() -> String? {
    let stored = UserDefaults.standard.string(forKey: HopDriverBridge.participantNameKey)
    guard let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return stored
  }

  /// Bridge the bearer's `@Published` state to the three contract events. `reachable` and `seen` are
  /// combined because one peer list crossing the bridge has to say which peers are live and which are
  /// only remembered, and those are two separate properties on the driver.
  private func observe(_ bearer: HopBearer) {
    Publishers.CombineLatest(bearer.$reachable, bearer.$seen)
      .sink { [weak self] reachable, seen in
        guard let self else { return }
        let body = HopDriverBridge.peerBodies(reachable: reachable, seen: seen)
        self.emit(HopDriverBridge.peersEvent, body, count: body.count)
      }
      .store(in: &cancellables)

    bearer.$messages
      .sink { [weak self] messages in
        guard let self else { return }
        self.emitThreads(from: messages, bearer: bearer)
      }
      .store(in: &cancellables)

    // `removeDuplicates` so the event means "a transport changed", which is what the UI subscribes for.
    // `refresh()` republishes this array on a timer as well as after a toggle, and `@Published` fires on
    // every assignment regardless of whether the value moved, so without this a toggle event is
    // indistinguishable from routine churn. Safe here because TransportStatus synthesises Equatable over
    // all of its stored properties.
    //
    // Deliberately NOT applied to the peer publishers above: `Peer.==` compares the address ALONE, on
    // purpose, so a peer whose name or hop count changed is `==` to its old value and deduping would
    // swallow a real update.
    bearer.$transports
      .removeDuplicates()
      .sink { [weak self] transports in
        guard let self else { return }
        let body = HopDriverBridge.transportBody(transports)
        self.emit(HopDriverBridge.transportsEvent, body, count: body.count)
      }
      .store(in: &cancellables)
  }

  // MARK: mapping

  /// A peer's `active` is membership in `reachable`, NOT `Peer.active`. The driver's flag means the
  /// far end's app is in the foreground; the contract's field means we can route to them now. Android
  /// maps it the same way.
  private static func peerBodies(reachable: [HopBearer.Peer], seen: [HopBearer.Peer]) -> [[String: Any]] {
    let live = Set(reachable.map(\.address))
    let historical = seen.filter { !live.contains($0.address) }
    return reachable.map { peerBody($0, active: true) } + historical.map { peerBody($0, active: false) }
  }

  private static func peerBody(_ peer: HopBearer.Peer, active: Bool) -> [String: Any] {
    let base58 = addressBase58(address: peer.address)
    return [
      "address": base58,
      "name": displayName(peer.name, base58: base58),
      "hops": Int(peer.hops),
      // Passed through verbatim. The wire vocabulary is wider than a two-platform enum: presence and
      // hop.identify report "ios", "android" or "cloud" (relays and hops:// endpoints), and an
      // unadvertised platform is "". Translating that here would make the bridge claim something the
      // mesh never said and would quietly erase "cloud".
      "platform": peer.platform,
      "app": peer.app,
      "active": active,
    ]
  }

  /// Never empty, per the contract. A peer that has not published a presence advert yet has no name,
  /// and "" in a chat list is indistinguishable from a bug, so fall back to the short base58 prefix
  /// the driver itself uses for the same purpose (`HopBearer.shortHex`).
  private static func displayName(_ name: String, base58: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? String(base58.prefix(8)) : trimmed
  }

  private static func transportBody(_ transports: [HopBearer.TransportStatus]) -> [String: String] {
    var body: [String: String] = [:]
    for transport in transports {
      // Three states, not two, matching the driver's own reasoning and Android's mapping: a transport
      // the host switched off is not the same as one that is on and simply has no links yet.
      body[transport.id] = !transport.enabled ? "off" : (transport.links > 0 ? "active" : "idle")
    }
    return body
  }

  private static func messageBody(_ message: HopBearer.Message) -> [String: Any] {
    [
      "id": message.id.uuidString,
      "body": message.text,
      "mine": !message.incoming,
      // `sentAt` is the only stamp present on every message: for an outgoing one it is when we sent
      // it, for an incoming one when we received it. `originAt` is the sender's own clock and is
      // deliberately bucketed to the minute on the private path, so it is not a sort key.
      "at": message.sentAt.timeIntervalSince1970 * 1000,
      "status": status(message),
    ]
  }

  /// Delivery state, most-final first. An incoming message has by definition arrived, so it reports
  /// "delivered" rather than borrowing the outgoing ladder. `bundleId` is the node's acceptance of an
  /// outgoing bundle, which is the moment "sending" becomes "sent".
  private static func status(_ message: HopBearer.Message) -> String {
    if message.incoming { return "delivered" }
    if message.failed { return "failed" }
    if message.delivered { return "delivered" }
    if message.relayed > 0 { return "relayed" }
    return message.bundleId == nil ? "sending" : "sent"
  }

  /// Group the flat message log into per-peer threads keyed by base58 address.
  ///
  /// `Message.peerAddr` is optional because history persisted before it existed carries only the peer
  /// NAME, so a thread is matched by address first and by name second. Dropping the nameless ones
  /// would silently lose old chats; inventing an address for them would be worse.
  private func threads(from messages: [HopBearer.Message], bearer: HopBearer) -> [String: [HopBearer.Message]] {
    var nameToAddress: [String: String] = [:]
    for peer in bearer.reachable + bearer.seen + bearer.contactList {
      let base58 = addressBase58(address: peer.address)
      nameToAddress[HopDriverBridge.displayName(peer.name, base58: base58)] = base58
      if !peer.name.isEmpty { nameToAddress[peer.name] = base58 }
    }
    var grouped: [String: [HopBearer.Message]] = [:]
    for message in messages {
      let key: String? = message.peerAddr.map { addressBase58(address: $0) } ?? nameToAddress[message.peer]
      guard let key else { continue }
      grouped[key, default: []].append(message)
    }
    return grouped
  }

  private func emitThreads(from messages: [HopBearer.Message], bearer: HopBearer) {
    let grouped = threads(from: messages, bearer: bearer)
    for (peer, thread) in grouped {
      // Change detection over EVERY message, not just the newest.
      //
      // Signing count plus the newest message looked cheaper and was wrong: the driver's refresh()
      // updates delivery state on ANY outgoing message still in flight, so an older bubble going from
      // "sent" to "delivered" leaves both the count and the newest message untouched. That thread
      // would have been deduped away and the delivery tick would never have reached the UI, which is a
      // silent stall rather than a visible bug. Android signs every message for the same reason.
      //
      // id, status and sentAt together cover the three ways a thread moves: a message is added or
      // trimmed, its delivery state advances, or its timestamp is rewritten.
      let signature = thread.reduce(into: Hasher()) { hasher, message in
        hasher.combine(message.id)
        hasher.combine(HopDriverBridge.status(message))
        hasher.combine(message.sentAt)
      }.finalize()
      guard emittedThreads[peer] != signature else { continue }
      let previousCount = emittedThreadCounts[peer] ?? 0
      let sent = emit(
        HopDriverBridge.messagesEvent,
        ["peer": peer, "messages": thread.map(HopDriverBridge.messageBody)],
        count: thread.count
      )
      guard sent else { continue }
      emittedThreads[peer] = signature
      emittedThreadCounts[peer] = thread.count
      if thread.count > previousCount {
        // The one address-bearing diagnostic the device proof needs: an opaque base58 PREFIX and a
        // count, never a display name or message body. It proves a thread grew on this device.
        NSLog("HOPBRIDGE thread grew peer=\(peer.prefix(8)) n=\(thread.count)")
      }
    }
    // A thread that disappeared (retention trimmed it) must be reported as empty, or the JavaScript
    // side keeps rendering messages the driver has already dropped.
    for peer in Array(emittedThreads.keys) where grouped[peer] == nil {
      guard emit(
        HopDriverBridge.messagesEvent,
        ["peer": peer, "messages": [[String: Any]]()],
        count: 0
      ) else { continue }
      emittedThreads.removeValue(forKey: peer)
      emittedThreadCounts.removeValue(forKey: peer)
    }
  }

  // MARK: permissions

  /// iOS has no "request Bluetooth" call. CoreBluetooth prompts the first time a `CBCentralManager`
  /// or `CBPeripheralManager` is instantiated, which happens inside the BLE bearer during `start()`.
  /// So this reports whether starting CAN prompt, it does not prompt itself and must not pretend to.
  ///
  /// `granted: true` therefore means "the usage strings are present and authorization is not already
  /// refused, so calling start() is worthwhile", not "the user has said yes". A denied or restricted
  /// authorization is terminal for this launch, the only remedy is Settings, so that is the one case
  /// reported as not granted.
  @objc(ensurePermissions:rejecter:)
  func ensurePermissions(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    var missing: [String] = []
    // A missing usage string is not a user decision, it is a packaging defect: iOS kills the app on
    // first radio use for the Bluetooth one and silently refuses to advertise for the Multipeer one.
    // Naming the key makes it actionable.
    for key in ["NSBluetoothAlwaysUsageDescription", "NSLocalNetworkUsageDescription"]
    where (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.isEmpty ?? true {
      missing.append(key)
    }
    switch CBManager.authorization {
    case .denied, .restricted: missing.append("bluetooth")
    case .notDetermined, .allowedAlways: break
    @unknown default: break
    }
    resolve(["granted": missing.isEmpty, "missing": missing])
  }

  // MARK: lifecycle

  @objc(start:resolver:rejecter:)
  func start(_ name: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return reject("hop_driver_error", "start requires a non-empty display name", nil)
    }
    do {
      try onMain {
        let bearer = try liveBearer()
        bearer.start(name: trimmed)
        NSLog("HOPBRIDGE start self=\(bearer.myAddress) name=\(trimmed)")
        startHeartbeat(bearer)
        // `start(name:)` is idempotent, so after a `stop()` it returns without touching the radios.
        // Putting back exactly the transports stop switched off is what makes start/stop/start work.
        for tag in stoppedTags { bearer.setTransportEnabled(tag, true) }
        stoppedTags = []
        // The bearer publishes on change, so a listener that attached after the last change would
        // otherwise see nothing until the next one. Prime all three surfaces from current state.
        let peers = HopDriverBridge.peerBodies(reachable: bearer.reachable, seen: bearer.seen)
        emit(HopDriverBridge.peersEvent, peers, count: peers.count)
        let transports = HopDriverBridge.transportBody(bearer.transports)
        emit(HopDriverBridge.transportsEvent, transports, count: transports.count)
        emitThreads(from: bearer.messages, bearer: bearer)
      }
      resolve(nil)
    } catch {
      reject("hop_driver_error", "Hop could not start because secure identity storage failed: \(error)", error)
    }
  }

  /// Radio silent. The Apple driver exposes no public teardown (its `shutdownForTesting` exists so a
  /// headless test can release a bearer, and production owns exactly one for the process lifetime), so
  /// stopping means switching every registered transport off and flushing what is pending to disk.
  /// The node stays open, which is why `start()` can bring it back.
  @objc(stop:rejecter:)
  func stop(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    onMain {
      guard let bearer else { return }
      var stopped: [String] = []
      for (tag, enabled) in bearer.transportStates() where enabled {
        if bearer.setTransportEnabled(tag, false) { stopped.append(tag) }
      }
      stoppedTags = stopped
      bearer.flushPendingSaves()
    }
    stopHeartbeat()
    resolve(nil)
  }

  @objc(setName:resolver:rejecter:)
  func setName(_ name: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return reject("hop_driver_error", "setName requires a non-empty display name", nil)
    }
    do {
      try onMain { try liveBearer().setName(trimmed) }
      resolve(nil)
    } catch {
      reject("hop_driver_error", "Hop could not set the display name: \(error)", error)
    }
  }

  // MARK: name persistence

  @objc(persistedName:rejecter:)
  func persistedName(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    resolve(savedParticipantName())
  }

  @objc(savePersistedName:resolver:rejecter:)
  func savePersistedName(_ name: String, resolver resolve: RCTPromiseResolveBlock,
                         rejecter reject: RCTPromiseRejectBlock) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return reject("hop_driver_error", "savePersistedName requires a non-empty name", nil)
    }
    UserDefaults.standard.set(trimmed, forKey: HopDriverBridge.participantNameKey)
    resolve(nil)
  }

  // MARK: reads

  /// Empty before `start()`, because nothing is known yet. Deliberately does not construct the bearer:
  /// that opens hop.db and touches the Keychain, which is work a read of "who is nearby" must not do
  /// as a side effect.
  @objc(peers:rejecter:)
  func peers(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    resolve(onMain {
      guard let bearer else { return [[String: Any]]() }
      return HopDriverBridge.peerBodies(reachable: bearer.reachable, seen: bearer.seen)
    })
  }

  @objc(messages:resolver:rejecter:)
  func messages(_ peerAddressBase58: String, resolver resolve: RCTPromiseResolveBlock,
                rejecter reject: RCTPromiseRejectBlock) {
    let key = peerAddressBase58.trimmingCharacters(in: .whitespacesAndNewlines)
    resolve(onMain {
      guard let bearer else { return [[String: Any]]() }
      return (threads(from: bearer.messages, bearer: bearer)[key] ?? []).map(HopDriverBridge.messageBody)
    })
  }

  @objc(selfAddress:rejecter:)
  func selfAddress(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    resolve(onMain { bearer?.myAddress ?? "" })
  }

  // MARK: transport control

  /// The pull counterpart of the `HopDriver:transports` push, keyed identically.
  ///
  /// Read from the `BearerManager` rather than from the driver's published `transports` mirror, matching
  /// Android. The mirror is only rewritten when the driver's `refresh()` runs, so a query issued right
  /// after a toggle would hand back the pre-toggle row; `transportStates()` and
  /// `activeTransportCounts()` are lock-guarded reads of the manager itself and cannot be stale. The
  /// driver's own doc on `transportStates()` makes the same point about the mirror lagging.
  ///
  /// Keys still come from the mirror, because the display label lives only there, and the driver
  /// publishes rows in a fixed order so the labels are stable.
  @objc(transports:rejecter:)
  func transports(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    resolve(onMain {
      guard let bearer else { return [String: String]() }
      let states = bearer.transportStates()
      let links = bearer.activeTransportCounts()
      var body: [String: String] = [:]
      for row in bearer.transports {
        guard let tag = row.tag else {
          // Not a shared bearer, so the manager knows nothing about it and the mirror is all there is.
          body[row.id] = row.enabled ? (row.links > 0 ? "active" : "idle") : "off"
          continue
        }
        let on = states[tag] ?? row.enabled
        body[row.id] = on ? ((links[tag] ?? 0) > 0 ? "active" : "idle") : "off"
      }
      return body
    })
  }

  /// Enable or disable ONE bearer, so a two-device proof can run over a named transport instead of
  /// whichever one happens to win the race.
  ///
  /// `transport` is the key this bridge publishes, which is `TransportStatus.id` (a display label such
  /// as "Bluetooth"). The driver's `setTransportEnabled` takes a `TransportStatus.tag` instead ("BT"),
  /// so the label is resolved to the tag through the driver's OWN published list rather than a mapping
  /// table written here, which would rot the moment a bearer is added. The raw tag is accepted too,
  /// because an unrecognised transport is published under its tag as its id.
  ///
  /// It resolves only once the toggle has SETTLED, not when the driver accepts it, matching Android
  /// exactly so neither the JavaScript layer nor the device harness needs a per-platform branch.
  /// `HopBearer.setTransportEnabled` is fire and forget onto its own control queue with no completion
  /// callback, so settling is established by polling three readings: the manager reports the requested
  /// state, the driver's own published row agrees, and when DISABLING the live link count for that
  /// transport has reached zero.
  ///
  /// That last condition is what makes one-bearer-at-a-time honest. Without it a message could still
  /// cross on the bearer just disabled, and a proof would attribute the delivery to the wrong radio.
  /// It is answerable on Apple because switching a transport off tears its links down synchronously as
  /// a LINK SOURCE; only the radio teardown is deferred to the BLE queue. So this waits for "carrying
  /// nothing", never for "radio silent", which the driver documents as unassertable.
  ///
  /// Rejects rather than resolving when the transport is unknown, carries no toggle handle, or never
  /// settles. Silently resolving would report a toggle that never happened.
  @objc(setTransportEnabled:enabled:resolver:rejecter:)
  func setTransportEnabled(_ transport: String, enabled: Bool,
                           resolver resolve: @escaping RCTPromiseResolveBlock,
                           rejecter reject: @escaping RCTPromiseRejectBlock) {
    let wanted = transport.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let tag: String = try onMain {
        let bearer = try liveBearer()
        guard let match = bearer.transports.first(where: { $0.id == wanted || $0.tag == wanted }) else {
          throw HopDriverBridge.TransportError.unknown(wanted, bearer.transports.map(\.id))
        }
        guard let tag = match.tag else { throw HopDriverBridge.TransportError.notToggleable(match.id) }
        guard bearer.setTransportEnabled(tag, enabled) else {
          throw HopDriverBridge.TransportError.rejected(match.id, tag)
        }
        return tag
      }
      confirmTransport(tag: tag, enabled: enabled,
                       deadline: Date().addingTimeInterval(HopDriverBridge.transportSettleSeconds),
                       resolve: resolve, reject: reject)
    } catch {
      reject("hop_driver_transport_failed", "\(error)", error)
    }
  }

  /// Ceiling on how long a toggle may take to settle before it is reported as failed. Matches Android.
  private static let transportSettleSeconds: TimeInterval = 5

  /// Poll the three readings on main until they agree or the deadline passes. Polling rather than
  /// blocking because the driver offers no completion callback and the main thread must not be held for
  /// seconds while a radio starts or stops.
  private func confirmTransport(tag: String, enabled: Bool, deadline: Date,
                                resolve: @escaping RCTPromiseResolveBlock,
                                reject: @escaping RCTPromiseRejectBlock) {
    let check = { [weak self] () -> Bool? in
      // nil means "cannot answer": the module is going away, which is a failure to confirm, not a pass.
      guard let self, let bearer = self.bearer else { return nil }
      let manager = bearer.transportStates()[tag]
      let row = bearer.transports.first { $0.tag == tag }?.enabled
      let links = bearer.activeTransportCounts()[tag] ?? 0
      return manager == enabled && row == enabled && (enabled || links == 0)
    }
    guard let settled = onMain(check) else {
      return reject("hop_driver_transport_failed",
                    "the Hop driver went away before transport \"\(tag)\" could be confirmed", nil)
    }
    if settled { return resolve(nil) }
    guard Date() < deadline else {
      let detail = onMain { [weak self] () -> String in
        guard let bearer = self?.bearer else { return "no driver" }
        let manager = bearer.transportStates()[tag].map(String.init(describing:)) ?? "absent"
        // Parenthesised: `first {}?.enabled.map(…)` chains the whole postfix, so `map` would be applied
        // to the unwrapped Bool rather than to the Optional, which does not compile.
        let row = (bearer.transports.first { $0.tag == tag }?.enabled)
          .map(String.init(describing:)) ?? "absent"
        return "manager=\(manager) row=\(row) links=\(bearer.activeTransportCounts()[tag] ?? 0)"
      }
      return reject("hop_driver_transport_failed",
                    "transport \"\(tag)\" did not reach enabled=\(enabled) within "
                      + "\(Int(HopDriverBridge.transportSettleSeconds))s: \(detail)", nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      guard let self else {
        return reject("hop_driver_transport_failed",
                      "the Hop driver went away before transport \"\(tag)\" could be confirmed", nil)
      }
      self.confirmTransport(tag: tag, enabled: enabled, deadline: deadline,
                            resolve: resolve, reject: reject)
    }
  }

  private enum TransportError: Error, CustomStringConvertible {
    case unknown(String, [String])
    case notToggleable(String)
    case rejected(String, String)

    var description: String {
      switch self {
      case let .unknown(name, known):
        return "unknown transport \"\(name)\"; this device registered: \(known.joined(separator: ", "))"
      case let .notToggleable(name):
        return "transport \"\(name)\" is not a shared bearer, so it has no toggle handle"
      case let .rejected(name, tag):
        return "the driver refused to toggle \"\(name)\": no registered bearer carries the tag \"\(tag)\""
      }
    }
  }

  // MARK: send

  /// Send by address. A known peer is sent to through the ordinary peer path so the driver records
  /// the contact and reuses the name it already resolved; an address we have not discovered yet goes
  /// through `sendTo`, which the node handles by deferring and ratcheting until a route exists.
  @objc(send:toAddressBase58:resolver:rejecter:)
  func send(_ text: String, toAddressBase58 addressBase58: String,
            resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return resolve(["ok": false, "detail": "message body is empty"]) }
    let target = addressBase58.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let outcome: [String: Any] = try onMain {
        let bearer = try liveBearer()
        let address = addressFromBase58(text: target)
        guard address.count == 32 else {
          return ["ok": false, "detail": "not a Hop address: \(target)"]
        }
        let known = (bearer.reachable + bearer.seen + bearer.contactList).first { $0.address == address }
        let result = known.map { bearer.send(body, to: $0) } ?? bearer.sendTo(addressBase58: target, text: body)
        switch result {
        case .queued: return ["ok": true]
        case .invalid: return ["ok": false, "detail": "not a routable Hop address: \(target)"]
        case .overloaded: return ["ok": false, "detail": "too many messages are already pending"]
        }
      }
      resolve(outcome)
    } catch {
      reject("hop_driver_error", "Hop could not send because it failed to start: \(error)", error)
    }
  }
}
