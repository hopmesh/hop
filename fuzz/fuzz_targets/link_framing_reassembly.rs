#![no_main]

mod common;

use hop_core::link::{
    Frame, Reassembler, MAX_FRAME_FRAGMENTS, MAX_FRAME_PAYLOAD_BYTES, MAX_FRAME_WIRE_BYTES,
};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: &[u8]| {
    let bytes = common::bounded_bytes(input, 256 * 1024);
    hop_core::node::fuzz_link_packet(&bytes[..bytes.len().min(64 * 1024 + 1)]);

    let frame_input = &bytes[..bytes.len().min(MAX_FRAME_WIRE_BYTES + 1)];
    if let Ok(frame) = Frame::from_bytes(frame_input) {
        let canonical = frame.to_bytes().expect("decoded frame re-encodes");
        assert_eq!(Frame::from_bytes(&canonical).unwrap(), frame);
    }

    let mut id = [0u8; 32];
    let id_len = bytes.len().min(32);
    id[..id_len].copy_from_slice(&bytes[..id_len]);
    let raw_count = bytes
        .get(32..34)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .unwrap_or(0);
    let count = if input.trim_ascii() == b"huge-fragment-count" {
        MAX_FRAME_FRAGMENTS + 1
    } else {
        raw_count
    };
    let mut reassembler = Reassembler::new(id, count);
    for (sequence, chunk) in bytes.get(34..).unwrap_or_default().chunks(64).take(256).enumerate() {
        let mut index = u16::try_from(sequence).unwrap_or(u16::MAX);
        if input.trim_ascii() == b"sequence-gap" && sequence == 1 {
            index = index.saturating_add(2);
        }
        let frame = Frame {
            bundle_id: id,
            frag_index: index,
            frag_count: count,
            bytes: chunk[..chunk.len().min(MAX_FRAME_PAYLOAD_BYTES)].to_vec(),
        };
        let _ = reassembler.accept(frame);
    }
});
