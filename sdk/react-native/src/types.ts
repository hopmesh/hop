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
