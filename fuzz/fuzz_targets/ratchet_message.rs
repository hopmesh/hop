#![no_main]

mod common;

use hop_core::session::{RatchetMessage, Session, MAX_RATCHET_MESSAGE_BYTES};
use libfuzzer_sys::fuzz_target;

fuzz_target!(|input: &[u8]| {
    let bytes = common::bounded_bytes(input, MAX_RATCHET_MESSAGE_BYTES + 1);
    let Ok(message) = RatchetMessage::from_bytes(&bytes) else {
        return;
    };
    let canonical = message.to_bytes().expect("decoded ratchet message re-encodes");
    assert_eq!(RatchetMessage::from_bytes(&canonical).unwrap(), message);

    let mut session = Session::init_responder([1u8; 32], [2u8; 32], [3u8; 32]);
    let before = postcard::to_allocvec(&session).expect("session serializes");
    if session.decrypt(&message).is_err() {
        let after = postcard::to_allocvec(&session).expect("session serializes after failure");
        assert_eq!(after, before, "failed authentication advanced ratchet state");
    }
});
