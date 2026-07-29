#![no_main]

mod common;

use hop_core::bundle::{Bundle, BundleFlags, BundleOpts, Payload, MAX_BUNDLE_WIRE_BYTES};
use hop_core::crypto::Identity;
use libfuzzer_sys::fuzz_target;

fn materialize(input: &[u8]) -> Vec<u8> {
    match input.trim_ascii() {
        b"non-canonical-vaccine-twin" => {
            let mut bundle = Bundle::create_vaccine([7u8; 32], BundleOpts::default());
            bundle.inner.flags.is_ack = false;
            bundle.to_bytes().expect("vaccine twin encodes")
        }
        b"private-header-mismatch" => {
            let recipient = Identity::from_secret_bytes(&[9u8; 32]);
            let prekey = recipient.derive_prekey();
            let mut bundle = Bundle::create_private(
                &recipient.address(),
                &prekey.public,
                &Payload::PeerMessage {
                    content_type: "fuzz".into(),
                    body: vec![1, 2, 3],
                },
                Some([0x12]),
                BundleOpts {
                    flags: BundleFlags {
                        request_ack: true,
                        is_ack: false,
                        custody_requested: false,
                    },
                    ..Default::default()
                },
            )
            .expect("private fuzz seed builds");
            bundle.inner.private.as_mut().unwrap().tag[0] ^= 0x80;
            bundle.to_bytes().expect("private chimera encodes")
        }
        b"oversized-length" => vec![0u8; MAX_BUNDLE_WIRE_BYTES + 1],
        _ => common::bounded_bytes(input, MAX_BUNDLE_WIRE_BYTES + 1),
    }
}

fuzz_target!(|input: &[u8]| {
    let bytes = materialize(input);
    if let Ok(bundle) = Bundle::from_bytes(&bytes) {
        let _ = bundle.verify();
        let canonical = bundle.to_bytes().expect("decoded bundle re-encodes");
        let decoded = Bundle::from_bytes(&canonical).expect("canonical bundle decodes");
        assert_eq!(decoded, bundle);
    }
});
