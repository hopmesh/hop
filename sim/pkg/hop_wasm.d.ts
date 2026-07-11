/* tslint:disable */
/* eslint-disable */

/**
 * A channel (hps://) post that arrived for this node, group messaging (§32).
 */
export class ChannelMsg {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    readonly body: Uint8Array;
    readonly path: string;
    /**
     * The POSTING member's address, every post is verified against its writer (§32).
     */
    readonly sender: Uint8Array;
}

/**
 * A message that arrived for this node and decrypted successfully.
 */
export class Delivered {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    readonly body: Uint8Array;
    /**
     * The delivered bundle's id, matches the ids from `drain_transfers`, so the sim can
     * solid-color exactly the path that arrived.
     */
    readonly bundle: Uint8Array;
    readonly content_type: string;
    readonly from: Uint8Array;
    /**
     * How many relay hops the bundle took to arrive (`env.hops` on the wire), the real count.
     */
    readonly hops: number;
}

/**
 * One frame's worth of bytes a node wants to ship to a peer, tagged with the link.
 */
export class OutPacket {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    readonly data: Uint8Array;
    readonly link: number;
}

/**
 * One real bundle crossing one link this frame, lets the visualizer color the hop by bundle.
 */
export class Transfer {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    readonly bundle: Uint8Array;
    /**
     * True when this hop delivered the bundle to its final destination.
     */
    readonly delivered: boolean;
    readonly link: number;
}

/**
 * A real Hop node, one per person on the map.
 */
export class WasmNode {
    free(): void;
    [Symbol.dispose](): void;
    /**
     * Post to a channel we're a member of, ONE message, every member receives it (real fan-out).
     * Returns the broadcast bundle's id so the sim can trace its flood.
     */
    channel_publish(path: string, body: Uint8Array): Uint8Array;
    /**
     * Join `host`'s channel at `path` (requests the content key over the mesh).
     */
    channel_subscribe(host: Uint8Array, path: string): void;
    /**
     * A bearer link came up. One side is the initiator; JS decides (e.g. lower id dials).
     */
    connected(link: number, initiator: boolean): void;
    /**
     * A bearer link dropped.
     */
    disconnected(link: number): void;
    /**
     * Pull the bytes this node wants to send out this frame (deliver each to its link's peer).
     */
    drain(): OutPacket[];
    /**
     * Did this node just emit a §39 recv-beacon? Lets the sim ripple a node as it advertises reachability.
     */
    drain_beaconed(): boolean;
    /**
     * Ids of our own sends confirmed delivered (by a returning ACK) since the last call, flat 32-byte
     * ids. The sender only learns delivery this way, a per-device UI shows "delivered" off this.
     */
    drain_delivered(): Uint8Array;
    /**
     * The `(link, bundle_id, is_final_delivery)` transfers this node made since the last call,
     * one per real bundle handed over a link. Color legs by `bundle`, solid when `delivered`.
     */
    drain_transfers(): Transfer[];
    /**
     * Which mailbox-tags this node currently holds a gradient toward, and the inbound link to forward
     * down for each, flat `[16-byte tag][u32 LE link][u8 hops]` records. Lets the sim draw the
     * distributed routing tree (each device holds a slice) + which way a private bundle would steer.
     */
    gradient(): Uint8Array;
    /**
     * Which bundles this node currently holds, as a flat concatenation of 32-byte ids (display ids,
     * so a deferred send's copies still match the id `send` returned). The sim intersects this with
     * the message bundles to draw only hops whose copy still exists.
     */
    held_ids(): Uint8Array;
    /**
     * Messages addressed to this node that arrived since the last call (decrypted).
     */
    inbox(): Delivered[];
    /**
     * Debug: take the inbox and report raw bundle count + per-bundle read result.
     */
    inbox_debug(): string;
    /**
     * Diagnostics: do we hold `addr`'s prekey (could we seal to them right now)?
     */
    knows_prekey(addr: Uint8Array): boolean;
    /**
     * This node's current §39 mailbox-tag (16 bytes), the key a relay's gradient points toward, so
     * the sim can find the routing tree steering a private bundle to this recipient.
     */
    mailbox_tag(): Uint8Array;
    /**
     * Build a node from a 32-byte identity seed (deterministic address across reloads) and a host
     * storage `bridge` (SQLite/OPFS in the Worker, a Map in Node tests), bundles live there, not
     * in wasm memory, so a many-node tab doesn't OOM while the core runs unchanged.
     */
    constructor(secret: Uint8Array, bridge: any);
    /**
     * Diagnostics: deferred sends still waiting on a prekey ("Securing…").
     */
    pending_count(): number;
    /**
     * Publish this node's prekey advert so peers can open forward-secret sessions to it.
     * Must be called (and gossiped over a link) before `send` can seal to this node.
     */
    publish_prekey(): void;
    /**
     * Publish a §39 receive beacon so relays lay a gradient toward this node's mailbox-tag, turning
     * blind flood into directed route-toward (§39 P4). Re-publish before the 90s soft-state TTL lapses.
     */
    publish_recv_beacon(): void;
    /**
     * Feed in bytes that arrived on a link from the peer.
     */
    receive(link: number, data: Uint8Array): void;
    /**
     * Host a group CHANNEL at `path` (hps://, §32): any member holding the content key reads and
     * writes; every post is verified against its writer's own address.
     */
    register_channel(path: string): void;
    /**
     * Send a real message to a 32-byte destination address (private/untraceable path, ACK requested).
     * Returns the created bundle's id so the sim can track just THIS message's flood (not gossip/ACKs).
     */
    send(dst: Uint8Array, body: Uint8Array): Uint8Array;
    /**
     * Send via the opt-in TRACED path (cleartext src/dst, directed routing), no prekey needed.
     */
    send_traced(dst: Uint8Array, body: Uint8Array): void;
    /**
     * Per-message send status, flat-encoded as repeated [32-byte id][u16 LE peers][u8 delivered].
     * Mirrors the debug app's Sending / Sent·N / Delivered.
     */
    sends_status(): Uint8Array;
    /**
     * Set the lifetime (ms) stamped on messages/ACKs this node sends, the sender's real per-bundle
     * TTL choice. The store prunes on it, so relay copies of delivered messages expire on schedule.
     */
    set_default_lifetime_ms(ms: number): void;
    /**
     * Turn on real-bundle-per-link observability so `drain_transfers` reports hops.
     */
    set_observe(on: boolean): void;
    /**
     * Channel posts that arrived since the last call (decrypted + writer-verified).
     */
    take_channel(): ChannelMsg[];
    /**
     * Advance the node's clock (ms). Expires adverts, retransmits, prunes routing state.
     */
    tick(now_ms: number): void;
    /**
     * This node's 32-byte public address, use it as a `dst` for `send`.
     */
    readonly address: Uint8Array;
}

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_wasmnode_free: (a: number, b: number) => void;
    readonly wasmnode_address: (a: number) => [number, number];
    readonly wasmnode_channel_publish: (a: number, b: number, c: number, d: number, e: number) => [number, number, number, number];
    readonly wasmnode_channel_subscribe: (a: number, b: number, c: number, d: number, e: number) => [number, number];
    readonly wasmnode_connected: (a: number, b: number, c: number) => void;
    readonly wasmnode_disconnected: (a: number, b: number) => void;
    readonly wasmnode_drain: (a: number) => [number, number];
    readonly wasmnode_drain_beaconed: (a: number) => number;
    readonly wasmnode_drain_delivered: (a: number) => [number, number];
    readonly wasmnode_drain_transfers: (a: number) => [number, number];
    readonly wasmnode_gradient: (a: number) => [number, number];
    readonly wasmnode_held_ids: (a: number) => [number, number];
    readonly wasmnode_inbox: (a: number) => [number, number];
    readonly wasmnode_inbox_debug: (a: number) => [number, number];
    readonly wasmnode_knows_prekey: (a: number, b: number, c: number) => number;
    readonly wasmnode_mailbox_tag: (a: number) => [number, number];
    readonly wasmnode_new: (a: number, b: number, c: any) => number;
    readonly wasmnode_pending_count: (a: number) => number;
    readonly wasmnode_publish_prekey: (a: number) => [number, number];
    readonly wasmnode_publish_recv_beacon: (a: number) => [number, number];
    readonly wasmnode_receive: (a: number, b: number, c: number, d: number) => void;
    readonly wasmnode_register_channel: (a: number, b: number, c: number) => void;
    readonly wasmnode_send: (a: number, b: number, c: number, d: number, e: number) => [number, number, number, number];
    readonly wasmnode_send_traced: (a: number, b: number, c: number, d: number, e: number) => [number, number];
    readonly wasmnode_sends_status: (a: number) => [number, number];
    readonly wasmnode_set_default_lifetime_ms: (a: number, b: number) => void;
    readonly wasmnode_set_observe: (a: number, b: number) => void;
    readonly wasmnode_take_channel: (a: number) => [number, number];
    readonly wasmnode_tick: (a: number, b: number) => void;
    readonly __wbg_channelmsg_free: (a: number, b: number) => void;
    readonly __wbg_delivered_free: (a: number, b: number) => void;
    readonly __wbg_outpacket_free: (a: number, b: number) => void;
    readonly __wbg_transfer_free: (a: number, b: number) => void;
    readonly channelmsg_body: (a: number) => [number, number];
    readonly channelmsg_path: (a: number) => [number, number];
    readonly channelmsg_sender: (a: number) => [number, number];
    readonly delivered_body: (a: number) => [number, number];
    readonly delivered_bundle: (a: number) => [number, number];
    readonly delivered_content_type: (a: number) => [number, number];
    readonly delivered_from: (a: number) => [number, number];
    readonly delivered_hops: (a: number) => number;
    readonly outpacket_data: (a: number) => [number, number];
    readonly outpacket_link: (a: number) => number;
    readonly transfer_bundle: (a: number) => [number, number];
    readonly transfer_delivered: (a: number) => number;
    readonly transfer_link: (a: number) => number;
    readonly __wbindgen_exn_store: (a: number) => void;
    readonly __externref_table_alloc: () => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __externref_drop_slice: (a: number, b: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
