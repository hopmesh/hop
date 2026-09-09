//! Canonical bundle decoding.
//!
//! This module provides strict canonical bundle decoding for pure-Rust services.
//! It exists outside `bundle.rs` because `core/hop-core/src/bundle.rs` is a declared
//! wire-source file tracked by `tools/wire-version-guard.sh`. Modifying `bundle.rs`
//! directly would demand a `BUNDLE_VERSION` bump that changes no emitted bytes.
//! By placing this canonical validation wrapper in `canonical.rs`, services can
//! enforce that bundle wire bytes match their canonical re-encoding without bumping
//! the wire format version.

use crate::bundle::Bundle;
use crate::error::{Error, Result};

/// Decode a bundle from wire bytes and verify that the input is the canonical
/// encoding of the resulting bundle.
///
/// Postcard deserialization by default ignores unparsed trailing bytes. This function
/// decodes the bundle via [`Bundle::from_bytes`], re-encodes it via [`Bundle::to_bytes`],
/// and verifies that the canonical re-encoded slice matches the input bytes byte for byte.
pub fn decode_bundle(bytes: &[u8]) -> Result<Bundle> {
    let bundle = Bundle::from_bytes(bytes)?;
    let canonical = bundle.to_bytes()?;
    if canonical.as_slice() != bytes {
        return Err(Error::Other("bundle bytes are not canonical".into()));
    }
    Ok(bundle)
}

#[cfg(test)]
mod tests {
    use crate::bundle::{Bundle, BundleOpts, Destination, Payload};
    use crate::crypto::Identity;

    use super::decode_bundle;

    #[test]
    fn canonical_decode_accepts_clean_and_rejects_trailing_garbage() {
        let sender = Identity::generate();
        let recipient = Identity::generate();
        let bundle = Bundle::create(
            &sender,
            Destination::Device(recipient.address()),
            &recipient.address(),
            &Payload::PeerMessage {
                content_type: "text/plain".into(),
                body: b"12345".to_vec(),
            },
            BundleOpts::default(),
        )
        .unwrap();

        let clean = bundle.to_bytes().unwrap();
        assert_eq!(clean.len(), 274);
        println!(
            "clean len={} decode={} verify={}",
            clean.len(),
            Bundle::from_bytes(&clean).is_ok(),
            bundle.verify().is_ok()
        );

        // Clean bundle decodes canonically
        let decoded = decode_bundle(&clean).expect("clean bundle must decode canonically");
        assert_eq!(decoded.id(), bundle.id());

        for pad_len in [1, 16, 128] {
            let mut padded = clean.clone();
            padded.extend(vec![0xAA; pad_len]);

            // Base Bundle::from_bytes erroneously accepts trailing bytes:
            let raw_decoded = Bundle::from_bytes(&padded);
            let ok = raw_decoded.is_ok();
            let verify_ok = raw_decoded
                .as_ref()
                .map(|b| b.verify().is_ok())
                .unwrap_or(false);
            let id_same = raw_decoded
                .as_ref()
                .map(|b| b.id() == bundle.id())
                .unwrap_or(false);
            println!("trailing {pad_len}: DECODED={ok} verify={verify_ok} id_same={id_same}");
            assert!(
                raw_decoded.is_ok(),
                "Bundle::from_bytes accepts trailing bytes"
            );

            // But canonical decode_bundle strictly rejects them:
            let result = decode_bundle(&padded);
            assert!(
                result.is_err(),
                "trailing {pad_len} bytes must be rejected by decode_bundle"
            );
        }
    }

    #[test]
    fn canonical_decode_private_and_vaccine_bundles() {
        let recipient = Identity::generate();
        let spk = recipient.derive_prekey();
        let private_bundle = Bundle::create_private(
            &recipient.address(),
            &spk.public,
            &Payload::PeerMessage {
                content_type: "t".into(),
                body: b"priv".to_vec(),
            },
            None,
            BundleOpts::default(),
        )
        .unwrap();

        let clean_priv = private_bundle.to_bytes().unwrap();
        let decoded_priv = decode_bundle(&clean_priv).expect("clean private bundle must decode");
        assert_eq!(decoded_priv.id(), private_bundle.id());

        for pad_len in [1, 16, 128] {
            let mut padded = clean_priv.clone();
            padded.extend(vec![0xBB; pad_len]);
            assert!(decode_bundle(&padded).is_err());
        }

        let vaccine = Bundle::create_vaccine([7u8; 32], BundleOpts::default());
        let clean_vac = vaccine.to_bytes().unwrap();
        let decoded_vac = decode_bundle(&clean_vac).expect("clean vaccine must decode");
        assert_eq!(decoded_vac.id(), vaccine.id());

        for pad_len in [1, 16, 128] {
            let mut padded = clean_vac.clone();
            padded.extend(vec![0xCC; pad_len]);
            assert!(decode_bundle(&padded).is_err());
        }
    }

    #[test]
    fn measure_canonical_decode_overhead() {
        use std::time::Instant;

        let sender = Identity::generate();
        let recipient = Identity::generate();
        let bundle = Bundle::create(
            &sender,
            Destination::Device(recipient.address()),
            &recipient.address(),
            &Payload::PeerMessage {
                content_type: "text/plain".into(),
                body: b"measurement payload for benchmarking decode overhead".to_vec(),
            },
            BundleOpts::default(),
        )
        .unwrap();
        let bytes = bundle.to_bytes().unwrap();

        const ITERS: u32 = 10_000;

        // Warm up
        for _ in 0..1_000 {
            let b = Bundle::from_bytes(&bytes).unwrap();
            let _ = b.to_bytes().unwrap();
        }

        let start_decode = Instant::now();
        for _ in 0..ITERS {
            let _ = Bundle::from_bytes(&bytes).unwrap();
        }
        let decode_elapsed = start_decode.elapsed();

        let start_reencode = Instant::now();
        for _ in 0..ITERS {
            let b = Bundle::from_bytes(&bytes).unwrap();
            let _ = b.to_bytes().unwrap();
        }
        let reencode_elapsed = start_reencode.elapsed();

        let start_full = Instant::now();
        for _ in 0..ITERS {
            let _ = decode_bundle(&bytes).unwrap();
        }
        let full_elapsed = start_full.elapsed();

        let decode_ns = decode_elapsed.as_nanos() as f64 / ITERS as f64;
        let reencode_ns =
            (reencode_elapsed.as_nanos() - decode_elapsed.as_nanos()) as f64 / ITERS as f64;
        let full_ns = full_elapsed.as_nanos() as f64 / ITERS as f64;

        println!(
            "BENCHMARK: from_bytes={:.2}us, re-encode={:.2}us, full decode_bundle={:.2}us (overhead={:.2}us per bundle)",
            decode_ns / 1000.0,
            reencode_ns / 1000.0,
            full_ns / 1000.0,
            (full_ns - decode_ns) / 1000.0
        );
    }
}
