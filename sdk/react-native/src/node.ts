// HopNode: the idiomatic JS face of the on-device Hop client SDK, one method per native bridge call.
// It is a thin, type-safe shim over the `HopMesh` native module (which itself wraps sdk/android's
// Kotlin `HopNode` and sdk/apple's Swift `HopNode`), adding only JS ergonomics: Uint8Array/string
// bodies, base58 addresses, Promises, and an EventEmitter-shaped subscription surface over the pump.
//
// The class takes its native module and emitter by injection so the messaging logic is unit-testable
// without React Native; index.ts wires the real, lazily-resolved bridge.

import { asBytes, fromBase64, toBase64 } from "./base64";
import { HopEvent, HopNativeModule } from "./native";
import {
  HopMessage,
  HopOutgoing,
  HopRole,
  HopSendOptions,
  HopServiceRequest,
  HopServiceResponse,
  HopStatus,
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

/**
 * A running Hop node. Owns a native `HopNode` handle; call `close()` when done.
 *
 * The core is poll-model: nothing is pushed asynchronously until you `start()` the pump. The pump ticks
 * the clock, drains outbound packets (delivered as `onOutgoing` events for your bearer to transmit),
 * and polls the inbox and hops:// queues, surfacing each as an event. Inbox items and responses repeat
 * on every poll until you `acceptInbox` / `acceptServiceResponse` them.
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
  tick(nowMs: number = Date.now()): Promise<void> {
    return this.native.tick(this.handle, nowMs);
  }

  /** False means the db path was unusable and the node is running ephemerally (state won't survive). */
  isPersistent(): Promise<boolean> {
    return this.native.isPersistent(this.handle);
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
  sendServiceResponse(args: {
    to: string;
    forRequestId: Uint8Array;
    status: number;
    body: Uint8Array | string;
  }): Promise<boolean> {
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

  // ---- bearer seam (drive a transport from JS) ----

  /** Bring a bearer link up. `link` is any app-chosen id; `role` is who dialed. */
  linkUp(link: number, role: HopRole): Promise<void> {
    return this.native.linkUp(this.handle, link, role);
  }

  /** Bring a bearer link down. */
  linkDown(link: number): Promise<void> {
    return this.native.linkDown(this.handle, link);
  }

  /** Feed inbound bytes received on `link` from the transport into the core. */
  bytesReceived(link: number, bytes: Uint8Array): Promise<void> {
    return this.native.bytesReceived(this.handle, link, toBase64(bytes));
  }

  // ---- pump + events ----

  /** Start the native pump: tick, drain outbound, and poll the inbox / hops:// queues on an interval. */
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

  /** Free the native node. Idempotent. */
  close(): Promise<void> {
    return this.native.closeNode(this.handle);
  }
}
