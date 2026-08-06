//! Auth primitives, pure and vetted-crate-only. No hand-rolled crypto: passwords are argon2id (the
//! OWASP default) via RustCrypto, and every secret token (session, invite, email-verification,
//! password-reset) is 256 bits of OS entropy. These are the security-critical bytes of the console,
//! so they live in one small tested module the rest of the service calls into.

// Both the OsRng VALUE and the RngCore TRAIT come from argon2's re-exported rand_core, deliberately.
// They used to be split (OsRng from here, RngCore from the `rand` crate), which compiled only while
// the two crates happened to agree on a rand_core version. The password-hash 0.5 to 0.6 bump broke
// that: `OsRng` no longer implemented the `rand` trait, so `fill_bytes` vanished from a type that
// plainly had it. Taking both from one crate makes that skew unrepresentable.
use argon2::password_hash::rand_core::{OsRng, RngCore};
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;

/// The password length band. A 12-char floor (NIST/OWASP-aligned for a B2B product) and a hard cap so
/// a giant password can't turn argon2's deliberate slowness into a hashing-DoS.
pub const MIN_PASSWORD_LEN: usize = 12;
pub const MAX_PASSWORD_LEN: usize = 200;

/// Reject a password that violates the length policy, returning a user-facing reason, else `None`.
/// Kept intentionally minimal (length only): composition rules push users toward predictable patterns
/// and are weaker than length, so we gate on length and lean on the hash + rate limiting elsewhere.
pub fn password_policy_error(password: &str) -> Option<&'static str> {
    let len = password.chars().count();
    if len < MIN_PASSWORD_LEN {
        return Some("password must be at least 12 characters");
    }
    if len > MAX_PASSWORD_LEN {
        return Some("password must be at most 200 characters");
    }
    None
}

/// Hash a password with argon2id (default RustCrypto params) into a self-describing PHC string, which
/// carries its own random salt + parameters so [`verify_password`] needs nothing else stored. Errors
/// only on an internal hashing failure (effectively never); the caller should still enforce
/// [`password_policy_error`] first.
pub fn hash_password(password: &str) -> Result<String, String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| format!("password hash: {e}"))
}

/// Verify a password against a stored PHC hash in constant time (argon2's verifier). A malformed hash
/// string verifies to `false` rather than erroring, so a corrupt row can't be a login bypass or a
/// panic.
pub fn verify_password(password: &str, phc: &str) -> bool {
    match PasswordHash::new(phc) {
        Ok(parsed) => Argon2::default()
            .verify_password(password.as_bytes(), &parsed)
            .is_ok(),
        Err(_) => false,
    }
}

/// A fresh 256-bit secret token as 64 lowercase-hex chars, from the OS CSPRNG. Used for session ids,
/// invite tokens, email-verification tokens, and password-reset tokens. Hex (not base64) so it is
/// URL-safe and case-insensitive with no padding surprises in emailed links.
pub fn generate_token() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Compare two tokens (a presented one vs. a stored one) in constant time, so token verification does
/// not leak length-prefix matches through timing. Both are expected to be the 64-hex `generate_token`
/// shape; a length mismatch is a definite non-match.
pub fn tokens_match(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn password_round_trips_and_rejects_wrong_and_tampered() {
        let hash = hash_password("correct horse battery staple").unwrap();
        assert!(verify_password("correct horse battery staple", &hash));
        assert!(!verify_password("wrong password entirely", &hash));
        // A corrupt/garbage hash string is a non-match, never a panic or a bypass.
        assert!(!verify_password("anything", "$argon2id$notarealhash"));
        assert!(!verify_password("anything", ""));
    }

    #[test]
    fn hashing_is_salted_so_the_same_password_yields_distinct_hashes() {
        let a = hash_password("a-sufficiently-long-password").unwrap();
        let b = hash_password("a-sufficiently-long-password").unwrap();
        assert_ne!(a, b, "each hash carries a fresh random salt");
        assert!(verify_password("a-sufficiently-long-password", &a));
        assert!(verify_password("a-sufficiently-long-password", &b));
    }

    #[test]
    fn policy_enforces_the_length_band() {
        assert_eq!(
            password_policy_error("short"),
            Some("password must be at least 12 characters")
        );
        assert_eq!(password_policy_error("exactly12chr"), None); // 12 chars
        assert!(password_policy_error(&"x".repeat(201)).is_some());
    }

    #[test]
    fn tokens_are_256_bit_hex_and_unique() {
        let t = generate_token();
        assert_eq!(t.len(), 64, "32 bytes as hex");
        assert!(t.bytes().all(|b| b.is_ascii_hexdigit()));
        assert_ne!(generate_token(), generate_token());
    }

    #[test]
    fn token_compare_is_length_checked_and_matches_only_equal() {
        let t = generate_token();
        assert!(tokens_match(&t, &t.clone()));
        assert!(!tokens_match(&t, &generate_token()));
        assert!(!tokens_match("abc", "abcd"));
    }
}
