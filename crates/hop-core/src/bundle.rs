//! The bundle: the unit of store-and-forward. See DESIGN.md §5.
//!
//! A bundle splits into a signed inner header ([`SignedInner`], covered by the
//! source signature) and a mutable forwarding [`Envelope`] (`hop_limit`,
//! `custody`) that relays may update without invalidating the signature.

use serde::{Deserialize, Serialize};

use crate::crypto::{self, Identity, PubKeyBytes, Sealed, ShortAddr, XPubKeyBytes};
use crate::error::{Error, Result};
use crate::{AppId, FABRIC_APP};

/// Wire format version.
pub const BUNDLE_VERSION: u8 = 1;

/// Globally-unique bundle id: `BLAKE3(src || nonce || payload_hash)`.
pub type BundleId = [u8; 32];

/// Where a bundle is headed. See DESIGN.md §5.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Destination {
    /// Use Case B: a specific device address.
    Device(PubKeyBytes),
    /// Use Case A: any gateway with the egress capability.
    InternetEgress,
    /// An ACK routed back to `origin` for a given bundle id.
    AckTo(PubKeyBytes, BundleId),
}

/// Per-bundle flags. Plain bools to avoid a bitflags dependency.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BundleFlags {
    pub request_ack: bool,
    pub is_ack: bool,
    pub custody_requested: bool,
}

/// Identifies a long-lived stream session (SSE/WebSocket) the gateway holds on a
/// device's behalf. See DESIGN.md §20.
pub type StreamId = [u8; 16];

/// The kind of gateway-held streaming connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum StreamKind {
    /// Server-Sent Events (one-way, server → device).
    Sse,
    /// WebSocket (bidirectional).
    WebSocket,
}

/// The application payload, *before* sealing. Lives encrypted inside [`Sealed`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Payload {
    HttpRequest {
        method: String,
        url: String,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
        max_resp_bytes: u32,
    },
    HttpResponse {
        status: u16,
        headers: Vec<(String, String)>,
        body: Vec<u8>,
        for_bundle_id: BundleId,
    },
    PeerMessage {
        content_type: String,
        body: Vec<u8>,
    },
    /// First message of a forward-secret session (DESIGN.md §25). Carries the X3DH
    /// ephemeral and the prekey it used (so the recipient derives the same root),
    /// plus the first ratchet message. Re-sent until the recipient replies, so any
    /// copy can bootstrap the session. The ratchet ciphertext is already end-to-end
    /// encrypted; the surrounding bundle seal is redundant for sessions (a later
    /// bundle-format change can carry it unsealed).
    SessionInit {
        ek_pub: XPubKeyBytes,
        spk_pub: XPubKeyBytes,
        msg: crate::session::RatchetMessage,
    },
    /// A ratchet message in an established forward-secret session.
    SessionMessage {
        msg: crate::session::RatchetMessage,
    },
    Ack {
        for_bundle_id: BundleId,
        status: u8,
        /// Hops the original message took to reach the destination (the forward path
        /// length the destination observed on arrival). Reported back for the UI.
        delivery_hops: u8,
    },
    /// Open a gateway-held streaming connection (SSE/WebSocket). See DESIGN.md §20.
    StreamOpen {
        stream_id: StreamId,
        kind: StreamKind,
        method: String,
        url: String,
        headers: Vec<(String, String)>,
    },
    /// One ordered chunk of a stream, in either direction. `fin` marks the last.
    StreamData {
        stream_id: StreamId,
        seq: u64,
        bytes: Vec<u8>,
        fin: bool,
    },
    /// Flow-control / catch-up: "I have everything contiguously through `ack`."
    /// Lets the holder release buffered chunks and resend any the peer missed.
    StreamAck {
        stream_id: StreamId,
        ack: u64,
    },
    /// Tear down a stream session.
    StreamClose {
        stream_id: StreamId,
        reason: u16,
    },
}

/// The signed portion of a bundle. The source signature covers this exactly.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedInner {
    pub version: u8,
    /// Application namespace on the shared fabric (DESIGN.md §17).
    pub app: AppId,
    pub id: BundleId,
    pub src: PubKeyBytes,
    pub dst: Destination,
    /// Sender clock in ms — advisory only (see DESIGN.md §8).
    pub created_at: u64,
    pub lifetime_ms: u32,
    pub flags: BundleFlags,
    /// Service priority (0 = lowest). Relays evict low-priority relayed bundles
    /// first under storage pressure (§ relay queue). Default normal.
    pub priority: u8,
    pub payload: Sealed,
}

/// The mutable forwarding envelope. NOT covered by the signature; relays update it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Envelope {
    pub hop_limit: u8,
    pub custody: Option<PubKeyBytes>,
    /// Binary spray-and-wait copy budget held by the current custodian (§6). The
    /// count travels with the bundle so a receiver knows how many copies it now
    /// owns. Not signed — it's per-custodian forwarding state, not content.
    pub copies: u16,
    /// Hops travelled from the source so far — incremented on each forward. Lets
    /// the destination see the path length A→B. Not signed (advisory).
    pub hops: u8,
    /// Provenance: the `short_addr` of each node that forwarded this bundle, in
    /// order (DESIGN.md §27). Not signed — it's mutable forwarding metadata. Lets the
    /// destination see the path and nodes learn routes from ACK/trace correlation.
    pub trace: Vec<ShortAddr>,
}

/// Delivery options for a new bundle. Use `..Default::default()` for the rest.
#[derive(Clone, Copy, Debug)]
pub struct BundleOpts {
    /// Application namespace on the shared fabric (DESIGN.md §17).
    pub app: AppId,
    /// Sender clock in ms — advisory only (see DESIGN.md §8).
    pub created_at: u64,
    pub lifetime_ms: u32,
    pub hop_limit: u8,
    /// Initial spray-and-wait copy budget L (§6). 1 = direct-delivery only.
    pub copies: u16,
    /// Service priority (0 = lowest, default 4 = normal).
    pub priority: u8,
    pub flags: BundleFlags,
}

impl Default for BundleOpts {
    fn default() -> Self {
        Self {
            app: FABRIC_APP,
            created_at: 0,
            lifetime_ms: 3_600_000, // 1h
            hop_limit: 8,
            copies: 8,
            priority: 4,
            flags: BundleFlags::default(),
        }
    }
}

/// A complete bundle as it travels across links.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Bundle {
    pub inner: SignedInner,
    pub env: Envelope,
    pub sig: Vec<u8>,
}

impl Bundle {
    /// Build, seal, and sign a new bundle from `from` to `dst`.
    ///
    /// `seal_to` is the **address** the payload is sealed to (its X25519 key is
    /// derived from it) — usually the destination device (B), or a gateway address
    /// for egress (A). An address is all you need; no separate sealing key.
    pub fn create(
        from: &Identity,
        dst: Destination,
        seal_to: &PubKeyBytes,
        payload: &Payload,
        opts: BundleOpts,
    ) -> Result<Self> {
        let plaintext = postcard::to_allocvec(payload)?;
        let sealed = crypto::seal(seal_to, &plaintext)?;

        let src = from.address();
        let id = compute_id(&src, &sealed);

        let inner = SignedInner {
            version: BUNDLE_VERSION,
            app: opts.app,
            id,
            src,
            dst,
            created_at: opts.created_at,
            lifetime_ms: opts.lifetime_ms,
            flags: opts.flags,
            priority: opts.priority,
            payload: sealed,
        };

        let sig = from.sign(&postcard::to_allocvec(&inner)?).to_vec();
        let env = Envelope {
            hop_limit: opts.hop_limit,
            custody: opts.flags.custody_requested.then_some(src),
            copies: opts.copies.max(1),
            hops: 0,
            trace: Vec::new(),
        };

        Ok(Bundle { inner, env, sig })
    }

    /// The bundle id.
    pub fn id(&self) -> BundleId {
        self.inner.id
    }

    /// Verify the source signature and that the id matches the sealed payload.
    /// Relays should call this before forwarding to avoid amplifying garbage.
    pub fn verify(&self) -> Result<()> {
        if compute_id(&self.inner.src, &self.inner.payload) != self.inner.id {
            return Err(Error::BadSignature);
        }
        let msg = postcard::to_allocvec(&self.inner)?;
        if crypto::verify(&self.inner.src, &msg, &self.sig) {
            Ok(())
        } else {
            Err(Error::BadSignature)
        }
    }

    /// Open the sealed payload with the recipient identity (destination or gateway).
    pub fn open(&self, recipient: &Identity) -> Result<Payload> {
        let plaintext = recipient.open(&self.inner.payload)?;
        Ok(postcard::from_bytes(&plaintext)?)
    }

    /// Binary spray-and-wait handoff (§6): split this custodian's copy budget,
    /// reducing our own count and returning the number to give the peer
    /// (`floor(n/2)`). At a single copy this returns 0 — the wait phase, where the
    /// bundle is only ever handed directly to its destination.
    pub fn split_copies(&mut self) -> u16 {
        let give = self.env.copies / 2;
        self.env.copies -= give;
        give
    }

    /// Are we down to the last copy (wait phase)?
    pub fn is_last_copy(&self) -> bool {
        self.env.copies <= 1
    }

    /// Mark this copy as forwarded one hop: increment travelled `hops` and
    /// decrement `hop_limit`. Returns false if the hop limit is exhausted.
    pub fn forwarded(&mut self) -> bool {
        self.env.hops = self.env.hops.saturating_add(1);
        self.decrement_hop()
    }

    /// Append a forwarder's short address to the provenance trace (DESIGN.md §27).
    /// Capped so a long-lived bundle can't grow an unbounded header.
    pub fn add_hop(&mut self, who: ShortAddr) {
        const MAX_TRACE: usize = 16;
        if self.env.trace.len() < MAX_TRACE {
            self.env.trace.push(who);
        }
    }

    /// The provenance trace: short addresses of the nodes that forwarded this bundle.
    pub fn trace(&self) -> &[ShortAddr] {
        &self.env.trace
    }

    /// Decrement the hop limit for forwarding. Returns false if undeliverable.
    pub fn decrement_hop(&mut self) -> bool {
        match self.env.hop_limit.checked_sub(1) {
            Some(n) => {
                self.env.hop_limit = n;
                true
            }
            None => false,
        }
    }

    /// Encode to the wire format (postcard — see DESIGN.md §13.4).
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        Ok(postcard::to_allocvec(self)?)
    }

    /// Decode from the wire format.
    pub fn from_bytes(data: &[u8]) -> Result<Self> {
        Ok(postcard::from_bytes(data)?)
    }
}

fn compute_id(src: &PubKeyBytes, sealed: &Sealed) -> BundleId {
    let mut hasher = blake3::Hasher::new();
    hasher.update(src);
    hasher.update(&sealed.ephemeral_pub);
    hasher.update(&sealed.nonce);
    hasher.update(&sealed.ciphertext);
    *hasher.finalize().as_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(from: &Identity, to_addr: &PubKeyBytes) -> Bundle {
        Bundle::create(
            from,
            Destination::InternetEgress,
            to_addr,
            &Payload::PeerMessage {
                content_type: "text/plain".into(),
                body: b"hello mesh".to_vec(),
            },
            BundleOpts {
                created_at: 1_000,
                flags: BundleFlags { request_ack: true, ..Default::default() },
                ..Default::default()
            },
        )
        .unwrap()
    }

    #[test]
    fn create_verify_open_roundtrip() {
        let alice = Identity::generate();
        let gw = Identity::generate();
        let b = sample(&alice, &gw.address());

        b.verify().unwrap();
        match b.open(&gw).unwrap() {
            Payload::PeerMessage { body, .. } => assert_eq!(body, b"hello mesh"),
            _ => panic!("wrong payload"),
        }
    }

    #[test]
    fn wire_roundtrip_is_stable() {
        let alice = Identity::generate();
        let gw = Identity::generate();
        let b = sample(&alice, &gw.address());

        let bytes = b.to_bytes().unwrap();
        let decoded = Bundle::from_bytes(&bytes).unwrap();
        assert_eq!(b, decoded);
        decoded.verify().unwrap();
    }

    #[test]
    fn tampering_breaks_verification() {
        let alice = Identity::generate();
        let gw = Identity::generate();
        let mut b = sample(&alice, &gw.address());

        b.inner.lifetime_ms = 1; // mutate a signed field
        assert!(matches!(b.verify(), Err(Error::BadSignature)));
    }

    #[test]
    fn forwarding_envelope_is_not_signed() {
        let alice = Identity::generate();
        let gw = Identity::generate();
        let mut b = sample(&alice, &gw.address());

        assert!(b.decrement_hop()); // relays mutate the envelope
        b.verify().unwrap(); // signature still valid
    }
}
