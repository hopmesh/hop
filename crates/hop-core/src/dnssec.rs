//! DNSSEC validation (DESIGN.md §30).
//!
//! This is the trust anchor for decentralized, multi-hop HNS: a `hops://` endpoint's address
//! comes from a `_hopaddress.<domain>` TXT record, and because *any* node in the mesh may
//! resolve and answer a query, the client must be able to verify the answer cryptographically
//! rather than trust whoever relayed it. We do that by validating the DNSSEC chain
//! (RRSIG → DNSKEY → DS → … → root) against a baked-in root trust anchor.
//!
//! Scope of this module: the verification primitives — RRSIG signature checking, DNSKEY key
//! tags, and DS digests — for **RSA/SHA-256 (algorithm 8)**, which is what the `.sh` / `hopme.sh`
//! / root chain uses today. ECDSA P-256 (alg 13) and Ed25519 (alg 15) are TODO. The chain
//! walk that strings these together up to [`ROOT_ANCHORS`] builds on top.

use rsa::{BigUint, Pkcs1v15Sign, RsaPublicKey};
use sha2::{Digest, Sha256};

/// DNSSEC algorithm numbers we recognize (IANA DNSSEC Algorithm Numbers).
pub const ALG_RSASHA256: u8 = 8;
pub const ALG_ECDSAP256SHA256: u8 = 13;
pub const ALG_ED25519: u8 = 15;

/// DS digest type 2 = SHA-256 (the only one we accept).
pub const DIGEST_SHA256: u8 = 2;

#[derive(Debug, PartialEq, Eq)]
pub enum DnssecError {
    /// Algorithm or digest type we don't implement yet.
    Unsupported(u8),
    /// A record/key/signature was malformed.
    Malformed(&'static str),
    /// The cryptographic signature did not verify.
    BadSignature,
    /// A DS digest didn't match the DNSKEY it should cover.
    DsMismatch,
    /// The chain didn't terminate at a configured root trust anchor.
    NoTrustAnchor,
    /// The signature is expired or not yet valid (compared to `now`).
    Expired,
}

/// A DNSKEY record's parsed fields (RFC 4034 §2.1). `public_key` is the raw key field.
#[derive(Clone, Debug)]
pub struct Dnskey {
    pub flags: u16,
    pub protocol: u8,
    pub algorithm: u8,
    pub public_key: Vec<u8>,
}

impl Dnskey {
    /// The full DNSKEY RDATA wire form (flags|proto|alg|publickey), used for the key tag and
    /// the DS digest.
    pub fn rdata(&self) -> Vec<u8> {
        let mut v = Vec::with_capacity(4 + self.public_key.len());
        v.extend_from_slice(&self.flags.to_be_bytes());
        v.push(self.protocol);
        v.push(self.algorithm);
        v.extend_from_slice(&self.public_key);
        v
    }

    /// The DNSKEY key tag (RFC 4034 Appendix B) — identifies which key an RRSIG used.
    pub fn key_tag(&self) -> u16 {
        let rdata = self.rdata();
        let mut ac: u32 = 0;
        for (i, b) in rdata.iter().enumerate() {
            ac += if i & 1 == 0 { (*b as u32) << 8 } else { *b as u32 };
        }
        ac += (ac >> 16) & 0xFFFF;
        (ac & 0xFFFF) as u16
    }

    /// Parse an RSA public key from the DNSKEY public-key field (RFC 3110): a 1- or 3-byte
    /// exponent length, the exponent, then the modulus.
    fn rsa_public_key(&self) -> Result<RsaPublicKey, DnssecError> {
        let k = &self.public_key;
        if k.is_empty() {
            return Err(DnssecError::Malformed("empty RSA key"));
        }
        let (exp_len, off) = if k[0] != 0 {
            (k[0] as usize, 1usize)
        } else {
            if k.len() < 3 {
                return Err(DnssecError::Malformed("short RSA key"));
            }
            (u16::from_be_bytes([k[1], k[2]]) as usize, 3usize)
        };
        if k.len() < off + exp_len + 1 {
            return Err(DnssecError::Malformed("truncated RSA key"));
        }
        let exponent = BigUint::from_bytes_be(&k[off..off + exp_len]);
        let modulus = BigUint::from_bytes_be(&k[off + exp_len..]);
        RsaPublicKey::new(modulus, exponent).map_err(|_| DnssecError::Malformed("bad RSA key"))
    }
}

/// A parsed RRSIG record (RFC 4034 §3.1). `signer_name`/`rrset_owner` are lowercase wire-form
/// names; `signature` is the raw signature bytes.
#[derive(Clone, Debug)]
pub struct Rrsig {
    pub type_covered: u16,
    pub algorithm: u8,
    pub labels: u8,
    pub original_ttl: u32,
    pub sig_expiration: u32,
    pub sig_inception: u32,
    pub key_tag: u16,
    pub signer_name: Vec<u8>, // canonical wire form
    pub signature: Vec<u8>,
}

/// One resource record in the covered RRset, in canonical form: lowercase wire-form `owner`
/// and raw `rdata` (RDATA only, no name compression).
#[derive(Clone, Debug)]
pub struct Rr {
    pub owner: Vec<u8>,
    pub rtype: u16,
    pub class: u16,
    pub rdata: Vec<u8>,
}

/// Build the data an RRSIG signs (RFC 4034 §3.1.8.1): the RRSIG RDATA (minus the signature)
/// followed by each RR in canonical order, each with the RRSIG's `original_ttl`.
fn signed_data(rrsig: &Rrsig, rrset: &[Rr]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&rrsig.type_covered.to_be_bytes());
    out.push(rrsig.algorithm);
    out.push(rrsig.labels);
    out.extend_from_slice(&rrsig.original_ttl.to_be_bytes());
    out.extend_from_slice(&rrsig.sig_expiration.to_be_bytes());
    out.extend_from_slice(&rrsig.sig_inception.to_be_bytes());
    out.extend_from_slice(&rrsig.key_tag.to_be_bytes());
    out.extend_from_slice(&rrsig.signer_name);

    // Canonical RR ordering is by RDATA bytes; for a single-record RRset (our case) it's moot,
    // but sort to be correct for multi-record sets.
    let mut sorted: Vec<&Rr> = rrset.iter().collect();
    sorted.sort_by(|a, b| a.rdata.cmp(&b.rdata));
    for rr in sorted {
        out.extend_from_slice(&rr.owner);
        out.extend_from_slice(&rr.rtype.to_be_bytes());
        out.extend_from_slice(&rr.class.to_be_bytes());
        out.extend_from_slice(&rrsig.original_ttl.to_be_bytes());
        out.extend_from_slice(&(rr.rdata.len() as u16).to_be_bytes());
        out.extend_from_slice(&rr.rdata);
    }
    out
}

/// Verify that `rrsig` over `rrset` was made by `key`. Checks the key tag matches, the
/// algorithm is supported, and the signature validates. (Validity-window checks are done by
/// the caller with a clock — see [`Rrsig::sig_inception`]/`sig_expiration`.)
pub fn verify_rrsig(rrset: &[Rr], rrsig: &Rrsig, key: &Dnskey) -> Result<(), DnssecError> {
    if key.key_tag() != rrsig.key_tag || key.algorithm != rrsig.algorithm {
        return Err(DnssecError::BadSignature);
    }
    let data = signed_data(rrsig, rrset);
    match rrsig.algorithm {
        ALG_RSASHA256 => {
            let pk = key.rsa_public_key()?;
            let digest = Sha256::digest(&data);
            pk.verify(Pkcs1v15Sign::new::<Sha256>(), &digest, &rrsig.signature)
                .map_err(|_| DnssecError::BadSignature)
        }
        other => Err(DnssecError::Unsupported(other)),
    }
}

/// Compute the DS digest (RFC 4034 §5.1.4) for a DNSKEY: `SHA-256(owner_wire || dnskey_rdata)`.
/// Compare against the parent's published DS to anchor the child key.
pub fn ds_digest(owner_wire: &[u8], key: &Dnskey, digest_type: u8) -> Result<Vec<u8>, DnssecError> {
    if digest_type != DIGEST_SHA256 {
        return Err(DnssecError::Unsupported(digest_type));
    }
    let mut h = Sha256::new();
    h.update(owner_wire);
    h.update(key.rdata());
    Ok(h.finalize().to_vec())
}

/// Encode a DNS name as lowercase, uncompressed wire form: each label length-prefixed, root 0.
/// `"hopme.sh"` → `05 'h''o''p''m''e' 02 's''h' 00`.
pub fn name_to_wire(name: &str) -> Vec<u8> {
    let mut out = Vec::new();
    for label in name.trim_end_matches('.').split('.') {
        if label.is_empty() {
            continue;
        }
        out.push(label.len() as u8);
        out.extend(label.bytes().map(|b| b.to_ascii_lowercase()));
    }
    out.push(0);
    out
}

/// TXT RDATA wire form for a single character-string: `<len><bytes>`.
pub fn txt_rdata(value: &str) -> Vec<u8> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(1 + bytes.len());
    out.push(bytes.len() as u8);
    out.extend_from_slice(bytes);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::STANDARD, Engine};

    fn b64(s: &str) -> Vec<u8> {
        STANDARD.decode(s.replace([' ', '\n'], "")).unwrap()
    }

    #[test]
    fn verifies_real_hopme_txt_rrsig() {
        // Real vectors pulled from the live, DNSSEC-signed hopme.sh zone (alg 8, RSA/SHA-256).
        // The hopme.sh ZSK (flags 256) signs _hopaddress.example.hopme.sh TXT.
        let zsk = Dnskey {
            flags: 256,
            protocol: 3,
            algorithm: 8,
            public_key: b64(
                "AwEAAdZm1zOo0FSOc/5gbJtNPoNpLmk8i3BvAUmgM//nsFHO68cVopMr\
                 jTEjmD+tb89QrEpmmATDEE3IqnalP1gaSGC+OferlNmCPFbuttNLCRf+\
                 XnKXbz9CJ/FUKWhCipRds8lBDVU/iTQbC4y0VHRZkr759yNXRHU1i/bN\
                 b3vptTKj",
            ),
        };
        // The signed key tag is 30700 — our independent computation must match.
        assert_eq!(zsk.key_tag(), 30700, "key tag from DNSKEY rdata");

        let rrsig = Rrsig {
            type_covered: 16, // TXT
            algorithm: 8,
            labels: 4, // _hopaddress.example.hopme.sh
            original_ttl: 300,
            sig_expiration: 1783834978, // 20260712054258 UTC
            sig_inception: 1781934178,  // 20260620054258 UTC
            key_tag: 30700,
            signer_name: name_to_wire("hopme.sh"),
            signature: b64(
                "rOfIOdr7ooOk0JK7SZbt71avK+VisW7mWtLt8oi7pbTcHwe6Tq5+PZog\
                 5ExVHe0EAqdXjGersLgue+z3hb75j/hNXvK/zKt2l2a+FFtwfVc9oUnx\
                 q5zh0c5Bz5CAjMeJ5lZvlRgiwbtTfGd0ezYDqgS8P0s1CyV9GCvbvElE\
                 LUI=",
            ),
        };

        let txt = Rr {
            owner: name_to_wire("_hopaddress.example.hopme.sh"),
            rtype: 16,
            class: 1,
            rdata: txt_rdata("J8XGeYT2VA3aq6KeP85LEujpAjg3LBbLLvivyoNFWTFr"),
        };

        verify_rrsig(&[txt], &rrsig, &zsk).expect("real DNSSEC RRSIG must verify");
    }

    #[test]
    fn rejects_tampered_record() {
        // Same as above but flip the TXT value → signature must fail.
        let zsk = Dnskey {
            flags: 256,
            protocol: 3,
            algorithm: 8,
            public_key: b64(
                "AwEAAdZm1zOo0FSOc/5gbJtNPoNpLmk8i3BvAUmgM//nsFHO68cVopMr\
                 jTEjmD+tb89QrEpmmATDEE3IqnalP1gaSGC+OferlNmCPFbuttNLCRf+\
                 XnKXbz9CJ/FUKWhCipRds8lBDVU/iTQbC4y0VHRZkr759yNXRHU1i/bN\
                 b3vptTKj",
            ),
        };
        let rrsig = Rrsig {
            type_covered: 16,
            algorithm: 8,
            labels: 4,
            original_ttl: 300,
            sig_expiration: 1783834978,
            sig_inception: 1781934178,
            key_tag: 30700,
            signer_name: name_to_wire("hopme.sh"),
            signature: b64(
                "rOfIOdr7ooOk0JK7SZbt71avK+VisW7mWtLt8oi7pbTcHwe6Tq5+PZog\
                 5ExVHe0EAqdXjGersLgue+z3hb75j/hNXvK/zKt2l2a+FFtwfVc9oUnx\
                 q5zh0c5Bz5CAjMeJ5lZvlRgiwbtTfGd0ezYDqgS8P0s1CyV9GCvbvElE\
                 LUI=",
            ),
        };
        let tampered = Rr {
            owner: name_to_wire("_hopaddress.example.hopme.sh"),
            rtype: 16,
            class: 1,
            rdata: txt_rdata("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
        };
        assert_eq!(
            verify_rrsig(&[tampered], &rrsig, &zsk),
            Err(DnssecError::BadSignature),
        );
    }
}
