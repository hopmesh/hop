//! libhop — the stable C ABI for hop-core: the universal client SDK.
//!
//! This is the ONE contract every non-Rust client binds: mobile bearer libs (Swift/Kotlin via the
//! generated `hop.h`), C/C++ tools, and embedded FULL clients — e.g. an ESP32 that opens a node,
//! secures sessions, and pushes sensor data to a `hops://` service. cbindgen generates
//! `include/hop.h` from this module (see `cbindgen.toml`).
//!
//! It is the poll-model byte seam — link up / bytes in / link down / drain out, keyed by `LinkId`
//! (u64) + `HopLinkRole` — PLUS the full client surface (open, identity, subscribe, send). Nothing
//! transport-specific crosses it: no BLE, no beacon, no service id — pure bytes + ids. The optional
//! UniFFI layer (the rest of this crate) wraps the SAME `HopNode`, so mobile gets ergonomic bindings
//! while every other target binds this C ABI.

#![allow(clippy::missing_safety_doc)]

use std::ffi::{c_void, CStr};
use std::os::raw::c_char;
use std::sync::Arc;

use crate::HopNode;

/// Which side opened a bearer link (the Noise role). Mirrors hop-core's internal `Role`.
#[repr(C)]
pub enum HopLinkRole {
    /// We dialed out (BLE central / TCP connect / Wi-Fi inviter) → Noise initiator.
    Dialer = 0,
    /// A peer connected in (peripheral / listener / invitee) → Noise responder.
    Acceptor = 1,
}

// ---- internal helpers (not exported) ----------------------------------------------------------

unsafe fn node_ref<'a>(node: *const HopNode) -> Option<&'a HopNode> {
    if node.is_null() {
        None
    } else {
        Some(&*node)
    }
}
unsafe fn cstr<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok()
}
unsafe fn slice<'a>(p: *const u8, len: usize) -> &'a [u8] {
    if p.is_null() || len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(p, len)
    }
}

// ---- lifecycle --------------------------------------------------------------------------------

/// Open a node with persistent storage at `db_path` (UTF-8 C string), a saved 32-byte identity
/// `secret` (pass NULL/0 for a fresh identity), and a 32-byte `app_secret` (NULL/0 = open fabric).
/// Returns an owning handle to free with `hop_node_free`, or NULL on a NULL/invalid `db_path`.
#[no_mangle]
pub unsafe extern "C" fn hop_node_open(
    db_path: *const c_char,
    secret: *const u8,
    secret_len: usize,
    app_secret: *const u8,
    app_secret_len: usize,
) -> *const HopNode {
    let Some(path) = cstr(db_path) else {
        return std::ptr::null();
    };
    let node = HopNode::open(
        path.to_string(),
        slice(secret, secret_len).to_vec(),
        slice(app_secret, app_secret_len).to_vec(),
    );
    Arc::into_raw(node)
}

/// Create a node with a fresh identity and ephemeral (in-memory) storage. Free with `hop_node_free`.
#[no_mangle]
pub unsafe extern "C" fn hop_node_new() -> *const HopNode {
    Arc::into_raw(HopNode::new())
}

/// Free a node handle returned by any constructor. Safe to pass NULL.
#[no_mangle]
pub unsafe extern "C" fn hop_node_free(node: *const HopNode) {
    if !node.is_null() {
        drop(Arc::from_raw(node));
    }
}

// ---- identity ---------------------------------------------------------------------------------

/// Write this node's 32-byte address into `out` (must have room for 32 bytes). False on NULL.
#[no_mangle]
pub unsafe extern "C" fn hop_node_address(node: *const HopNode, out: *mut u8) -> bool {
    let (Some(node), false) = (node_ref(node), out.is_null()) else {
        return false;
    };
    let addr = node.address();
    std::ptr::copy_nonoverlapping(addr.as_ptr(), out, addr.len().min(32));
    true
}

// ---- clock ------------------------------------------------------------------------------------

/// Advance time: expire adverts, retransmit unacked bundles, prune dedup. Call ~1 Hz.
#[no_mangle]
pub unsafe extern "C" fn hop_node_tick(node: *const HopNode, now_ms: u64) {
    if let Some(node) = node_ref(node) {
        node.tick(now_ms);
    }
}

// ---- bearer seam: inbound (bearer -> core) ----------------------------------------------------

/// A bearer link came up. `role` = which side dialed (the Noise initiator/responder selector).
#[no_mangle]
pub unsafe extern "C" fn hop_link_up(node: *const HopNode, link: u64, role: HopLinkRole) {
    if let Some(node) = node_ref(node) {
        node.connected(link, matches!(role, HopLinkRole::Dialer));
    }
}

/// One frame of opaque bytes arrived on `link`.
#[no_mangle]
pub unsafe extern "C" fn hop_bytes_received(node: *const HopNode, link: u64, data: *const u8, len: usize) {
    if let Some(node) = node_ref(node) {
        node.received(link, slice(data, len).to_vec());
    }
}

/// A bearer link dropped.
#[no_mangle]
pub unsafe extern "C" fn hop_link_down(node: *const HopNode, link: u64) {
    if let Some(node) = node_ref(node) {
        node.disconnected(link);
    }
}

// ---- bearer seam: outbound (core -> bearer, POLLED) -------------------------------------------

/// Drain queued outbound packets. Synchronously invokes `sink(ctx, link, bytes_ptr, bytes_len)`
/// once per packet during this call — this is the POLL model; core never pushes asynchronously.
/// The byte pointer is valid only for the duration of each `sink` call; copy what you keep.
#[no_mangle]
pub unsafe extern "C" fn hop_drain_outgoing(
    node: *const HopNode,
    sink: Option<extern "C" fn(ctx: *mut c_void, link: u64, bytes: *const u8, len: usize)>,
    ctx: *mut c_void,
) {
    let (Some(node), Some(sink)) = (node_ref(node), sink) else {
        return;
    };
    for pkt in node.drain_outgoing() {
        sink(ctx, pkt.link, pkt.bytes.as_ptr(), pkt.bytes.len());
    }
}

// ---- client API (full client, e.g. ESP32) -----------------------------------------------------

/// Subscribe the directory to a service `topic` (UTF-8 C string).
#[no_mangle]
pub unsafe extern "C" fn hop_subscribe(node: *const HopNode, topic: *const c_char) {
    if let (Some(node), Some(topic)) = (node_ref(node), cstr(topic)) {
        node.subscribe(topic.to_string());
    }
}

/// Publish this node's prekey advert (DESIGN.md §25) so peers can seal forward-secret messages to
/// us; it gossips on link-up. Call once after opening (and after the first `hop_node_tick` sets a
/// real clock, else the advert is judged expired). Returns true on success.
#[no_mangle]
pub unsafe extern "C" fn hop_publish_prekey(node: *const HopNode) -> bool {
    matches!(node_ref(node), Some(node) if node.publish_prekey().is_ok())
}

/// Drain newly-received messages (poll model). Invokes
/// `sink(ctx, from32, content_type_cstr, body_ptr, body_len, hops, created_at_ms)` once per message
/// during this call. `from` points at 32 address bytes; `content_type` is a NUL-terminated UTF-8
/// string; `body` is `body_len` bytes — all valid only for the duration of each `sink` call.
#[no_mangle]
pub unsafe extern "C" fn hop_poll_inbox(
    node: *const HopNode,
    sink: Option<
        extern "C" fn(
            ctx: *mut c_void,
            from: *const u8,
            content_type: *const c_char,
            body: *const u8,
            body_len: usize,
            hops: u8,
            created_at: u64,
        ),
    >,
    ctx: *mut c_void,
) {
    let (Some(node), Some(sink)) = (node_ref(node), sink) else {
        return;
    };
    for m in node.take_inbox() {
        let ct = std::ffi::CString::new(m.content_type).unwrap_or_default();
        sink(ctx, m.from.as_ptr(), ct.as_ptr(), m.body.as_ptr(), m.body.len(), m.hops, m.created_at);
    }
}

/// Send a message to the 32-byte address `dst` — untraceable by default (DESIGN.md §39).
/// `content_type` is a UTF-8 C string (e.g. "text/plain"); `body`/`body_len` is the payload. If
/// `request_ack`, a private delivery confirmation is requested. On success writes the 32-byte
/// bundle id into `out_id` (room for 32 bytes, may be NULL to ignore) and returns true.
#[no_mangle]
pub unsafe extern "C" fn hop_send_message(
    node: *const HopNode,
    dst: *const u8,
    content_type: *const c_char,
    body: *const u8,
    body_len: usize,
    request_ack: bool,
    out_id: *mut u8,
) -> bool {
    let Some(node) = node_ref(node) else {
        return false;
    };
    let Some(ct) = cstr(content_type) else {
        return false;
    };
    if dst.is_null() {
        return false;
    }
    match node.send_message(slice(dst, 32).to_vec(), ct.to_string(), slice(body, body_len).to_vec(), request_ack) {
        Ok(id) => {
            if !out_id.is_null() {
                std::ptr::copy_nonoverlapping(id.as_ptr(), out_id, id.len().min(32));
            }
            true
        }
        Err(_) => false,
    }
}
