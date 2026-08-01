// The iOS half of @hop-mesh/react-native: a classic React Native module that wraps the Swift Hop
// client SDK (sdk/apple, the `Hop` product) and exposes it to JavaScript. Binary values cross the
// bridge as base64 strings and addresses as base58 strings, matching android/ and src/native.ts.
//
// Node handles are integers minted here; the module keeps a handle -> (HopNode, pump timer) registry
// behind a lock. The pump ticks the clock, drains outbound packets, and polls the inbox and hops://
// queues on an interval, emitting one event per item over RCTEventEmitter.

import Foundation
import Hop

@objc(HopMesh)
final class HopMesh: RCTEventEmitter {
  private struct Entry {
    let node: HopNode
    var timer: DispatchSourceTimer?
  }

  private let lock = NSLock()
  private var nodes: [Int: Entry] = [:]
  private var nextHandle: Int = 1
  private var hasListeners = false

  // Serial queue that owns every pump tick so a node is never polled from two threads at once.
  private let pumpQueue = DispatchQueue(label: "sh.hop.reactnative.pump")

  override static func requiresMainQueueSetup() -> Bool { false }

  override func supportedEvents() -> [String]! {
    ["HopMesh:message", "HopMesh:serviceRequest", "HopMesh:serviceResponse", "HopMesh:outgoing"]
  }

  override func startObserving() { hasListeners = true }
  override func stopObserving() { hasListeners = false }

  // MARK: registry helpers

  private func register(_ node: HopNode) -> Int {
    lock.lock(); defer { lock.unlock() }
    let handle = nextHandle
    nextHandle += 1
    nodes[handle] = Entry(node: node, timer: nil)
    return handle
  }

  private func node(_ handle: Int) -> HopNode? {
    lock.lock(); defer { lock.unlock() }
    return nodes[handle]?.node
  }

  private func data(_ b64: String) -> Data { Data(base64Encoded: b64) ?? Data() }
  private func b64(_ data: Data) -> String { data.base64EncodedString() }

  // MARK: lifecycle

  @objc(createEphemeral:rejecter:)
  func createEphemeral(_ resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = HopNode.ephemeral() else { return reject("hop_error", "hop_node_new returned null", nil) }
    resolve(register(node))
  }

  @objc(createWithSecret:resolver:rejecter:)
  func createWithSecret(_ secretB64: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = HopNode.with(secret: data(secretB64)) else { return reject("hop_error", "hop_node_with_secret returned null", nil) }
    resolve(register(node))
  }

  @objc(openPersistent:secret:appSecret:resolver:rejecter:)
  func openPersistent(_ dbPath: String, secret secretB64: String, appSecret appSecretB64: String,
                      resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = HopNode.open(dbPath: dbPath, secret: data(secretB64), appSecret: data(appSecretB64)) else {
      return resolve(-1)
    }
    resolve(register(node))
  }

  @objc(openKeyed:key:secret:appSecret:resolver:rejecter:)
  func openKeyed(_ dbPath: String, key keyB64: String, secret secretB64: String, appSecret appSecretB64: String,
                 resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = HopNode.openKeyed(dbPath: dbPath, key: data(keyB64), secret: data(secretB64), appSecret: data(appSecretB64)) else {
      return resolve(-1)
    }
    resolve(register(node))
  }

  @objc(closeNode:resolver:rejecter:)
  func closeNode(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    lock.lock()
    if var entry = nodes[handle] {
      entry.timer?.cancel()
      entry.timer = nil
      nodes[handle] = nil
    }
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

  // MARK: bearer seam

  @objc(linkUp:link:role:resolver:rejecter:)
  func linkUp(_ handle: Int, link: Double, role: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    node.linkUp(UInt64(link), role: role == "dialer" ? .dialer : .acceptor); resolve(nil)
  }

  @objc(linkDown:link:resolver:rejecter:)
  func linkDown(_ handle: Int, link: Double, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    node.linkDown(UInt64(link)); resolve(nil)
  }

  @objc(bytesReceived:link:bytes:resolver:rejecter:)
  func bytesReceived(_ handle: Int, link: Double, bytes bytesB64: String, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    guard let node = node(handle) else { return reject("hop_error", "unknown node handle", nil) }
    node.bytesReceived(UInt64(link), data(bytesB64)); resolve(nil)
  }

  // MARK: pump

  @objc(startPump:intervalMs:resolver:rejecter:)
  func startPump(_ handle: Int, intervalMs: Double, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    lock.lock()
    guard var entry = nodes[handle] else { lock.unlock(); return reject("hop_error", "unknown node handle", nil) }
    entry.timer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: pumpQueue)
    let interval = max(intervalMs, 10) / 1000.0
    timer.schedule(deadline: .now(), repeating: interval)
    timer.setEventHandler { [weak self] in self?.pump(handle) }
    entry.timer = timer
    nodes[handle] = entry
    lock.unlock()
    timer.resume()
    resolve(nil)
  }

  @objc(stopPump:resolver:rejecter:)
  func stopPump(_ handle: Int, resolver resolve: RCTPromiseResolveBlock, rejecter reject: RCTPromiseRejectBlock) {
    lock.lock()
    if var entry = nodes[handle] {
      entry.timer?.cancel()
      entry.timer = nil
      nodes[handle] = entry
    }
    lock.unlock()
    resolve(nil)
  }

  private func pump(_ handle: Int) {
    guard let node = node(handle) else { return }
    node.tick(nowMs: UInt64(Date().timeIntervalSince1970 * 1000))
    node.drainOutgoing { link, bytes in
      self.send("HopMesh:outgoing", ["node": handle, "link": Int(link), "bytes": self.b64(bytes)])
    }
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
