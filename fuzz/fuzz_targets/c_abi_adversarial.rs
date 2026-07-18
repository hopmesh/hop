#![no_main]

mod common;

use std::ffi::c_char;

use hop::cabi::*;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: &[u8]| {
    let bytes = common::bounded_bytes(input, 64 * 1024);
    let adversarial_len = match input.trim_ascii() {
        b"fixed-width-0" => 0,
        b"fixed-width-1" => 1,
        b"fixed-width-31" => 31,
        b"fixed-width-32" => 32,
        b"fixed-width-33" => 33,
        b"max-length" => usize::MAX,
        _ => common::u64_prefix(&bytes) as usize,
    };
    unsafe {
        let rejected = hop_node_with_secret(std::ptr::null(), adversarial_len);
        if adversarial_len == 0 {
            if !rejected.is_null() {
                hop_node_free(rejected);
            }
        } else {
            assert!(rejected.is_null());
        }

        let seed_len = bytes.len().min(32);
        let node = hop_node_with_secret(bytes.as_ptr(), seed_len);
        assert!(!node.is_null());
        hop_bytes_received(node, 1, std::ptr::null(), adversarial_len);
        hop_link_up(node, 1, u32::from(bytes.first().copied().unwrap_or(0)));

        let packet_len = bytes.len().min(hop_core::node::MAX_LINK_PACKET_BYTES);
        hop_bytes_received(node, 1, bytes.as_ptr(), packet_len);
        let _ = hop_verify_reach_record(
            bytes.as_ptr(),
            bytes.len(),
            0,
            None,
            std::ptr::null_mut(),
        );
        let mut wire_metadata = [0u8; HOP_WIRE_BUNDLE_METADATA_LEN];
        let _ = hop_validate_wire_bundle(
            bytes.as_ptr(),
            bytes.len(),
            wire_metadata.as_mut_ptr(),
            wire_metadata.len(),
        );

        let destination = [7u8; 32];
        let content_type = b"application/octet-stream\0";
        let _ = hop_send_message(
            node,
            destination.as_ptr(),
            content_type.as_ptr() as *const c_char,
            bytes.as_ptr(),
            bytes.len(),
            false,
            std::ptr::null_mut(),
        );
        hop_node_free(node);
    }
});
