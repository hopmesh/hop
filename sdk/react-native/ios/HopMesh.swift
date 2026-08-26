// The iOS half of @hop-mesh/react-native. It owns one native HopNode and HopRuntime at a time:
// native BLE/LAN bearers form links, receive bytes, and drain the node's outbound queue without
// exposing packet transport to JavaScript.
import Foundation
import Hop
import HopContract
import HopBearerBle
import HopBearerLan
import React

@objc(HopMesh)
final class HopMesh: RCTEventEmitter {
  private final class Entry {
    let handle = 1
    let node: HopNode
    let runtime: HopRuntime
    var timer: DispatchSourceTimer?

    private let stateLock = NSLock()
    private var revision = 0
    private var lastStates = ["ble": "enabled", "lan": "enabled", "relay": "disabled"]

    init(node: HopNode) {
      self.node = node
      self.runtime = HopRuntime(node: node)

      // The transport id is process-local and intentionally unrelated to the node address. BLE and LAN
      // receive the same 16 bytes so their peer tiebreaker and duplicate-link behavior agree.
      let transportId = randomNodeId()
      runtime.register(BleBearer(myId: transportId))
      runtime.register(LanBearer(myId: transportId))
    }

    func snapshot() -> (body: [String: Any], changed: Bool) {
      let enabled = runtime.bearers.bearerStates()
      let active = runtime.bearers.activeTransports()
      let states = [
        "ble": nativeState(tag: "BT", enabled: enabled, active: active),
        "lan": nativeState(tag: "LAN", enabled: enabled, active: active),
        // Relay has a separate native-bearer probe. This cross-platform bridge intentionally owns BLE
        // and LAN only, so it never advertises a relay capability it does not register.
        "relay": "disabled",
      ]

      stateLock.lock(); defer { stateLock.unlock() }
      let changed = states != lastStates
      if changed {
        revision += 1
        lastStates = states
      }
      return (["revision": revision, "states": states], changed)
    }

    private func nativeState(tag: String, enabled: [String: Bool], active: [String: Int]) -> String {
      guard enabled[tag] == true else { return "disabled" }
      return active[tag, default: 0] > 0 ? "active" : "enabled"
    }
  }

  private let lock = NSLock()
  private var runtimeEntry: Entry?
  private var opening = false
  private var hasListeners = false

  // Serial queue that owns every pump tick so the runtime never drains the node from two threads at once.
  private let pumpQueue = DispatchQueue(label: "sh.hop.reactnative.pump")

  override static func requiresMainQueueSetup() -> Bool { false }

  override func supportedEvents() -> [String]! {
    ["HopMesh:message", "HopMesh:serviceRequest", "HopMesh:serviceResponse", "HopMesh:bearerState",
     "HopMesh:hpsMessage", "HopMesh:hpsInvite"]
  }

  override func startObserving() { hasListeners = true }
  override func stopObserving() { hasListeners = false }

  // MARK: registry helpers

  private func reserveOpen() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard runtimeEntry == nil, !opening else { return false }
    opening = true
    return true
  }

  private func registerReserved(_ node: HopNode) -> Int? {
    lock.lock(); defer { lock.unlock() }
    guard opening, runtimeEntry == nil else { return nil }
    let entry = Entry(node: node)
    runtimeEntry = entry
    opening = false
    return entry.handle
  }

  private func abandonReservedOpen() {
    lock.lock(); opening = false; lock.unlock()
  }

  private func entry(for handle: Int) -> Entry? {
    lock.lock(); defer { lock.unlock() }
    guard runtimeEntry?.handle == handle else { return nil }
    return runtimeEntry
  }

  private func node(_ handle: Int) -> HopNode? {
    entry(for: handle)?.node
  }

  private func data(_ b64: String) -> Data { Data(base64Encoded: b64) ?? Data() }
  private func b64(_ data: Data) -> String { data.base64EncodedString() }

  // MARK: hps:// enum mapping
  //
  // Enums cross the bridge as lowercase strings. An UNRECOGNIZED string returns nil here and the
  // calling method fails the promise; it is NEVER coerced to `.open` or `.channel`, because reading a
  // garbage access mode as Open would hand a topic's keys to anyone who asks. The reverse direction
  // (topics and invites going out) is total, so it needs no fallback.
  private func hpsKind(_ text: String) -> HpsKind? {
    switch text {
    case "channel": return .channel
    case "service": return .service
    default: return nil
    }
  }

  private func hpsAccess(_ text: String) -> HpsAccess? {
    switch text {
    case "open": return .open
    case "requestToJoin": return .requestToJoin
    case "invite": return .invite
    default: return nil
    }
  }

  private func hpsVisibility(_ text: String) -> HpsVisibility? {
    switch text {
    case "private": return .topicPrivate
    case "discoverable": return .discoverable
    default: return nil
    }
  }

  // Exhaustive switches, not a ternary with a fallthrough: a kind or access mode added to the SDK
  // must break this build rather than quietly render as the last case.
  private func name(_ kind: HpsKind) -> String {
    switch kind {
    case .channel: return "channel"
    case .service: return "service"
    }
  }

  private func name(_ access: HpsAccess) -> String {
    switch access {
    case .open: return "open"
    case .requestToJoin: return "requestToJoin"
    case .invite: return "invite"
    }
  }

  private func badEnum(_ reject: RCTPromiseRejectBlock, _ field: String, _ value: String) {
    reject("hop_error", "unrecognized hps \(field): \(value)", nil)
  }

  // MARK: lifecycle

  @objc(createEphemeral:rejecter:)
  func createEphemeral(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard reserveOpen() else {
      return reject("hop_node_exists", "a Hop node is already open in this native process; close it before opening another", nil)
    }
    guard let node = HopNode.ephemeral() else {
      abandonReservedOpen()
      return reject("hop_error", "hop_node_new returned null", nil)
    }
    guard let handle = registerReserved(node) else {
      abandonReservedOpen()
      return reject("hop_node_exists", "a Hop node is already open in this native process; close it before opening another", nil)
    }
    resolve(handle)
  }

  @objc(createWithSecret:resolver:rejecter:)
  func createWithSecret(_ secretB64: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard reserveOpen() else {
      return reject("hop_node_exists", "a Hop node is already open in this native process; close it before opening another", nil)
    }
    guard let node = HopNode.with(secret: data(secretB64)) else {
      abandonReservedOpen()
      return reject("hop_error", "hop_node_with_secret returned null", nil)
    }
    guard let handle = registerReserved(node) else {
      abandonReservedOpen()
      return reject("hop_node_exists", "a Hop node is already open in this native process; close it before opening another", nil)
    }
    resolve(handle)
  }

  @objc(openPersistent:secret:appSecret:resolver:rejecter:)
  func openPersistent(_ dbPath: String, secret secretB64: String, appSecret appSecretB64: String,
                      resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard reserveOpen() else {
      return reject("hop_node_exists", "a Hop node is already open in this native process; close it before opening another", nil)
    }
    guard let node = HopNode.open(dbPath: dbPath, secret: data(secretB64), appSecret: data(appSecretB64)) else {
      abandonReservedOpen()
      return resolve(-1)
    }
    guard let handle = registerReserved(node) else {
      abandonReservedOpen()
      return reject("hop_node_exists", "a Hop node is already open in this native process; close it before opening another", nil)
    }
    resolve(handle)
  }

  @objc(openKeyed:key:secret:appSecret:resolver:rejecter:)
  func openKeyed(_ dbPath: String, key keyB64: String, secret secretB64: String, appSecret appSecretB64: String,
                 resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard reserveOpen() else {
      return reject("hop_node_exists", "a Hop node is already open in this native process; close it before opening another", nil)
    }
    guard let node = HopNode.openKeyed(dbPath: dbPath, key: data(keyB64), secret: data(secretB64), appSecret: data(appSecretB64)) else {
      abandonReservedOpen()
      return resolve(-1)
    }
    guard let handle = registerReserved(node) else {
      abandonReservedOpen()
      return reject("hop_node_exists", "a Hop node is already open in this native process; close it before opening another", nil)
    }
    resolve(handle)
  }

  @objc(closeNode:resolver:rejecter:)
  func closeNode(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    lock.lock()
    guard let entry = runtimeEntry, entry.handle == handle else {
      lock.unlock()
      return resolve(nil)
    }
    entry.timer?.cancel()
    entry.timer = nil
    entry.runtime.stop()
    runtimeEntry = nil
    lock.unlock()
    resolve(nil)
  }

  // MARK: identity + config

  @objc(address:resolver:rejecter:)
  func address(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(HopAddress.base58(node.address))
  }

  @objc(secret:resolver:rejecter:)
  func secret(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(b64(node.secret))
  }

  @objc(setName:name:resolver:rejecter:)
  func setName(_ handle: Int, name: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    node.setName(name); resolve(nil)
  }

  @objc(subscribe:topic:resolver:rejecter:)
  func subscribe(_ handle: Int, topic: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    node.subscribe(topic); resolve(nil)
  }

  @objc(publishPrekey:resolver:rejecter:)
  func publishPrekey(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.publishPrekey())
  }

  @objc(tick:nowMs:resolver:rejecter:)
  func tick(_ handle: Int, nowMs: Double, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    node.tick(nowMs: UInt64(nowMs)); resolve(nil)
  }

  @objc(isPersistent:resolver:rejecter:)
  func isPersistent(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.isPersistent)
  }

  @objc(rehydrateDropped:resolver:rejecter:)
  func rehydrateDropped(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(Int(node.rehydrateDropped))
  }

  @objc(isSecured:addr:resolver:rejecter:)
  func isSecured(_ handle: Int, addr addrB58: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let addr = HopAddress.fromBase58(addrB58) else { return resolve(false) }
    resolve(node.isSecured(addr))
  }

  // MARK: messaging

  @objc(send:to:contentType:body:requestAck:resolver:rejecter:)
  func send(_ handle: Int, to toB58: String, contentType: String, body bodyB64: String, requestAck: Bool,
            resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let dst = HopAddress.fromBase58(toB58) else { return resolve(nil) }
    let id = node.send(to: dst, contentType: contentType, body: data(bodyB64), requestAck: requestAck)
    resolve(id.map(b64))
  }

  @objc(sendTo:to:contentType:body:requestAck:resolver:rejecter:)
  func sendTo(_ handle: Int, to toB58: String, contentType: String, body bodyB64: String, requestAck: Bool,
              resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let dst = HopAddress.fromBase58(toB58) else { return resolve(nil) }
    let id = node.sendTo(peer: dst, contentType: contentType, body: data(bodyB64), requestAck: requestAck)
    resolve(id.map(b64))
  }

  @objc(status:id:resolver:rejecter:)
  func status(_ handle: Int, id idB64: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    let s = node.status(of: data(idB64))
    resolve(["relayed": Int(s.relayed), "delivered": s.delivered, "forwardHops": Int(s.forwardHops), "forwardMs": Int(s.forwardMs)])
  }

  @objc(acceptInbox:id:resolver:rejecter:)
  func acceptInbox(_ handle: Int, id idB64: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.acceptInbox(data(idB64)))
  }

  // MARK: hops:// request / response

  @objc(sendServiceRequest:to:service:method:args:resolver:rejecter:)
  func sendServiceRequest(_ handle: Int, to toB58: String, service: String, method: String, args argsB64: String,
                          resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let dst = HopAddress.fromBase58(toB58) else { return resolve(nil) }
    let id = node.sendServiceRequest(to: dst, service: service, method: method, args: data(argsB64))
    resolve(id.map(b64))
  }

  @objc(sendServiceResponse:to:forRequestId:status:body:resolver:rejecter:)
  func sendServiceResponse(_ handle: Int, to toB58: String, forRequestId reqB64: String, status: Int, body bodyB64: String,
                           resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let dst = HopAddress.fromBase58(toB58) else { return resolve(false) }
    let ok = node.sendServiceResponse(to: dst, forRequestId: data(reqB64), status: UInt16(truncatingIfNeeded: status), body: data(bodyB64))
    resolve(ok)
  }

  @objc(acceptServiceResponse:forRequestId:resolver:rejecter:)
  func acceptServiceResponse(_ handle: Int, forRequestId reqB64: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.acceptServiceResponse(forRequestId: data(reqB64)))
  }

  // MARK: native bearer manager

  private func emitBearerSnapshot(_ entry: Entry, force: Bool = false) -> [String: Any] {
    let snapshot = entry.snapshot()
    if force || snapshot.changed {
      var event = snapshot.body
      event["node"] = entry.handle
      send("HopMesh:bearerState", event)
    }
    return snapshot.body
  }

  @objc(bearerSnapshot:resolver:rejecter:)
  func bearerSnapshot(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let entry = entry(for: handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(emitBearerSnapshot(entry))
  }

  @objc(setBearerEnabled:bearer:enabled:resolver:rejecter:)
  func setBearerEnabled(_ handle: Int, bearer: String, enabled: Bool,
                        resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let entry = entry(for: handle) else { return reject("hop_error", "unknown node handle", nil) }
    switch bearer {
    case "ble":
      entry.runtime.bearers.setEnabled("BT", enabled)
    case "lan":
      entry.runtime.bearers.setEnabled("LAN", enabled)
    case "relay":
      if enabled {
        return reject(
          "hop_bearer_unavailable",
          "relay is intentionally outside the cross-platform native bridge; probe it through its native bearer package",
          nil
        )
      }
    default:
      return reject("hop_error", "unrecognized bearer: \(bearer)", nil)
    }
    resolve(emitBearerSnapshot(entry))
  }

  // MARK: section 19 relay pool

  @objc(relayAdd:url:configured:resolver:rejecter:)
  func relayAdd(_ handle: Int, url: String, configured: Bool, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.relayAdd(url, configured: configured))
  }

  // nil means nothing is dialable RIGHT NOW, which is not the same as offline: a non-zero relayPool
  // total with nothing dialable is the degraded "every candidate is backed off" state, and the JS
  // wrapper documents that distinction for the UI that has to render it.
  @objc(relayNext:resolver:rejecter:)
  func relayNext(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.relayNext())
  }

  @objc(relayReport:url:ok:resolver:rejecter:)
  func relayReport(_ handle: Int, url: String, ok: Bool, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    node.relayReport(url, ok: ok); resolve(nil)
  }

  @objc(relayPool:resolver:rejecter:)
  func relayPool(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    let pool = node.relayPool()
    resolve(["total": pool.total, "available": pool.available])
  }

  // MARK: hps:// pub/sub (section 32)
  //
  // A publication is a single content-key-encrypted, per-writer-signed message flooded once, not a
  // fan-out and not a multicast bundle. Membership, invites and revocation are properties of the
  // topic's key handoff, which is why `hpsApprove` and `hpsRekey` resolve bundle ids: each one is a
  // key handoff sealed to a member.

  @objc(hpsRegister:path:kind:access:visibility:resolver:rejecter:)
  func hpsRegister(_ handle: Int, path: String, kind kindText: String, access accessText: String, visibility visibilityText: String,
                   resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let kind = hpsKind(kindText) else { return badEnum(reject, "kind", kindText) }
    guard let access = hpsAccess(accessText) else { return badEnum(reject, "access", accessText) }
    guard let visibility = hpsVisibility(visibilityText) else { return badEnum(reject, "visibility", visibilityText) }
    // Empty is a channel's correct answer (no service signing key), so it resolves an empty string
    // rather than nil; nil is reserved for the register having failed.
    resolve(node.hpsRegister(path: path, kind: kind, access: access, visibility: visibility).map(b64))
  }

  @objc(hpsSubscribe:host:path:resolver:rejecter:)
  func hpsSubscribe(_ handle: Int, host hostB58: String, path: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let host = HopAddress.fromBase58(hostB58) else { return resolve(nil) }
    resolve(node.hpsSubscribe(host: host, path: path).map(b64))
  }

  @objc(hpsPublish:path:body:resolver:rejecter:)
  func hpsPublish(_ handle: Int, path: String, body bodyB64: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.hpsPublish(path: path, body: data(bodyB64)).map(b64))
  }

  @objc(acceptHpsMessage:id:resolver:rejecter:)
  func acceptHpsMessage(_ handle: Int, id idB64: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.acceptHpsMessage(data(idB64)))
  }

  @objc(hpsInvite:path:dest:resolver:rejecter:)
  func hpsInvite(_ handle: Int, path: String, dest destB58: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let dest = HopAddress.fromBase58(destB58) else { return resolve(nil) }
    resolve(node.hpsInvite(path: path, dest: dest).map(b64))
  }

  @objc(hpsAcceptInvite:host:path:resolver:rejecter:)
  func hpsAcceptInvite(_ handle: Int, host hostB58: String, path: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let host = HopAddress.fromBase58(hostB58) else { return resolve(nil) }
    resolve(node.hpsAcceptInvite(host: host, path: path).map(b64))
  }

  @objc(hpsDeclineInvite:host:path:resolver:rejecter:)
  func hpsDeclineInvite(_ handle: Int, host hostB58: String, path: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let host = HopAddress.fromBase58(hostB58) else { return resolve(false) }
    resolve(node.hpsDeclineInvite(host: host, path: path))
  }

  // The native call also yields the leave bundle's id; JS gets only the ok flag, because an RN client
  // has nothing to correlate that id against.
  @objc(hpsLeave:path:resolver:rejecter:)
  func hpsLeave(_ handle: Int, path: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.hpsLeave(path: path).ok)
  }

  @objc(hpsPending:path:resolver:rejecter:)
  func hpsPending(_ handle: Int, path: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.hpsPending(path: path).map(HopAddress.base58))
  }

  @objc(hpsApprove:path:requester:resolver:rejecter:)
  func hpsApprove(_ handle: Int, path: String, requester requesterB58: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let requester = HopAddress.fromBase58(requesterB58) else { return resolve(nil) }
    resolve(node.hpsApprove(path: path, requester: requester).map(b64))
  }

  @objc(hpsDeny:path:requester:resolver:rejecter:)
  func hpsDeny(_ handle: Int, path: String, requester requesterB58: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    guard let requester = HopAddress.fromBase58(requesterB58) else { return resolve(false) }
    resolve(node.hpsDeny(path: path, requester: requester))
  }

  // An unparsable address in the remove list FAILS the whole call rather than being skipped. Skipping
  // it would rotate the key and report success while the member the caller asked to revoke still holds
  // a usable one, which is the worst possible outcome to report as an ok.
  @objc(hpsRekey:path:newPath:remove:resolver:rejecter:)
  func hpsRekey(_ handle: Int, path: String, newPath: String, remove removeB58: [String],
                resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    var remove: [Data] = []
    for text in removeB58 {
      guard let addr = HopAddress.fromBase58(text) else {
        return reject("hop_error", "unparsable address in the hps remove list: \(text)", nil)
      }
      remove.append(addr)
    }
    resolve(node.hpsRekey(path: path, newPath: newPath, remove: remove).map(b64))
  }

  @objc(hpsReach:path:resolver:rejecter:)
  func hpsReach(_ handle: Int, path: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(Int(node.hpsReach(path: path)))
  }

  @objc(hpsMembers:path:resolver:rejecter:)
  func hpsMembers(_ handle: Int, path: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.hpsMembers(path: path).map(HopAddress.base58))
  }

  @objc(hpsMyTopics:resolver:rejecter:)
  func hpsMyTopics(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.hpsMyTopics().map { topic -> [String: Any] in
      [
        "host": HopAddress.base58(topic.host),
        "path": topic.path,
        "kind": name(topic.kind),
        "hosting": topic.hosting,
        "access": name(topic.access),
      ]
    })
  }

  @objc(hpsBrowse:resolver:rejecter:)
  func hpsBrowse(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    resolve(node.hpsBrowse().map { topic -> [String: Any] in
      [
        "host": HopAddress.base58(topic.host),
        "path": topic.path,
        "kind": name(topic.kind),
        "title": topic.title,
        "summary": topic.summary,
        "access": name(topic.access),
      ]
    })
  }

  // MARK: pump

  @objc(startPump:intervalMs:resolver:rejecter:)
  func startPump(_ handle: Int, intervalMs: Double, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let entry = entry(for: handle) else { return reject("hop_error", "unknown node handle", nil) }
    entry.timer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
    let interval = max(intervalMs, 10) / 1000.0
    timer.schedule(deadline: .now(), repeating: interval)
    timer.setEventHandler { [weak self] in self?.pump(handle) }
    entry.timer = timer
    entry.runtime.start()
    timer.resume()
    _ = emitBearerSnapshot(entry, force: true)
    resolve(nil)
  }

  @objc(stopPump:resolver:rejecter:)
  func stopPump(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let entry = entry(for: handle) else { return reject("hop_error", "unknown node handle", nil) }
    entry.timer?.cancel()
    entry.timer = nil
    entry.runtime.stop()
    _ = emitBearerSnapshot(entry)
    resolve(nil)
  }

  private func pump(_ handle: Int) {
    guard let entry = entry(for: handle) else { return }
    let node = entry.node
    entry.runtime.tick(nowMs: UInt64(Date().timeIntervalSince1970 * 1000))
    entry.runtime.pump()
    node.pollInbox { m in
      self.send("HopMesh:message", [
        "node": handle,
        "id": self.b64(m.id),
        "from": HopAddress.base58(m.from),
        "contentType": m.contentType,
        "body": self.b64(m.body),
        "hops": Int(m.hops),
        "createdAt": Double(m.createdAt),
      ])
    }
    node.pollServiceRequests { r in
      self.send("HopMesh:serviceRequest", [
        "node": handle,
        "from": HopAddress.base58(r.from),
        "requestId": self.b64(r.requestId),
        "service": r.service,
        "method": r.method,
        "args": self.b64(r.args),
      ])
    }
    node.pollServiceResponses { r in
      self.send("HopMesh:serviceResponse", [
        "node": handle,
        "from": HopAddress.base58(r.from),
        "forRequestId": self.b64(r.forRequestId),
        "status": Int(r.status),
        "body": self.b64(r.body),
      ])
    }
    // The NON-accepting poll, exactly like pollInbox above: a publication stays queued until JS calls
    // acceptHpsMessage, so one that arrives while the JS side crashes is redelivered, not lost.
    node.pollHpsMessages { m in
      self.send("HopMesh:hpsMessage", [
        "node": handle,
        "id": self.b64(m.id),
        "path": m.path,
        "sender": HopAddress.base58(m.sender),
        "body": self.b64(m.body),
      ])
    }
    // Take-and-clear, not accept-to-remove: a drained invite is gone, so the JS side must persist what
    // this hands it.
    node.pollHpsInvites { inv in
      self.send("HopMesh:hpsInvite", [
        "node": handle,
        "host": HopAddress.base58(inv.host),
        "path": inv.path,
        "kind": self.name(inv.kind),
      ])
    }
    _ = emitBearerSnapshot(entry)
  }

  // MARK: address helpers

  @objc(addressToBase58:resolver:rejecter:)
  func addressToBase58(_ bytesB64: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    resolve(HopAddress.base58(data(bytesB64)))
  }

  @objc(addressFromBase58:resolver:rejecter:)
  func addressFromBase58(_ text: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    resolve(HopAddress.fromBase58(text).map(b64))
  }

  // Only emit when JS is listening (avoids RCTEventEmitter warnings during startup/teardown).
  private func send(_ event: String, _ body: [String: Any]) {
    guard hasListeners else { return }
    sendEvent(withName: event, body: body)
  }
}
