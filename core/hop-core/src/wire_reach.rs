//! Wire-byte determination for self-certifying reach records (DESIGN.md Sec.30).
//!
//! Everything in this module decides bytes that leave the machine: the [`ReachClaim`] and
//! [`ReachRecord`] struct layouts, their postcard field order, the domain separator
//! [`REACH_CONTEXT`], and [`signing_bytes`]. It is deliberately separated from [`crate::reach`],
//! whose remaining lines are admission and acceptance POLICY (input size bounds, endpoint length
//! bounds, signature verification, and TTL expiry) and decide no emitted byte at all.
//!
//! `core/hop-core/vectors/wire-source-manifest.txt` names this file, not `reach.rs`. The split
//! follows the exact precedent set by `node.rs -> wire_emit.rs`, `access.rs -> wire_stamp.rs`,
//! and `store.rs -> wire_have.rs`: adding an acceptance ceiling or tightening an input bound is an
//! admission policy change, not a format change, and must not demand a `BUNDLE_VERSION` bump.

use serde::{Deserialize, Serialize};

use crate::crypto::{Identity, PubKeyBytes};

/// Domain separator so a reach-record signature can never be confused with any other signed blob
/// this identity produces (prekeys, bundles, hps records).
pub const REACH_CONTEXT: &[u8] = b"hop/reach-record/v1\0";

/// The signed content: who is reachable where, when, and for how long.
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Debug)]
pub struct ReachClaim {
    /// The signer's Hop address (Ed25519 public key). The record self-certifies against this.
    pub address: PubKeyBytes,
    /// Opaque endpoint spec the app interprets, e.g. `wss://myaddress.com/_hop` or `1.2.3.4:9944`.
    pub endpoint: String,
    /// Unix seconds when signed. A newer record supersedes an older one for the same address.
    pub issued_at: u64,
    /// Seconds the record stays valid from `issued_at`.
    pub ttl_secs: u32,
}

/// A signed reachability record: the claim plus an Ed25519 signature by `claim.address`.
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Debug)]
pub struct ReachRecord {
    pub claim: ReachClaim,
    /// Ed25519 signature over the domain-separated, postcard-encoded claim (64 bytes).
    pub sig: Vec<u8>,
}

/// The exact bytes signed/verified: a domain prefix + the deterministic postcard encoding of the
/// claim. Single-purpose by the prefix; stable by postcard's determinism.
pub fn signing_bytes(claim: &ReachClaim) -> Vec<u8> {
    let mut v = Vec::from(REACH_CONTEXT);
    v.extend_from_slice(&postcard::to_allocvec(claim).unwrap_or_default());
    v
}

impl ReachRecord {
    /// Sign a reachability claim with `id`'s identity key. `now_secs` stamps `issued_at`.
    pub fn sign(
        id: &Identity,
        endpoint: impl Into<String>,
        ttl_secs: u32,
        now_secs: u64,
    ) -> ReachRecord {
        let claim = ReachClaim {
            address: id.address(),
            endpoint: endpoint.into(),
            issued_at: now_secs,
            ttl_secs,
        };
        let sig = id.sign(&signing_bytes(&claim)).to_vec();
        ReachRecord { claim, sig }
    }

    /// Serialize for a well-known body, gossip, or cache.
    pub fn to_bytes(&self) -> Vec<u8> {
        postcard::to_allocvec(self).unwrap_or_default()
    }
}
