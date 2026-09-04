// HopNode: the idiomatic JS face of the on-device Hop client SDK, one method per native bridge call.
// It is a thin, type-safe shim over the `HopMesh` native module (which itself wraps sdk/android's
// Kotlin `HopNode` and sdk/apple's Swift `HopNode`), adding only JS ergonomics: Uint8Array/string
// bodies, base58 addresses, Promises, and an EventEmitter-shaped subscription surface over the pump.
//
// The class takes its native module and emitter by injection so the messaging logic is unit-testable
// without React Native; index.ts wires the real, lazily-resolved bridge.

import { asBytes, fromBase64, toBase64 } from "./base64";
import {
  HopEvent,
  HopNativeModule,
  NativeHpsTopic,
  NativeHpsTopicInfo,
} from "./native";
import {
  HopHpsInvite,
  HopHpsMessage,
  HopHpsTopic,
  HopHpsTopicInfo,
  HopMessage,
  HopOutgoing,
  HopRelayPool,
  HopRole,
  HopSendOptions,
  HopServiceRequest,
  HopServiceResponse,
  HopStatus,
  HpsAccess,
  HpsKind,
  HpsVisibility,
} from "./types";

export interface Emitter {
  addListener(event: string, cb: (payload: any) => void): { remove(): void };
}

/** An unsubscribe handle returned by the `on*` methods. */
export interface Subscription {
  remove(): void;
}

function decodeMessage(p: any): HopMessage {
  return {
    id: fromBase64(p.id),
    from: p.from,
    contentType: p.contentType,
    body: fromBase64(p.body),
    hops: p.hops,
    createdAt: p.createdAt,
  };
}

function decodeServiceRequest(p: any): HopServiceRequest {
  return {
    from: p.from,
    requestId: fromBase64(p.requestId),
    service: p.service,
    method: p.method,
    args: fromBase64(p.args),
  };
}

function decodeServiceResponse(p: any): HopServiceResponse {
  return {
    from: p.from,
    forRequestId: fromBase64(p.forRequestId),
    status: p.status,
    body: fromBase64(p.body),
  };
}

/** The `HopMesh:hpsMessage` event payload, exactly as both native pumps emit it. */
interface HpsMessagePayload {
  readonly node: number;
  readonly id: string;
  readonly path: string;
  readonly sender: string;
  readonly body: string;
}

/** The `HopMesh:hpsInvite` event payload, exactly as both native pumps emit it. */
interface HpsInvitePayload {
  readonly node: number;
  readonly host: string;
  readonly path: string;
  readonly kind: string;
}

function decodeHpsMessage(p: HpsMessagePayload): HopHpsMessage {
  return {
    id: fromBase64(p.id),
    path: p.path,
    sender: p.sender,
    body: fromBase64(p.body),
  };
}

// `kind` and `access` reach JS as plain strings, because a string is what an RN bridge carries. The
// decoders below narrow them to the public unions WITHOUT rewriting a value the union does not
// contain: an unrecognized access mode stays unrecognized and fails every comparison, where
// normalizing it to "open" would show a gated topic as an open one.
function decodeHpsInvite(p: HpsInvitePayload): HopHpsInvite {
  return {
    host: p.host,
    path: p.path,
    kind: p.kind as HpsKind,
  };
}

function decodeHpsTopic(t: NativeHpsTopic): HopHpsTopic {
  return {
    host: t.host,
    path: t.path,
    kind: t.kind as HpsKind,
    hosting: t.hosting,
    access: t.access as HpsAccess,
  };
}

function decodeHpsTopicInfo(t: NativeHpsTopicInfo): HopHpsTopicInfo {
  return {
    host: t.host,
    path: t.path,
    kind: t.kind as HpsKind,
    title: t.title,
    summary: t.summary,
    access: t.access as HpsAccess,
  };
}

function assertSafeInteger(val: number, name: string): void {
  if (typeof val !== "number" || !Number.isSafeInteger(val) || val < 0) {
    throw new RangeError(`${name} must be a safe non-negative integer, got ${val}`);
  }
}

function assertStatus(val: number): void {
  if (typeof val !== "number" || !Number.isInteger(val) || val < 0 || val > 65535) {
    throw new RangeError(`status must be an integer between 0 and 65535, got ${val}`);
  }
}

/**
 * A running Hop node. Owns a native `HopNode` handle; call `close()` when done.
 *
 * The core is poll-model: nothing is pushed asynchronously until you `start()` the pump. The pump ticks
 * the clock, drains outbound packets (delivered as `onOutgoing` events for your bearer to transmit),
 * and polls the inbox, the hops:// queues and the hps:// queues, surfacing each as an event. Inbox
 * items, responses and hps:// publications repeat on every poll until you `acceptInbox` /
 * `acceptServiceResponse` / `acceptHpsMessage` them. hps:// INVITES are the exception: the pump takes
 * and clears them, so a drained invite is gone and a host must persist what it surfaces.
 */
export class HopNode {
  constructor(
    private readonly native: HopNativeModule,
    private readonly emitter: Emitter,
    /** The opaque native handle. Exposed for advanced interop; treat as read-only. */
    public readonly handle: number,
  ) {}

  // ---- identity + config ----

  /** This node's address, base58-encoded. */
  address(): Promise<string> {
    return this.native.address(this.handle);
  }

  /** This node's 32-byte identity secret; persist it to restore the node later. */
  async secret(): Promise<Uint8Array> {
    return fromBase64(await this.native.secret(this.handle));
  }

  /** Set the display name reported via presence / hop.identify. */
  setName(name: string): Promise<void> {
    return this.native.setName(this.handle, name);
  }

  /** Subscribe to an hps:// topic. */
  subscribe(topic: string): Promise<void> {
    return this.native.subscribe(this.handle, topic);
  }

  /** Publish a fresh prekey bundle to the directory. */
  publishPrekey(): Promise<boolean> {
    return this.native.publishPrekey(this.handle);
  }

  /** Advance the node clock. The pump calls this for you; only needed for manual driving. */
  async tick(nowMs: number = Date.now()): Promise<void> {
    assertSafeInteger(nowMs, "nowMs");
    return this.native.tick(this.handle, nowMs);
  }

  /** False means the db path was unusable and the node is running ephemerally (state won't survive). */
  isPersistent(): Promise<boolean> {
    return this.native.isPersistent(this.handle);
  }

  /** True only when the store is SQLCipher-keyed at rest (F-25, ABI-001). */
  isEncrypted(): Promise<boolean> {
    return this.native.isEncrypted(this.handle);
  }
  /** How many persisted records failed to decode on startup; non-zero means state lost on upgrade. */
  rehydrateDropped(): Promise<number> {
    return this.native.rehydrateDropped(this.handle);
  }

  /** Whether we hold a forward-secret session with `addr` (content is ratcheted, not static-sealed). */
  isSecured(addr: string): Promise<boolean> {
    return this.native.isSecured(this.handle, addr);
  }

  // ---- messaging ----

  /** Send an untraceable (section 39) message. Resolves the 32-byte bundle id, or null on error. */
  async send(opts: HopSendOptions): Promise<Uint8Array | null> {
    const id = await this.native.send(
      this.handle,
      opts.to,
      opts.contentType ?? "text/plain",
      toBase64(asBytes(opts.body)),
      opts.requestAck ?? false,
    );
    return id == null ? null : fromBase64(id);
  }

  /** Send to a directly-connected peer (the directed section 27 path). Resolves the bundle id, or null. */
  async sendTo(opts: HopSendOptions): Promise<Uint8Array | null> {
    const id = await this.native.sendTo(
      this.handle,
      opts.to,
      opts.contentType ?? "text/plain",
      toBase64(asBytes(opts.body)),
      opts.requestAck ?? false,
    );
    return id == null ? null : fromBase64(id);
  }

  /** Delivery status of a message we sent, by its bundle id. */
  status(id: Uint8Array): Promise<HopStatus> {
    return this.native.status(this.handle, toBase64(id));
  }

  /** Durably accept one inbox item (by its id) so it stops repeating on the next poll. */
  acceptInbox(id: Uint8Array): Promise<boolean> {
    return this.native.acceptInbox(this.handle, toBase64(id));
  }

  // ---- hops:// request / response ----

  /** Send an hops:// service request. Resolves the request id, or null on error. */
  async sendServiceRequest(args: {
    to: string;
    service: string;
    method: string;
    args: Uint8Array | string;
  }): Promise<Uint8Array | null> {
    const id = await this.native.sendServiceRequest(
      this.handle,
      args.to,
      args.service,
      args.method,
      toBase64(asBytes(args.args)),
    );
    return id == null ? null : fromBase64(id);
  }

  /** Reply to an hops:// service request. */
  async sendServiceResponse(args: {
    to: string;
    forRequestId: Uint8Array;
    status: number;
    body: Uint8Array | string;
  }): Promise<boolean> {
    assertStatus(args.status);
    return this.native.sendServiceResponse(
      this.handle,
      args.to,
      toBase64(args.forRequestId),
      args.status,
      toBase64(asBytes(args.body)),
    );
  }

  /** Durably accept a previously-polled response by its 32-byte correlation request id. */
  acceptServiceResponse(forRequestId: Uint8Array): Promise<boolean> {
    return this.native.acceptServiceResponse(this.handle, toBase64(forRequestId));
  }

  /** Durably accept a previously-polled request by its 32-byte request id. */
  acceptServiceRequest(requestId: Uint8Array): Promise<boolean> {
    return this.native.acceptServiceRequest(this.handle, toBase64(requestId));
  }

  /** Reject a previously-polled request without ACK so a retransmission can retry. */
  rejectServiceRequest(requestId: Uint8Array): Promise<boolean> {
    return this.native.rejectServiceRequest(this.handle, toBase64(requestId));
  }
  // ---- bearer seam (drive a transport from JS) ----

  /** Bring a bearer link up. `link` is any app-chosen id; `role` is who dialed. */
  async linkUp(link: number, role: HopRole): Promise<void> {
    assertSafeInteger(link, "link");
    return this.native.linkUp(this.handle, link, role);
  }

  async linkDown(link: number): Promise<void> {
    assertSafeInteger(link, "link");
    return this.native.linkDown(this.handle, link);
  }

  async bytesReceived(link: number, bytes: Uint8Array): Promise<void> {
    assertSafeInteger(link, "link");
    return this.native.bytesReceived(this.handle, link, toBase64(bytes));
  }
  // ---- section 19 relay pool ----
  //
  // Without these an app is stuck on one hardcoded relay URL, which is the single point of failure
  // section 19 exists to remove: any endpoint the node learns about can be pooled, scored and dialed
  // in preference order.

  /**
   * Offer a relay endpoint to the pool. Resolves true if the endpoint is now pooled.
   *
   * `configured` marks an operator or user choice, which a gossiped endpoint can never demote, and it
   * defaults to true here because a URL an app hands in came from a person or a build, not the mesh.
   */
  relayAdd(url: string, configured: boolean = true): Promise<boolean> {
    return this.native.relayAdd(this.handle, url, configured);
  }

  /**
   * The relay to dial right now, or null when there is nothing dialable.
   *
   * null with a non-zero `relayPool().total` is the degraded "every candidate is backed off" state. A
   * UI must show it as that and retry, NOT as offline: the pool still knows where to retry, and the
   * backoff always eventually recovers. null with a zero total is an empty pool, which is the case
   * `relayAdd` fixes.
   */
  relayNext(): Promise<string | null> {
    return this.native.relayNext(this.handle);
  }

  /** Report a dial outcome so the pool can score it. A success clears that endpoint's failure history;
   *  failures back it off exponentially and always eventually recover. */
  relayReport(url: string, ok: boolean): Promise<void> {
    return this.native.relayReport(this.handle, url, ok);
  }

  /** Pooled endpoint counts: total known, and how many are dialable right now. */
  relayPool(): Promise<HopRelayPool> {
    return this.native.relayPool(this.handle);
  }

  // ---- hps:// pub/sub (section 32): services and channels ----
  //
  // A Hop group message is not one-to-one fan-out and not a multicast bundle. It is a single
  // content-key-encrypted, per-writer-signed publication, flooded once, so a post costs the same
  // whether a topic has three members or three hundred. Membership, invites and revocation are
  // properties of the topic's key handoff, never of the delivery: `hpsRekey` rotates the content key
  // and withholds it from the addresses it removes, and that is what revocation means here.

  /**
   * Host a topic at `path`. The node mints its keys and persists them, so the topic survives restarts.
   *
   * Resolves the service public key subscribers verify broadcasts with. That key is EMPTY for a
   * channel, which has no service signing key because every member writes under their own identity, so
   * an empty result is a success. Failure is null, and the two are deliberately distinguishable.
   */
  async hpsRegister(
    path: string,
    kind: HpsKind,
    access: HpsAccess = "open",
    visibility: HpsVisibility = "private",
  ): Promise<Uint8Array | null> {
    const pubkey = await this.native.hpsRegister(this.handle, path, kind, access, visibility);
    return pubkey == null ? null : fromBase64(pubkey);
  }

  /** Subscribe to `hps://{host}/{path}`: ask the host for the topic's keys. Resolves the request's
   *  bundle id, or null. Whether the keys arrive at all is the access mode's call, not this one's. */
  async hpsSubscribe(host: string, path: string): Promise<Uint8Array | null> {
    const id = await this.native.hpsSubscribe(this.handle, host, path);
    return id == null ? null : fromBase64(id);
  }

  /** Publish to a topic we host, or (for a channel) belong to. Resolves the bundle id, or null. */
  async hpsPublish(path: string, body: Uint8Array | string): Promise<Uint8Array | null> {
    const id = await this.native.hpsPublish(this.handle, path, toBase64(asBytes(body)));
    return id == null ? null : fromBase64(id);
  }

  /**
   * Durably accept one hps:// publication (by its id) so it stops repeating on the next poll.
   *
   * The pump polls with the NON-accepting poll, exactly as it does the inbox: a publication stays
   * queued until JS accepts it, so one that arrives while the JS side crashes is redelivered rather
   * than lost. Accept it once your own store holds it.
   */
  acceptHpsMessage(id: Uint8Array): Promise<boolean> {
    return this.native.acceptHpsMessage(this.handle, toBase64(id));
  }

  /** Host to contact: invite an address to a topic we host (the `invite` access mode). Resolves the
   *  invite's bundle id, or null. */
  async hpsInvite(path: string, dest: string): Promise<Uint8Array | null> {
    const id = await this.native.hpsInvite(this.handle, path, dest);
    return id == null ? null : fromBase64(id);
  }

  /** Accept an invite we received: joins the topic once the host seals us the keys. */
  async hpsAcceptInvite(host: string, path: string): Promise<Uint8Array | null> {
    const id = await this.native.hpsAcceptInvite(this.handle, host, path);
    return id == null ? null : fromBase64(id);
  }

  /** Decline an invite. Durable, so the host does not re-offer it. */
  hpsDeclineInvite(host: string, path: string): Promise<boolean> {
    return this.native.hpsDeclineInvite(this.handle, host, path);
  }

  /**
   * Leave a topic we follow, or retire one we host.
   *
   * The native call also yields the leave bundle's id; this narrows to the ok flag on purpose, because
   * an RN client has nothing to do with that id (there is no hps status query to correlate it against).
   */
  hpsLeave(path: string): Promise<boolean> {
    return this.native.hpsLeave(this.handle, path);
  }

  /** Host: the addresses waiting for approval on a `requestToJoin` topic, base58-encoded. */
  hpsPending(path: string): Promise<string[]> {
    return this.native.hpsPending(this.handle, path);
  }

  /** Host: approve a pending requester, which is what hands them the content key. Resolves the
   *  handoff's bundle id, or null. */
  async hpsApprove(path: string, requester: string): Promise<Uint8Array | null> {
    const id = await this.native.hpsApprove(this.handle, path, requester);
    return id == null ? null : fromBase64(id);
  }

  /** Host: deny a pending requester. No key is handed out. */
  hpsDeny(path: string, requester: string): Promise<boolean> {
    return this.native.hpsDeny(this.handle, path, requester);
  }

  /**
   * Host: rotate the topic's content key, optionally onto `newPath`, withholding it from `remove`.
   *
   * This is what revocation is here: a removed address keeps whatever it already read and can decrypt
   * nothing published after the rotation. Resolves one bundle id per member the new key was sealed to.
   */
  async hpsRekey(path: string, newPath: string = "", remove: string[] = []): Promise<Uint8Array[]> {
    const ids = await this.native.hpsRekey(this.handle, path, newPath, remove);
    return ids.map((id) => fromBase64(id));
  }

  /** Host: how many distinct members have acked a publication on this topic. An Open topic keeps no
   *  member list, so an ack is the only moment it learns a member's address at all. */
  hpsReach(path: string): Promise<number> {
    return this.native.hpsReach(this.handle, path);
  }

  /** Host: the retained member set for this topic, base58-encoded. */
  hpsMembers(path: string): Promise<string[]> {
    return this.native.hpsMembers(this.handle, path);
  }

  /** Every topic this node hosts or follows, read from the node's own store. Use it to rebuild a topic
   *  list at startup rather than persisting one yourself. */
  async hpsMyTopics(): Promise<HopHpsTopic[]> {
    const topics = await this.native.hpsMyTopics(this.handle);
    return topics.map(decodeHpsTopic);
  }

  /** Discoverable topics found on the mesh: decrypted descriptors, not subscriptions. Only topics
   *  hosted by apps holding the same app secret are ever surfaced (section 17). */
  async hpsBrowse(): Promise<HopHpsTopicInfo[]> {
    const found = await this.native.hpsBrowse(this.handle);
    return found.map(decodeHpsTopicInfo);
  }

  // ---- pump + events ----

  /** Start the native pump: tick, drain outbound, and poll the inbox / hops:// / hps:// queues on an
   *  interval. */
  start(intervalMs: number = 250): Promise<void> {
    return this.native.startPump(this.handle, intervalMs);
  }

  /** Stop the pump. Events stop until `start()` is called again. */
  stop(): Promise<void> {
    return this.native.stopPump(this.handle);
  }

  private subscribe$<T>(event: string, decode: (p: any) => T, cb: (value: T) => void): Subscription {
    return this.emitter.addListener(event, (payload) => {
      if (payload?.node === this.handle) cb(decode(payload));
    });
  }

  /** Subscribe to inbound messages. Returns an unsubscribe handle. */
  onMessage(cb: (message: HopMessage) => void): Subscription {
    return this.subscribe$(HopEvent.Message, decodeMessage, cb);
  }

  /** Subscribe to inbound hops:// service requests (this node acting as a service). */
  onServiceRequest(cb: (request: HopServiceRequest) => void): Subscription {
    return this.subscribe$(HopEvent.ServiceRequest, decodeServiceRequest, cb);
  }

  /** Subscribe to inbound hops:// service responses (this node acting as a caller). */
  onServiceResponse(cb: (response: HopServiceResponse) => void): Subscription {
    return this.subscribe$(HopEvent.ServiceResponse, decodeServiceResponse, cb);
  }

  /** Subscribe to outbound packets the core wants transmitted (hand them to your bearer). */
  onOutgoing(cb: (out: HopOutgoing) => void): Subscription {
    return this.subscribe$(
      HopEvent.Outgoing,
      (p) => ({ link: p.link, bytes: fromBase64(p.bytes) }),
      cb,
    );
  }

  /** Subscribe to inbound hps:// publications on topics this node hosts or follows. Each repeats on
   *  every poll until `acceptHpsMessage`. */
  onHpsMessage(cb: (message: HopHpsMessage) => void): Subscription {
    return this.subscribe$(HopEvent.HpsMessage, decodeHpsMessage, cb);
  }

  /** Subscribe to inbound hps:// invites. Take-and-clear, not accept-to-remove: the native queue drops
   *  an invite as it is emitted, so persist what this hands you or it is gone. */
  onHpsInvite(cb: (invite: HopHpsInvite) => void): Subscription {
    return this.subscribe$(HopEvent.HpsInvite, decodeHpsInvite, cb);
  }

  /** Free the native node. Idempotent. */
  close(): Promise<void> {
    return this.native.closeNode(this.handle);
  }
}
