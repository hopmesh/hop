/* @ts-self-types="./hop_wasm.d.ts" */

/**
 * A channel (hps://) post that arrived for this node, group messaging (§32).
 */
export class ChannelMsg {
    static __wrap(ptr) {
        const obj = Object.create(ChannelMsg.prototype);
        obj.__wbg_ptr = ptr;
        ChannelMsgFinalization.register(obj, obj.__wbg_ptr, obj);
        return obj;
    }
    __destroy_into_raw() {
        const ptr = this.__wbg_ptr;
        this.__wbg_ptr = 0;
        ChannelMsgFinalization.unregister(this);
        return ptr;
    }
    free() {
        const ptr = this.__destroy_into_raw();
        wasm.__wbg_channelmsg_free(ptr, 0);
    }
    /**
     * @returns {Uint8Array}
     */
    get body() {
        const ret = wasm.channelmsg_body(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * @returns {string}
     */
    get path() {
        let deferred1_0;
        let deferred1_1;
        try {
            const ret = wasm.channelmsg_path(this.__wbg_ptr);
            deferred1_0 = ret[0];
            deferred1_1 = ret[1];
            return getStringFromWasm0(ret[0], ret[1]);
        } finally {
            wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
        }
    }
    /**
     * The POSTING member's address, every post is verified against its writer (§32).
     * @returns {Uint8Array}
     */
    get sender() {
        const ret = wasm.channelmsg_sender(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
}
if (Symbol.dispose) ChannelMsg.prototype[Symbol.dispose] = ChannelMsg.prototype.free;

/**
 * A message that arrived for this node and decrypted successfully.
 */
export class Delivered {
    static __wrap(ptr) {
        const obj = Object.create(Delivered.prototype);
        obj.__wbg_ptr = ptr;
        DeliveredFinalization.register(obj, obj.__wbg_ptr, obj);
        return obj;
    }
    __destroy_into_raw() {
        const ptr = this.__wbg_ptr;
        this.__wbg_ptr = 0;
        DeliveredFinalization.unregister(this);
        return ptr;
    }
    free() {
        const ptr = this.__destroy_into_raw();
        wasm.__wbg_delivered_free(ptr, 0);
    }
    /**
     * @returns {Uint8Array}
     */
    get body() {
        const ret = wasm.delivered_body(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * The delivered bundle's id, matches the ids from `drain_transfers`, so the sim can
     * solid-color exactly the path that arrived.
     * @returns {Uint8Array}
     */
    get bundle() {
        const ret = wasm.delivered_bundle(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * @returns {string}
     */
    get content_type() {
        let deferred1_0;
        let deferred1_1;
        try {
            const ret = wasm.delivered_content_type(this.__wbg_ptr);
            deferred1_0 = ret[0];
            deferred1_1 = ret[1];
            return getStringFromWasm0(ret[0], ret[1]);
        } finally {
            wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
        }
    }
    /**
     * @returns {Uint8Array}
     */
    get from() {
        const ret = wasm.delivered_from(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * How many relay hops the bundle took to arrive (`env.hops` on the wire), the real count.
     * @returns {number}
     */
    get hops() {
        const ret = wasm.delivered_hops(this.__wbg_ptr);
        return ret;
    }
}
if (Symbol.dispose) Delivered.prototype[Symbol.dispose] = Delivered.prototype.free;

/**
 * One frame's worth of bytes a node wants to ship to a peer, tagged with the link.
 */
export class OutPacket {
    static __wrap(ptr) {
        const obj = Object.create(OutPacket.prototype);
        obj.__wbg_ptr = ptr;
        OutPacketFinalization.register(obj, obj.__wbg_ptr, obj);
        return obj;
    }
    __destroy_into_raw() {
        const ptr = this.__wbg_ptr;
        this.__wbg_ptr = 0;
        OutPacketFinalization.unregister(this);
        return ptr;
    }
    free() {
        const ptr = this.__destroy_into_raw();
        wasm.__wbg_outpacket_free(ptr, 0);
    }
    /**
     * @returns {Uint8Array}
     */
    get data() {
        const ret = wasm.outpacket_data(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * @returns {number}
     */
    get link() {
        const ret = wasm.outpacket_link(this.__wbg_ptr);
        return ret >>> 0;
    }
}
if (Symbol.dispose) OutPacket.prototype[Symbol.dispose] = OutPacket.prototype.free;

/**
 * One real bundle crossing one link this frame, lets the visualizer color the hop by bundle.
 */
export class Transfer {
    static __wrap(ptr) {
        const obj = Object.create(Transfer.prototype);
        obj.__wbg_ptr = ptr;
        TransferFinalization.register(obj, obj.__wbg_ptr, obj);
        return obj;
    }
    __destroy_into_raw() {
        const ptr = this.__wbg_ptr;
        this.__wbg_ptr = 0;
        TransferFinalization.unregister(this);
        return ptr;
    }
    free() {
        const ptr = this.__destroy_into_raw();
        wasm.__wbg_transfer_free(ptr, 0);
    }
    /**
     * @returns {Uint8Array}
     */
    get bundle() {
        const ret = wasm.transfer_bundle(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * True when this hop delivered the bundle to its final destination.
     * @returns {boolean}
     */
    get delivered() {
        const ret = wasm.transfer_delivered(this.__wbg_ptr);
        return ret !== 0;
    }
    /**
     * @returns {number}
     */
    get link() {
        const ret = wasm.transfer_link(this.__wbg_ptr);
        return ret >>> 0;
    }
}
if (Symbol.dispose) Transfer.prototype[Symbol.dispose] = Transfer.prototype.free;

/**
 * A real Hop node, one per person on the map.
 */
export class WasmNode {
    __destroy_into_raw() {
        const ptr = this.__wbg_ptr;
        this.__wbg_ptr = 0;
        WasmNodeFinalization.unregister(this);
        return ptr;
    }
    free() {
        const ptr = this.__destroy_into_raw();
        wasm.__wbg_wasmnode_free(ptr, 0);
    }
    /**
     * This node's 32-byte public address, use it as a `dst` for `send`.
     * @returns {Uint8Array}
     */
    get address() {
        const ret = wasm.wasmnode_address(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * Post to a channel we're a member of, ONE message, every member receives it (real fan-out).
     * Returns the broadcast bundle's id so the sim can trace its flood.
     * @param {string} path
     * @param {Uint8Array} body
     * @returns {Uint8Array}
     */
    channel_publish(path, body) {
        const ptr0 = passStringToWasm0(path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArray8ToWasm0(body, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ret = wasm.wasmnode_channel_publish(this.__wbg_ptr, ptr0, len0, ptr1, len1);
        if (ret[3]) {
            throw takeFromExternrefTable0(ret[2]);
        }
        var v3 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v3;
    }
    /**
     * Join `host`'s channel at `path` (requests the content key over the mesh).
     * @param {Uint8Array} host
     * @param {string} path
     */
    channel_subscribe(host, path) {
        const ptr0 = passArray8ToWasm0(host, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passStringToWasm0(path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len1 = WASM_VECTOR_LEN;
        const ret = wasm.wasmnode_channel_subscribe(this.__wbg_ptr, ptr0, len0, ptr1, len1);
        if (ret[1]) {
            throw takeFromExternrefTable0(ret[0]);
        }
    }
    /**
     * A bearer link came up. One side is the initiator; JS decides (e.g. lower id dials).
     * @param {number} link
     * @param {boolean} initiator
     */
    connected(link, initiator) {
        wasm.wasmnode_connected(this.__wbg_ptr, link, initiator);
    }
    /**
     * A bearer link dropped.
     * @param {number} link
     */
    disconnected(link) {
        wasm.wasmnode_disconnected(this.__wbg_ptr, link);
    }
    /**
     * Pull the bytes this node wants to send out this frame (deliver each to its link's peer).
     * @returns {OutPacket[]}
     */
    drain() {
        const ret = wasm.wasmnode_drain(this.__wbg_ptr);
        var v1 = getArrayJsValueFromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Did this node just emit a §39 recv-beacon? Lets the sim ripple a node as it advertises reachability.
     * @returns {boolean}
     */
    drain_beaconed() {
        const ret = wasm.wasmnode_drain_beaconed(this.__wbg_ptr);
        return ret !== 0;
    }
    /**
     * Ids of our own sends confirmed delivered (by a returning ACK) since the last call, flat 32-byte
     * ids. The sender only learns delivery this way, a per-device UI shows "delivered" off this.
     * @returns {Uint8Array}
     */
    drain_delivered() {
        const ret = wasm.wasmnode_drain_delivered(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * The `(link, bundle_id, is_final_delivery)` transfers this node made since the last call,
     * one per real bundle handed over a link. Color legs by `bundle`, solid when `delivered`.
     * @returns {Transfer[]}
     */
    drain_transfers() {
        const ret = wasm.wasmnode_drain_transfers(this.__wbg_ptr);
        var v1 = getArrayJsValueFromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Which mailbox-tags this node currently holds a gradient toward, and the inbound link to forward
     * down for each, flat `[16-byte tag][u32 LE link][u8 hops]` records. Lets the sim draw the
     * distributed routing tree (each device holds a slice) + which way a private bundle would steer.
     * @returns {Uint8Array}
     */
    gradient() {
        const ret = wasm.wasmnode_gradient(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * Which bundles this node currently holds, as a flat concatenation of 32-byte ids (display ids,
     * so a deferred send's copies still match the id `send` returned). The sim intersects this with
     * the message bundles to draw only hops whose copy still exists.
     * @returns {Uint8Array}
     */
    held_ids() {
        const ret = wasm.wasmnode_held_ids(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * Messages addressed to this node that arrived since the last call (decrypted).
     * @returns {Delivered[]}
     */
    inbox() {
        const ret = wasm.wasmnode_inbox(this.__wbg_ptr);
        var v1 = getArrayJsValueFromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Debug: take the inbox and report raw bundle count + per-bundle read result.
     * @returns {string}
     */
    inbox_debug() {
        let deferred1_0;
        let deferred1_1;
        try {
            const ret = wasm.wasmnode_inbox_debug(this.__wbg_ptr);
            deferred1_0 = ret[0];
            deferred1_1 = ret[1];
            return getStringFromWasm0(ret[0], ret[1]);
        } finally {
            wasm.__wbindgen_free(deferred1_0, deferred1_1, 1);
        }
    }
    /**
     * Diagnostics: do we hold `addr`'s prekey (could we seal to them right now)?
     * @param {Uint8Array} addr
     * @returns {boolean}
     */
    knows_prekey(addr) {
        const ptr0 = passArray8ToWasm0(addr, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.wasmnode_knows_prekey(this.__wbg_ptr, ptr0, len0);
        return ret !== 0;
    }
    /**
     * This node's current §39 mailbox-tag (16 bytes), the key a relay's gradient points toward, so
     * the sim can find the routing tree steering a private bundle to this recipient.
     * @returns {Uint8Array}
     */
    mailbox_tag() {
        const ret = wasm.wasmnode_mailbox_tag(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * Build a node from a 32-byte identity seed (deterministic address across reloads) and a host
     * storage `bridge` (SQLite/OPFS in the Worker, a Map in Node tests), bundles live there, not
     * in wasm memory, so a many-node tab doesn't OOM while the core runs unchanged.
     * @param {Uint8Array} secret
     * @param {any} bridge
     */
    constructor(secret, bridge) {
        const ptr0 = passArray8ToWasm0(secret, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ret = wasm.wasmnode_new(ptr0, len0, bridge);
        this.__wbg_ptr = ret;
        WasmNodeFinalization.register(this, this.__wbg_ptr, this);
        return this;
    }
    /**
     * Diagnostics: deferred sends still waiting on a prekey ("Securing…").
     * @returns {number}
     */
    pending_count() {
        const ret = wasm.wasmnode_pending_count(this.__wbg_ptr);
        return ret >>> 0;
    }
    /**
     * Publish this node's prekey advert so peers can open forward-secret sessions to it.
     * Must be called (and gossiped over a link) before `send` can seal to this node.
     */
    publish_prekey() {
        const ret = wasm.wasmnode_publish_prekey(this.__wbg_ptr);
        if (ret[1]) {
            throw takeFromExternrefTable0(ret[0]);
        }
    }
    /**
     * Publish a §39 receive beacon so relays lay a gradient toward this node's mailbox-tag, turning
     * blind flood into directed route-toward (§39 P4). Re-publish before the 90s soft-state TTL lapses.
     */
    publish_recv_beacon() {
        const ret = wasm.wasmnode_publish_recv_beacon(this.__wbg_ptr);
        if (ret[1]) {
            throw takeFromExternrefTable0(ret[0]);
        }
    }
    /**
     * Feed in bytes that arrived on a link from the peer.
     * @param {number} link
     * @param {Uint8Array} data
     */
    receive(link, data) {
        const ptr0 = passArray8ToWasm0(data, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wasmnode_receive(this.__wbg_ptr, link, ptr0, len0);
    }
    /**
     * Host a group CHANNEL at `path` (hps://, §32): any member holding the content key reads and
     * writes; every post is verified against its writer's own address.
     * @param {string} path
     */
    register_channel(path) {
        const ptr0 = passStringToWasm0(path, wasm.__wbindgen_malloc, wasm.__wbindgen_realloc);
        const len0 = WASM_VECTOR_LEN;
        wasm.wasmnode_register_channel(this.__wbg_ptr, ptr0, len0);
    }
    /**
     * Send a real message to a 32-byte destination address (private/untraceable path, ACK requested).
     * Returns the created bundle's id so the sim can track just THIS message's flood (not gossip/ACKs).
     * @param {Uint8Array} dst
     * @param {Uint8Array} body
     * @returns {Uint8Array}
     */
    send(dst, body) {
        const ptr0 = passArray8ToWasm0(dst, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArray8ToWasm0(body, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ret = wasm.wasmnode_send(this.__wbg_ptr, ptr0, len0, ptr1, len1);
        if (ret[3]) {
            throw takeFromExternrefTable0(ret[2]);
        }
        var v3 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v3;
    }
    /**
     * Send via the opt-in TRACED path (cleartext src/dst, directed routing), no prekey needed.
     * @param {Uint8Array} dst
     * @param {Uint8Array} body
     */
    send_traced(dst, body) {
        const ptr0 = passArray8ToWasm0(dst, wasm.__wbindgen_malloc);
        const len0 = WASM_VECTOR_LEN;
        const ptr1 = passArray8ToWasm0(body, wasm.__wbindgen_malloc);
        const len1 = WASM_VECTOR_LEN;
        const ret = wasm.wasmnode_send_traced(this.__wbg_ptr, ptr0, len0, ptr1, len1);
        if (ret[1]) {
            throw takeFromExternrefTable0(ret[0]);
        }
    }
    /**
     * Per-message send status, flat-encoded as repeated [32-byte id][u16 LE peers][u8 delivered].
     * Mirrors the debug app's Sending / Sent·N / Delivered.
     * @returns {Uint8Array}
     */
    sends_status() {
        const ret = wasm.wasmnode_sends_status(this.__wbg_ptr);
        var v1 = getArrayU8FromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 1, 1);
        return v1;
    }
    /**
     * Set the lifetime (ms) stamped on messages/ACKs this node sends, the sender's real per-bundle
     * TTL choice. The store prunes on it, so relay copies of delivered messages expire on schedule.
     * @param {number} ms
     */
    set_default_lifetime_ms(ms) {
        wasm.wasmnode_set_default_lifetime_ms(this.__wbg_ptr, ms);
    }
    /**
     * Turn on real-bundle-per-link observability so `drain_transfers` reports hops.
     * @param {boolean} on
     */
    set_observe(on) {
        wasm.wasmnode_set_observe(this.__wbg_ptr, on);
    }
    /**
     * Channel posts that arrived since the last call (decrypted + writer-verified).
     * @returns {ChannelMsg[]}
     */
    take_channel() {
        const ret = wasm.wasmnode_take_channel(this.__wbg_ptr);
        var v1 = getArrayJsValueFromWasm0(ret[0], ret[1]).slice();
        wasm.__wbindgen_free(ret[0], ret[1] * 4, 4);
        return v1;
    }
    /**
     * Advance the node's clock (ms). Expires adverts, retransmits, prunes routing state.
     * @param {number} now_ms
     */
    tick(now_ms) {
        wasm.wasmnode_tick(this.__wbg_ptr, now_ms);
    }
}
if (Symbol.dispose) WasmNode.prototype[Symbol.dispose] = WasmNode.prototype.free;
function __wbg_get_imports() {
    const import0 = {
        __proto__: null,
        __wbg___wbindgen_is_function_acc5528be2b923f2: function(arg0) {
            const ret = typeof(arg0) === 'function';
            return ret;
        },
        __wbg___wbindgen_is_object_0beba4a1980d3eea: function(arg0) {
            const val = arg0;
            const ret = typeof(val) === 'object' && val !== null;
            return ret;
        },
        __wbg___wbindgen_is_string_1fca8072260dd261: function(arg0) {
            const ret = typeof(arg0) === 'string';
            return ret;
        },
        __wbg___wbindgen_is_undefined_721f8decd50c87a3: function(arg0) {
            const ret = arg0 === undefined;
            return ret;
        },
        __wbg___wbindgen_throw_ea4887a5f8f9a9db: function(arg0, arg1) {
            throw new Error(getStringFromWasm0(arg0, arg1));
        },
        __wbg_call_5575218572ead796: function() { return handleError(function (arg0, arg1, arg2) {
            const ret = arg0.call(arg1, arg2);
            return ret;
        }, arguments); },
        __wbg_channelmsg_new: function(arg0) {
            const ret = ChannelMsg.__wrap(arg0);
            return ret;
        },
        __wbg_contains_cf4fbf9c138e80c4: function(arg0, arg1, arg2) {
            const ret = arg0.contains(getArrayU8FromWasm0(arg1, arg2));
            return ret;
        },
        __wbg_crypto_38df2bab126b63dc: function(arg0) {
            const ret = arg0.crypto;
            return ret;
        },
        __wbg_delivered_new: function(arg0) {
            const ret = Delivered.__wrap(arg0);
            return ret;
        },
        __wbg_getRandomValues_3f44b700395062e5: function() { return handleError(function (arg0, arg1) {
            globalThis.crypto.getRandomValues(getArrayU8FromWasm0(arg0, arg1));
        }, arguments); },
        __wbg_getRandomValues_c44a50d8cfdaebeb: function() { return handleError(function (arg0, arg1) {
            arg0.getRandomValues(arg1);
        }, arguments); },
        __wbg_getRandomValues_cc7f052a444bb2ce: function() { return handleError(function (arg0, arg1) {
            globalThis.crypto.getRandomValues(getArrayU8FromWasm0(arg0, arg1));
        }, arguments); },
        __wbg_get_ba4089894282e649: function(arg0, arg1, arg2, arg3) {
            const ret = arg1.get(getArrayU8FromWasm0(arg2, arg3));
            var ptr1 = isLikeNone(ret) ? 0 : passArray8ToWasm0(ret, wasm.__wbindgen_malloc);
            var len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        },
        __wbg_have_0dba6682e138d355: function(arg0, arg1) {
            const ret = arg1.have();
            const ptr1 = passArray8ToWasm0(ret, wasm.__wbindgen_malloc);
            const len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        },
        __wbg_kvGet_6f03bbf8eef1b6ef: function(arg0, arg1, arg2, arg3) {
            const ret = arg1.kvGet(getStringFromWasm0(arg2, arg3));
            var ptr1 = isLikeNone(ret) ? 0 : passArray8ToWasm0(ret, wasm.__wbindgen_malloc);
            var len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        },
        __wbg_kvList_f2ae384d8b7d0bbe: function(arg0, arg1, arg2, arg3) {
            const ret = arg1.kvList(getStringFromWasm0(arg2, arg3));
            const ptr1 = passArray8ToWasm0(ret, wasm.__wbindgen_malloc);
            const len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        },
        __wbg_kvPut_3e0d517d69083817: function(arg0, arg1, arg2, arg3, arg4) {
            arg0.kvPut(getStringFromWasm0(arg1, arg2), getArrayU8FromWasm0(arg3, arg4));
        },
        __wbg_kvRemove_91cafbbe021efe30: function(arg0, arg1, arg2) {
            arg0.kvRemove(getStringFromWasm0(arg1, arg2));
        },
        __wbg_length_589238bdcf171f0e: function(arg0) {
            const ret = arg0.length;
            return ret;
        },
        __wbg_msCrypto_bd5a034af96bcba6: function(arg0) {
            const ret = arg0.msCrypto;
            return ret;
        },
        __wbg_new_with_length_9b650f44b5c44a4e: function(arg0) {
            const ret = new Uint8Array(arg0 >>> 0);
            return ret;
        },
        __wbg_node_84ea875411254db1: function(arg0) {
            const ret = arg0.node;
            return ret;
        },
        __wbg_outpacket_new: function(arg0) {
            const ret = OutPacket.__wrap(arg0);
            return ret;
        },
        __wbg_process_44c7a14e11e9f69e: function(arg0) {
            const ret = arg0.process;
            return ret;
        },
        __wbg_prototypesetcall_d721637c7ca66eb8: function(arg0, arg1, arg2) {
            Uint8Array.prototype.set.call(getArrayU8FromWasm0(arg0, arg1), arg2);
        },
        __wbg_prune_77625ac6c7b93d9b: function(arg0, arg1) {
            arg0.prune(arg1);
        },
        __wbg_put_05686f2ea9dd4c36: function(arg0, arg1, arg2, arg3, arg4, arg5) {
            const ret = arg0.put(getArrayU8FromWasm0(arg1, arg2), getArrayU8FromWasm0(arg3, arg4), arg5);
            return ret;
        },
        __wbg_randomFillSync_6c25eac9869eb53c: function() { return handleError(function (arg0, arg1) {
            arg0.randomFillSync(arg1);
        }, arguments); },
        __wbg_remove_4b86b5b8b252f46b: function(arg0, arg1, arg2, arg3) {
            const ret = arg1.remove(getArrayU8FromWasm0(arg2, arg3));
            var ptr1 = isLikeNone(ret) ? 0 : passArray8ToWasm0(ret, wasm.__wbindgen_malloc);
            var len1 = WASM_VECTOR_LEN;
            getDataViewMemory0().setInt32(arg0 + 4 * 1, len1, true);
            getDataViewMemory0().setInt32(arg0 + 4 * 0, ptr1, true);
        },
        __wbg_require_b4edbdcf3e2a1ef0: function() { return handleError(function () {
            const ret = module.require;
            return ret;
        }, arguments); },
        __wbg_seen_096a410ffe1dec16: function(arg0, arg1, arg2) {
            const ret = arg0.seen(getArrayU8FromWasm0(arg1, arg2));
            return ret;
        },
        __wbg_setData_27d07a06437501d2: function(arg0, arg1, arg2, arg3, arg4) {
            arg0.setData(getArrayU8FromWasm0(arg1, arg2), getArrayU8FromWasm0(arg3, arg4));
        },
        __wbg_static_accessor_GLOBAL_THIS_2fee5048bcca5938: function() {
            const ret = typeof globalThis === 'undefined' ? null : globalThis;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_static_accessor_GLOBAL_ce44e66a4935da8c: function() {
            const ret = typeof global === 'undefined' ? null : global;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_static_accessor_SELF_44f6e0cb5e67cdad: function() {
            const ret = typeof self === 'undefined' ? null : self;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_static_accessor_WINDOW_168f178805d978fe: function() {
            const ret = typeof window === 'undefined' ? null : window;
            return isLikeNone(ret) ? 0 : addToExternrefTable0(ret);
        },
        __wbg_subarray_b0e8ac4ed313fea8: function(arg0, arg1, arg2) {
            const ret = arg0.subarray(arg1 >>> 0, arg2 >>> 0);
            return ret;
        },
        __wbg_transfer_new: function(arg0) {
            const ret = Transfer.__wrap(arg0);
            return ret;
        },
        __wbg_versions_276b2795b1c6a219: function(arg0) {
            const ret = arg0.versions;
            return ret;
        },
        __wbindgen_cast_0000000000000001: function(arg0, arg1) {
            // Cast intrinsic for `Ref(Slice(U8)) -> NamedExternref("Uint8Array")`.
            const ret = getArrayU8FromWasm0(arg0, arg1);
            return ret;
        },
        __wbindgen_cast_0000000000000002: function(arg0, arg1) {
            // Cast intrinsic for `Ref(String) -> Externref`.
            const ret = getStringFromWasm0(arg0, arg1);
            return ret;
        },
        __wbindgen_init_externref_table: function() {
            const table = wasm.__wbindgen_externrefs;
            const offset = table.grow(4);
            table.set(0, undefined);
            table.set(offset + 0, undefined);
            table.set(offset + 1, null);
            table.set(offset + 2, true);
            table.set(offset + 3, false);
        },
    };
    return {
        __proto__: null,
        "./hop_wasm_bg.js": import0,
    };
}

const ChannelMsgFinalization = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(ptr => wasm.__wbg_channelmsg_free(ptr, 1));
const DeliveredFinalization = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(ptr => wasm.__wbg_delivered_free(ptr, 1));
const OutPacketFinalization = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(ptr => wasm.__wbg_outpacket_free(ptr, 1));
const TransferFinalization = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(ptr => wasm.__wbg_transfer_free(ptr, 1));
const WasmNodeFinalization = (typeof FinalizationRegistry === 'undefined')
    ? { register: () => {}, unregister: () => {} }
    : new FinalizationRegistry(ptr => wasm.__wbg_wasmnode_free(ptr, 1));

function addToExternrefTable0(obj) {
    const idx = wasm.__externref_table_alloc();
    wasm.__wbindgen_externrefs.set(idx, obj);
    return idx;
}

function getArrayJsValueFromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    const mem = getDataViewMemory0();
    const result = [];
    for (let i = ptr; i < ptr + 4 * len; i += 4) {
        result.push(wasm.__wbindgen_externrefs.get(mem.getUint32(i, true)));
    }
    wasm.__externref_drop_slice(ptr, len);
    return result;
}

function getArrayU8FromWasm0(ptr, len) {
    ptr = ptr >>> 0;
    return getUint8ArrayMemory0().subarray(ptr / 1, ptr / 1 + len);
}

let cachedDataViewMemory0 = null;
function getDataViewMemory0() {
    if (cachedDataViewMemory0 === null || cachedDataViewMemory0.buffer.detached === true || (cachedDataViewMemory0.buffer.detached === undefined && cachedDataViewMemory0.buffer !== wasm.memory.buffer)) {
        cachedDataViewMemory0 = new DataView(wasm.memory.buffer);
    }
    return cachedDataViewMemory0;
}

function getStringFromWasm0(ptr, len) {
    return decodeText(ptr >>> 0, len);
}

let cachedUint8ArrayMemory0 = null;
function getUint8ArrayMemory0() {
    if (cachedUint8ArrayMemory0 === null || cachedUint8ArrayMemory0.byteLength === 0) {
        cachedUint8ArrayMemory0 = new Uint8Array(wasm.memory.buffer);
    }
    return cachedUint8ArrayMemory0;
}

function handleError(f, args) {
    try {
        return f.apply(this, args);
    } catch (e) {
        const idx = addToExternrefTable0(e);
        wasm.__wbindgen_exn_store(idx);
    }
}

function isLikeNone(x) {
    return x === undefined || x === null;
}

function passArray8ToWasm0(arg, malloc) {
    const ptr = malloc(arg.length * 1, 1) >>> 0;
    getUint8ArrayMemory0().set(arg, ptr / 1);
    WASM_VECTOR_LEN = arg.length;
    return ptr;
}

function passStringToWasm0(arg, malloc, realloc) {
    if (realloc === undefined) {
        const buf = cachedTextEncoder.encode(arg);
        const ptr = malloc(buf.length, 1) >>> 0;
        getUint8ArrayMemory0().subarray(ptr, ptr + buf.length).set(buf);
        WASM_VECTOR_LEN = buf.length;
        return ptr;
    }

    let len = arg.length;
    let ptr = malloc(len, 1) >>> 0;

    const mem = getUint8ArrayMemory0();

    let offset = 0;

    for (; offset < len; offset++) {
        const code = arg.charCodeAt(offset);
        if (code > 0x7F) break;
        mem[ptr + offset] = code;
    }
    if (offset !== len) {
        if (offset !== 0) {
            arg = arg.slice(offset);
        }
        ptr = realloc(ptr, len, len = offset + arg.length * 3, 1) >>> 0;
        const view = getUint8ArrayMemory0().subarray(ptr + offset, ptr + len);
        const ret = cachedTextEncoder.encodeInto(arg, view);

        offset += ret.written;
        ptr = realloc(ptr, len, offset, 1) >>> 0;
    }

    WASM_VECTOR_LEN = offset;
    return ptr;
}

function takeFromExternrefTable0(idx) {
    const value = wasm.__wbindgen_externrefs.get(idx);
    wasm.__externref_table_dealloc(idx);
    return value;
}

let cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
cachedTextDecoder.decode();
const MAX_SAFARI_DECODE_BYTES = 2146435072;
let numBytesDecoded = 0;
function decodeText(ptr, len) {
    numBytesDecoded += len;
    if (numBytesDecoded >= MAX_SAFARI_DECODE_BYTES) {
        cachedTextDecoder = new TextDecoder('utf-8', { ignoreBOM: true, fatal: true });
        cachedTextDecoder.decode();
        numBytesDecoded = len;
    }
    return cachedTextDecoder.decode(getUint8ArrayMemory0().subarray(ptr, ptr + len));
}

const cachedTextEncoder = new TextEncoder();

if (!('encodeInto' in cachedTextEncoder)) {
    cachedTextEncoder.encodeInto = function (arg, view) {
        const buf = cachedTextEncoder.encode(arg);
        view.set(buf);
        return {
            read: arg.length,
            written: buf.length
        };
    };
}

let WASM_VECTOR_LEN = 0;

let wasmModule, wasmInstance, wasm;
function __wbg_finalize_init(instance, module) {
    wasmInstance = instance;
    wasm = instance.exports;
    wasmModule = module;
    cachedDataViewMemory0 = null;
    cachedUint8ArrayMemory0 = null;
    wasm.__wbindgen_start();
    return wasm;
}

async function __wbg_load(module, imports) {
    if (typeof Response === 'function' && module instanceof Response) {
        if (typeof WebAssembly.instantiateStreaming === 'function') {
            try {
                return await WebAssembly.instantiateStreaming(module, imports);
            } catch (e) {
                const validResponse = module.ok && expectedResponseType(module.type);

                if (validResponse && module.headers.get('Content-Type') !== 'application/wasm') {
                    console.warn("`WebAssembly.instantiateStreaming` failed because your server does not serve Wasm with `application/wasm` MIME type. Falling back to `WebAssembly.instantiate` which is slower. Original error:\n", e);

                } else { throw e; }
            }
        }

        const bytes = await module.arrayBuffer();
        return await WebAssembly.instantiate(bytes, imports);
    } else {
        const instance = await WebAssembly.instantiate(module, imports);

        if (instance instanceof WebAssembly.Instance) {
            return { instance, module };
        } else {
            return instance;
        }
    }

    function expectedResponseType(type) {
        switch (type) {
            case 'basic': case 'cors': case 'default': return true;
        }
        return false;
    }
}

function initSync(module) {
    if (wasm !== undefined) return wasm;


    if (module !== undefined) {
        if (Object.getPrototypeOf(module) === Object.prototype) {
            ({module} = module)
        } else {
            console.warn('using deprecated parameters for `initSync()`; pass a single object instead')
        }
    }

    const imports = __wbg_get_imports();
    if (!(module instanceof WebAssembly.Module)) {
        module = new WebAssembly.Module(module);
    }
    const instance = new WebAssembly.Instance(module, imports);
    return __wbg_finalize_init(instance, module);
}

async function __wbg_init(module_or_path) {
    if (wasm !== undefined) return wasm;


    if (module_or_path !== undefined) {
        if (Object.getPrototypeOf(module_or_path) === Object.prototype) {
            ({module_or_path} = module_or_path)
        } else {
            console.warn('using deprecated parameters for the initialization function; pass a single object instead')
        }
    }

    if (module_or_path === undefined) {
        module_or_path = new URL('hop_wasm_bg.wasm', import.meta.url);
    }
    const imports = __wbg_get_imports();

    if (typeof module_or_path === 'string' || (typeof Request === 'function' && module_or_path instanceof Request) || (typeof URL === 'function' && module_or_path instanceof URL)) {
        module_or_path = fetch(module_or_path);
    }

    const { instance, module } = await __wbg_load(await module_or_path, imports);

    return __wbg_finalize_init(instance, module);
}

export { initSync, __wbg_init as default };
