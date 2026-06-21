//! `hps://` pub/sub primitives — services & channels (DESIGN.md §32).
//!
//! `hps://` is publish/subscribe, distinct from request/response `hops://`. A topic lives at a
//! path on any node. Two cryptographic concerns are kept separate:
//!
//! - **Confidentiality** — a symmetric **content key**, handed to members at subscribe time;
//!   anyone holding it can decrypt (read) and, for a channel, encrypt (write).
//! - **Authenticity** — every published message is **signed by its sender**. For a *channel*
//!   each member signs with their own device identity (so readers see a verified sender). For a
//!   *service* only the owner's **signing key** produces a valid broadcast, so a leaked content
//!   key lets someone read but never forge a broadcast.
//!
//! This module is the crypto + config layer; the node registry, subscribe/publish wire flow,
//! and ACK-based reach build on top.

use chacha20poly1305::{aead::Aead, ChaCha20Poly1305, Key, KeyInit, Nonce};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};

use crate::crypto::Identity;

/// A well-known keypair every node holds, used only to seal/open the *envelope* of a broadcast
/// bundle (DESIGN.md §32). Its secret is public (derived from a constant), so any node can open
/// a broadcast — confidentiality of the actual message is the content key inside, not this. A
/// broadcast can't be addressed to one recipient, so we seal to this shared key instead.
pub fn broadcast_identity() -> Identity {
    let seed = blake3::hash(b"hop.hps.broadcast.v1");
    Identity::from_secret_bytes(seed.as_bytes())
}

/// A 32-byte symmetric content key (read/write membership for a topic).
pub type ContentKey = [u8; 32];

/// What kind of topic a path hosts.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ServiceKind {
    /// Anyone with the content key reads AND writes; each post signed by its writer's identity.
    Channel,
    /// Only the owner broadcasts (signed by the service key); subscribers read.
    Service,
}

/// The persisted configuration for a topic registered at a path. Holds the secret material, so
/// it lives only in the host node's store — never sent on the wire as-is.
#[derive(Clone, Serialize, Deserialize)]
pub struct ServiceConfig {
    pub kind: ServiceKind,
    /// Symmetric key for confidentiality (handed to members on subscribe).
    pub content_key: ContentKey,
    /// ed25519 seed of the service signing key — `Some` for a `Service` (only the owner can
    /// broadcast), `None` for a `Channel` (members sign with their own identities).
    pub signing_seed: Option<[u8; 32]>,
}

impl ServiceConfig {
    /// Generate fresh keys for a new topic.
    pub fn new(kind: ServiceKind) -> Self {
        let mut content_key = [0u8; 32];
        OsRng.fill_bytes(&mut content_key);
        let signing_seed = match kind {
            ServiceKind::Service => {
                let mut s = [0u8; 32];
                OsRng.fill_bytes(&mut s);
                Some(s)
            }
            ServiceKind::Channel => None,
        };
        Self { kind, content_key, signing_seed }
    }

    /// The public key subscribers use to verify a *service's* broadcasts (`None` for a channel).
    pub fn service_pubkey(&self) -> Option<[u8; 32]> {
        self.signing_seed.map(|s| SigningKey::from_bytes(&s).verifying_key().to_bytes())
    }
}

/// Encrypt `plaintext` under the content `key`, returning `(nonce, ciphertext)`.
pub fn seal_content(key: &ContentKey, plaintext: &[u8]) -> ([u8; 12], Vec<u8>) {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let ct = cipher
        .encrypt(Nonce::from_slice(&nonce), plaintext)
        .expect("chacha20poly1305 encrypt");
    (nonce, ct)
}

/// Decrypt a content-keyed message; `None` if the key is wrong or the ciphertext was tampered.
pub fn open_content(key: &ContentKey, nonce: &[u8; 12], ciphertext: &[u8]) -> Option<Vec<u8>> {
    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    cipher.decrypt(Nonce::from_slice(nonce), ciphertext).ok()
}

/// The bytes a publish signature covers: the topic path, nonce, and ciphertext — so a signature
/// can't be replayed onto a different topic or ciphertext. Public so a channel member can sign
/// it with their own [`Identity`].
pub fn publish_signing_bytes(path: &str, nonce: &[u8; 12], ciphertext: &[u8]) -> Vec<u8> {
    publish_msg(path, nonce, ciphertext)
}

fn publish_msg(path: &str, nonce: &[u8; 12], ciphertext: &[u8]) -> Vec<u8> {
    let mut m = Vec::with_capacity(path.len() + 12 + ciphertext.len());
    m.extend_from_slice(path.as_bytes());
    m.extend_from_slice(nonce);
    m.extend_from_slice(ciphertext);
    m
}

/// Sign a published message with an ed25519 `seed` (the writer's identity for a channel, or the
/// service signing key for a service).
pub fn sign_publish(seed: &[u8; 32], path: &str, nonce: &[u8; 12], ciphertext: &[u8]) -> [u8; 64] {
    SigningKey::from_bytes(seed)
        .sign(&publish_msg(path, nonce, ciphertext))
        .to_bytes()
}

/// Verify a published message's signature against `pubkey` (the sender's address for a channel,
/// or the service's public key for a service broadcast).
pub fn verify_publish(
    pubkey: &[u8; 32],
    path: &str,
    nonce: &[u8; 12],
    ciphertext: &[u8],
    sig: &[u8; 64],
) -> bool {
    let Ok(vk) = VerifyingKey::from_bytes(pubkey) else {
        return false;
    };
    vk.verify(&publish_msg(path, nonce, ciphertext), &Signature::from_bytes(sig))
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn content_key_round_trips_and_rejects_wrong_key() {
        let cfg = ServiceConfig::new(ServiceKind::Channel);
        let (nonce, ct) = seal_content(&cfg.content_key, b"hello channel");
        assert_eq!(open_content(&cfg.content_key, &nonce, &ct).as_deref(), Some(&b"hello channel"[..]));
        let other = ServiceConfig::new(ServiceKind::Channel);
        assert_eq!(open_content(&other.content_key, &nonce, &ct), None, "wrong key can't read");
        // Tampered ciphertext fails the AEAD tag.
        let mut bad = ct.clone();
        bad[0] ^= 0xff;
        assert_eq!(open_content(&cfg.content_key, &nonce, &bad), None);
    }

    #[test]
    fn service_only_owner_signature_verifies() {
        let svc = ServiceConfig::new(ServiceKind::Service);
        let seed = svc.signing_seed.unwrap();
        let pubkey = svc.service_pubkey().unwrap();
        let (nonce, ct) = seal_content(&svc.content_key, b"broadcast");
        let sig = sign_publish(&seed, "news", &nonce, &ct);
        assert!(verify_publish(&pubkey, "news", &nonce, &ct, &sig));
        // A different signer (a subscriber who leaked-read the content key) can't forge.
        let imposter = ServiceConfig::new(ServiceKind::Service);
        let forged = sign_publish(&imposter.signing_seed.unwrap(), "news", &nonce, &ct);
        assert!(!verify_publish(&pubkey, "news", &nonce, &ct, &forged));
        // Signature is bound to the path + ciphertext.
        assert!(!verify_publish(&pubkey, "other", &nonce, &ct, &sig));
    }

    #[test]
    fn channel_has_no_service_key() {
        assert!(ServiceConfig::new(ServiceKind::Channel).service_pubkey().is_none());
        assert!(ServiceConfig::new(ServiceKind::Service).service_pubkey().is_some());
    }
}
