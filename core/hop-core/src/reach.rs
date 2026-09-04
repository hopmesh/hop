//! Self-certifying reachability records: a node signs "I, address X, am reachable at `<endpoint>`"
//! with its identity key, and anyone verifies that signature against X. This is the DNS-free,
//! cacheable, gossip-able binding of a Hop address to a network location.
//!
//! It is the address -> location half of endpoint discovery. The name -> address half is separate:
//! either the name IS the address (self-certifying, `hops://<address>`), or a domain's TLS cert binds
//! `myaddress.com -> X` when the record is served from `https://myaddress.com/.well-known/hop`. Either
//! way this record needs NO external trust anchor: the claimed `address` is the very key that signs it,
//! so a forged claim (someone else's address, a tampered endpoint) simply fails the signature check.
//!
//! ## Revocation model (why there is no revocation list)
//!
//! A self-certifying record has no issuing authority, so there is no CA to publish a CRL/OCSP against
//! and nothing a third party could revoke on the signer's behalf. Revocation is instead **expiry +
//! re-signing**, the same model as short-lived TLS certificates: a record is only trusted for
//! `ttl_secs` from `issued_at` (enforced in [`ReachRecord::verify`]), and the holder keeps a live
//! record fresh by re-signing before it lapses. To retire an endpoint, stop re-signing and let the
//! last record expire; to move, sign a new record (a strictly-newer `issued_at` supersedes the old
//! one for the same address). Publishers therefore choose a TTL that bounds their own worst-case
//! staleness: **short TTLs (minutes to a few hours) are the revocation granularity** and are cheap
//! because signing is one Ed25519 op (hop-endpoint re-signs hourly, see `WELL_KNOWN_RESIGN`). Key
//! compromise is out of scope of the record itself (a stolen identity key can sign valid records for
//! its own address until the address is abandoned), exactly as a stolen TLS key can, and is handled at
//! the identity layer, not here.

use crate::crypto;
pub use crate::wire_reach::{signing_bytes, ReachClaim, ReachRecord, REACH_CONTEXT};

/// Maximum wire bytes accepted by [`ReachRecord::verify`].
/// Checked before postcard deserialization to bound attacker-controlled allocation.
pub const MAX_REACH_RECORD_BYTES: usize = 64 * 1024;

/// Maximum length of an endpoint string in a reach claim.
/// Checked before signature verification to bound dial string size.
pub const MAX_REACH_ENDPOINT_BYTES: usize = 2 * 1024;

impl ReachRecord {
    /// Parse and VERIFY. The signature must be by `claim.address`; when `now_secs` is supplied the
    /// record must be unexpired. Returns the verified record, or `None` on malformed / bad-signature /
    /// expired. Self-certifying: no external key or anchor is consulted.
    pub fn verify(bytes: &[u8], now_secs: Option<u64>) -> Option<ReachRecord> {
        if bytes.len() > MAX_REACH_RECORD_BYTES {
            return None;
        }
        let rec: ReachRecord = postcard::from_bytes(bytes).ok()?;
        if rec.sig.len() != 64 {
            return None;
        }
        if rec.claim.endpoint.len() > MAX_REACH_ENDPOINT_BYTES {
            return None;
        }
        if !crypto::verify(&rec.claim.address, &signing_bytes(&rec.claim), &rec.sig) {
            return None;
        }
        if let Some(now) = now_secs {
            let expiry = rec
                .claim
                .issued_at
                .saturating_add(rec.claim.ttl_secs as u64);
            if now > expiry {
                return None;
            }
        }
        Some(rec)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::Identity;

    #[test]
    fn signs_and_verifies_round_trip() {
        let id = Identity::generate();
        let rec = ReachRecord::sign(&id, "wss://myaddress.com/_hop", 3600, 1_000);
        let got = ReachRecord::verify(&rec.to_bytes(), Some(1_500)).expect("valid record verifies");
        assert_eq!(got.claim.address, id.address());
        assert_eq!(got.claim.endpoint, "wss://myaddress.com/_hop");
    }

    #[test]
    fn rejects_tampered_endpoint() {
        let id = Identity::generate();
        let mut rec = ReachRecord::sign(&id, "wss://good.com/_hop", 3600, 1_000);
        rec.claim.endpoint = "wss://evil.com/_hop".into(); // the signature no longer covers this
        assert!(ReachRecord::verify(&rec.to_bytes(), None).is_none());
    }

    #[test]
    fn cannot_forge_someone_elses_address() {
        // Sign as the attacker, then claim to be `real`. The sig won't verify against real's key.
        let real = Identity::generate();
        let attacker = Identity::generate();
        let mut rec = ReachRecord::sign(&attacker, "wss://evil.com/_hop", 3600, 1_000);
        rec.claim.address = real.address();
        assert!(ReachRecord::verify(&rec.to_bytes(), None).is_none());
    }

    #[test]
    fn rejects_expired_but_accepts_within_ttl() {
        let id = Identity::generate();
        let rec = ReachRecord::sign(&id, "1.2.3.4:9944", 60, 1_000);
        assert!(
            ReachRecord::verify(&rec.to_bytes(), Some(1_030)).is_some(),
            "within ttl"
        );
        assert!(
            ReachRecord::verify(&rec.to_bytes(), Some(2_000)).is_none(),
            "past issued_at + ttl"
        );
    }

    #[test]
    fn oversized_reach_record_is_rejected_before_postcard_allocation() {
        let id = Identity::generate();
        let big_endpoint = "w".repeat(65_536);
        let rec = ReachRecord::sign(&id, big_endpoint, 3600, 1_000);
        let bytes = rec.to_bytes();
        assert!(
            bytes.len() > 64 * 1024,
            "precondition: serialized bytes exceed 64 KiB ceiling"
        );
        assert!(
            ReachRecord::verify(&bytes, Some(1_000)).is_none(),
            "ReachRecord::verify must reject records exceeding MAX_REACH_RECORD_BYTES"
        );
    }

    #[test]
    fn oversized_endpoint_is_rejected_before_signature_verification() {
        let id = Identity::generate();
        let big_endpoint = "w".repeat(2_049);
        let rec = ReachRecord::sign(&id, big_endpoint, 3600, 1_000);
        let bytes = rec.to_bytes();
        assert!(
            ReachRecord::verify(&bytes, Some(1_000)).is_none(),
            "ReachRecord::verify must reject claims with endpoint exceeding MAX_REACH_ENDPOINT_BYTES"
        );
    }
}
