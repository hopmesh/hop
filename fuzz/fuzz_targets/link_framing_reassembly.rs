#![no_main]

// Framing and reassembly, over the path production actually runs.
//
// This target used to fuzz `hop_core::link::{Frame, fragment, Reassembler, MAX_FRAME_*}`, a second
// generic framing layer that no production code path ever called: record splitting was always done
// by `wire_emit::frame_record` into `LinkPacket::DataFrag` and reassembled by
// `Node::on_record_frag`. That dead layer was deleted in the v13 to v14 bump (audit PROC-001).
// Rather than drop a fuzz target along with it, the target was repointed at the real framing path,
// so coverage moved off code nothing emitted and onto code every link uses.

mod common;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: &[u8]| {
    let bytes = common::bounded_bytes(input, 256 * 1024);

    // Inbound: an attacker-controlled link packet must be rejected or bounded, never panic.
    hop_core::node::fuzz_link_packet(&bytes[..bytes.len().min(64 * 1024 + 1)]);

    // Outbound and back: whatever frame_record emits must decode inside the accepted envelope and
    // reassemble to exactly the plaintext that went in.
    //
    // Reaching the multi-fragment branch needs an input over ~60 KB, which a short smoke run will
    // not invent, so `corpus/link_framing_reassembly/multi-fragment-record` seeds one (64 KiB, which
    // this target turns into 2048 ids and therefore 2 fragments). The same round trip is also pinned
    // deterministically, on both branches, by
    // `wire_emit_tests::framing_round_trips_on_both_the_single_and_fragmented_branches`, so the
    // fragmented path does not depend on the fuzzer's luck.
    hop_core::node::fuzz_record_framing(&bytes);
});
