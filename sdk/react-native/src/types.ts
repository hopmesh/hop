// The public value types, mirroring the Swift `HopMessage`/`HopStatus`/`HopServiceRequest`/
// `HopServiceResponse` and their Kotlin twins. Binary fields are surfaced as `Uint8Array` on the JS
// side (decoded from the base64 the bridge carries); addresses are surfaced as base58 strings, the
// human-facing form the native `HopAddress` helpers produce.

/** A decrypted message delivered to this node. */
export interface HopMessage {
  /** Stable 32-byte inbox id (use it with `acceptInbox`). */
  readonly id: Uint8Array;
  /** The sender's address, base58-encoded. */
  readonly from: string;
  readonly contentType: string;
  readonly body: Uint8Array;
  /** Forward-path length A to B. */
  readonly hops: number;
  /** Sender clock (ms) at creation. */
  readonly createdAt: number;
}

/** Delivery status of a message we sent. */
export interface HopStatus {
  /** Distinct peers handed a copy. */
  readonly relayed: number;
  /** Destination confirmed. */
  readonly delivered: boolean;
  /** Forward-path length the destination reported. */
  readonly forwardHops: number;
  /** Forward-path latency (ms) the destination reported. */
  readonly forwardMs: number;
}

/** An hops:// request delivered to this node acting as a service. */
export interface HopServiceRequest {
  readonly from: string;
  readonly requestId: Uint8Array;
  readonly service: string;
  readonly method: string;
  readonly args: Uint8Array;
}

/** An hops:// response delivered to this node acting as a caller. */
export interface HopServiceResponse {
  readonly from: string;
  readonly forRequestId: Uint8Array;
  readonly status: number;
  readonly body: Uint8Array;
}

/** An opaque outbound packet the core wants a bearer to transmit on `link`. */
export interface HopOutgoing {
  readonly link: number;
  readonly bytes: Uint8Array;
}

/** Which side opened a bearer link (the Noise role). */
export type HopRole = "dialer" | "acceptor";

/** Section 19 relay-pool counts: `total` endpoints known, `available` dialable right now.
 *
 *  A non-zero `total` with `available` at zero is the degraded "every candidate is backed off" state a
 *  UI should show as such rather than as offline; the pool still knows where to retry. */
export interface HopRelayPool {
  readonly total: number;
  readonly available: number;
}

/** Which mode an hps:// topic runs in (DESIGN.md section 32).
 *
 *  `channel` is group chat: every member holds the shared content key and writes, and each post is
 *  signed by the writer's own device identity. `service` is broadcast: subscribers hold the content key
 *  to read, and only the host can produce a post a subscriber will verify. */
export type HpsKind = "channel" | "service";

/** Who gets a topic's content key. `open` hands it out on a join request; `requestToJoin` queues the
 *  requester for the host's approval; `invite` is host to destination, and the destination accepts. */
export type HpsAccess = "open" | "requestToJoin" | "invite";

/** Whether a topic is advertised on the mesh. `discoverable` topics appear in `hpsBrowse` results for
 *  apps holding the same app secret; `private` ones are reachable only by host address and path. */
export type HpsVisibility = "private" | "discoverable";

/** One hps:// publication delivered to this node.
 *
 *  A Hop group message is not one-to-one fan-out and not a multicast bundle: it is a single
 *  content-key-encrypted, per-writer-signed publication, flooded once. Membership, invites and
 *  revocation are properties of the topic's key handoff, not of the delivery. */
export interface HopHpsMessage {
  /** Stable 32-byte id (use it with `acceptHpsMessage`). */
  readonly id: Uint8Array;
  /** The topic path this was published to. */
  readonly path: string;
  /** The writer's address, base58-encoded, taken from the message's own signature. */
  readonly sender: string;
  readonly body: Uint8Array;
}

/** An invite a host sent us for a topic it hosts (the `invite` access mode). */
export interface HopHpsInvite {
  /** The host's address, base58-encoded. */
  readonly host: string;
  readonly path: string;
  readonly kind: HpsKind;
}

/** A topic this node hosts or follows, as the node's own store records it. */
export interface HopHpsTopic {
  /** The host's address, base58-encoded (our own address for a topic we host). */
  readonly host: string;
  readonly path: string;
  readonly kind: HpsKind;
  /** True when this node is the host and holds the topic's keys. */
  readonly hosting: boolean;
  readonly access: HpsAccess;
}

/** A discoverable topic found on the mesh: the decrypted descriptor, not a subscription. */
export interface HopHpsTopicInfo {
  /** The host's address, base58-encoded. */
  readonly host: string;
  readonly path: string;
  readonly kind: HpsKind;
  readonly title: string;
  readonly summary: string;
  readonly access: HpsAccess;
}

/** Options for opening a persistent, on-device node. */
export interface HopOpenOptions {
  /** Absolute path to the SQLite store (SQLCipher when `key` is set). */
  dbPath: string;
  /** A previously exported 32-byte identity secret; omit for a fresh identity. */
  secret?: Uint8Array;
  /** The app-fabric secret; omit for the open fabric. */
  appSecret?: Uint8Array;
  /** A raw 32-byte key from the platform keystore; when set the store is encrypted at rest. */
  key?: Uint8Array;
}

/** Options for `send` / `sendTo`. */
export interface HopSendOptions {
  /** Destination address, base58-encoded. */
  to: string;
  /** MIME-ish content type; defaults to `text/plain`. */
  contentType?: string;
  /** Body bytes, or a UTF-8 string. */
  body: Uint8Array | string;
  /** Ask the destination to acknowledge delivery (populates `status`). */
  requestAck?: boolean;
}
