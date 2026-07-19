//! Passwordless auth: a magic-link [`LoginToken`] (emailed, single-use, short-lived) redeems into a
//! [`Session`]. There is one code path for signup and login: redeeming a link creates the account on
//! first sight or signs an existing user in, so there is no "email is taken", no "unknown email", and
//! no enumeration signal (see the console mock's unified flow). GitHub OAuth lands in a later phase as
//! a second entry into the same session issuance.
//!
//! Secrets never rest in the clear: the 256-bit CSPRNG login token and session id are stored only as
//! their SHA-256 hash; the raw value lives solely in the emailed link and the `HttpOnly` cookie.

use crate::auth;
use crate::domain::User;
use crate::store::{Store, StoreError, StoreResult};
use serde::{Deserialize, Serialize};

/// How long an emailed sign-in link is valid. Short: it is a bearer credential in an inbox.
pub const LOGIN_TOKEN_TTL_MS: u64 = 15 * 60 * 1000;
/// How long a session lasts before re-authentication. Rolling refresh can extend this later.
pub const SESSION_TTL_MS: u64 = 30 * 24 * 60 * 60 * 1000;
/// The session cookie name. The `__Host-` prefix binds it to this exact host at the browser level
/// (host-only scope, `Path=/`, `Secure` required), so a sibling/parent-domain `Set-Cookie` cannot
/// plant or fixate a `hop_session` the console would honor. Requires HTTPS (or a localhost secure
/// context in dev).
pub const SESSION_COOKIE: &str = "__Host-hop_session";

/// A pending magic-link login. Keyed by `token_hash`; the raw token is only ever in the email link.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LoginToken {
    pub token_hash: String,
    /// Normalized (trimmed, lowercased) address the link was sent to.
    pub email: String,
    pub created_ms: u64,
    pub expires_ms: u64,
}

/// An authenticated session. Keyed by `id_hash`; the raw id is only ever in the cookie.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Session {
    pub id_hash: String,
    pub user_id: String,
    pub created_ms: u64,
    pub expires_ms: u64,
}

/// SHA-256 (hex) of a raw secret, the at-rest form of every login token and session id.
pub fn hash_token(raw: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(raw.as_bytes());
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// Canonical form of an email for storage + lookup: trimmed and lowercased, so `A@X.co ` and `a@x.co`
/// are one account and one uniqueness key.
pub fn normalize_email(email: &str) -> String {
    email.trim().to_lowercase()
}

/// A deliberately permissive shape check (one `@`, non-empty local part, a dotted domain, no spaces).
/// Real deliverability is proven by the link click, not by a regex, so this only rejects the obviously
/// malformed before we spend an email send.
pub fn is_valid_email(email: &str) -> bool {
    let e = email.trim();
    if e.len() > 254 || e.contains(char::is_whitespace) {
        return false;
    }
    let mut parts = e.split('@');
    let (Some(local), Some(domain), None) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    !local.is_empty() && domain.contains('.') && !domain.starts_with('.') && !domain.ends_with('.')
}

/// The raw sign-in link material handed back to the caller to email. The console never logs or stores
/// `raw`; only its hash was persisted.
pub struct RawLogin {
    pub raw: String,
    pub email: String,
    pub expires_ms: u64,
}

/// Mint a sign-in link for `email` and persist only its hash. No user is created and no existing-user
/// signal is returned, so calling this reveals nothing about whether the address has an account. The
/// caller must have already checked [`is_valid_email`]; `email` is normalized here.
pub fn request_login(store: &dyn Store, email: &str, now_ms: u64) -> StoreResult<RawLogin> {
    let email = normalize_email(email);
    let raw = auth::generate_token();
    let token = LoginToken {
        token_hash: hash_token(&raw),
        email: email.clone(),
        created_ms: now_ms,
        expires_ms: now_ms + LOGIN_TOKEN_TTL_MS,
    };
    store.create_login_token(&token)?;
    Ok(RawLogin {
        raw,
        email,
        expires_ms: token.expires_ms,
    })
}

/// The result of a successful redeem: the (possibly just-created) user, the raw session id to set as a
/// cookie, and whether this click created the account.
pub struct LoggedIn {
    pub user: User,
    pub session_raw: String,
    pub session_expires_ms: u64,
    pub created: bool,
}

/// Redeem a raw sign-in link. Returns `Ok(None)` for an unknown, already-consumed, or expired token
/// (the caller shows "this link is no longer valid, request a new one", never distinguishing the
/// cases). On success it consumes the token (single-use), creates the user on first login or finds the
/// existing one, marks the address verified (the click proves inbox control), and issues a session.
pub fn redeem_login(
    store: &dyn Store,
    raw_token: &str,
    now_ms: u64,
) -> StoreResult<Option<LoggedIn>> {
    // Consume first: `take` deletes the row, so a double-click cannot mint two sessions from one link.
    let Some(tok) = store.take_login_token(&hash_token(raw_token))? else {
        return Ok(None);
    };
    if tok.expires_ms <= now_ms {
        return Ok(None);
    }
    login_or_create(store, &tok.email, now_ms).map(Some)
}

/// The shared create-or-sign-in core behind every VERIFIED identity proof (a clicked magic link, a
/// completed OAuth exchange): find or race-safely create the user for `email` (already normalized),
/// mark the address verified, and issue a session. Callers must only invoke this once the caller has
/// PROVEN control of `email`; nothing here re-checks that.
pub fn login_or_create(store: &dyn Store, email: &str, now_ms: u64) -> StoreResult<LoggedIn> {
    let (mut user, created) = match store.user_by_email(email)? {
        Some(u) => (u, false),
        None => {
            let u = User {
                id: auth::generate_token(),
                email: email.to_string(),
                password_hash: String::new(), // passwordless; a password may be set later, optionally
                email_verified: true,
                created_ms: now_ms,
            };
            match store.create_user(&u) {
                Ok(()) => (u, true),
                // Lost a create race: a concurrent login for this same new address committed the
                // account first. Continue idempotently as that existing user rather than surfacing
                // the store's Conflict, which login must never leak (store.rs).
                Err(StoreError::Conflict(_)) => {
                    let existing = store.user_by_email(email)?.ok_or(StoreError::NotFound)?;
                    (existing, false)
                }
                Err(e) => return Err(e),
            }
        }
    };
    if !user.email_verified {
        store.mark_email_verified(&user.id)?;
        user.email_verified = true;
    }
    // Every signed-in user lands in a workspace they own (created on first login, no-op thereafter),
    // so there is no empty-account state and no org setup step (the approachable flow).
    crate::orgs::ensure_personal_workspace(store, &user.id, &user.email, now_ms)?;
    let session_raw = auth::generate_token();
    let sess = Session {
        id_hash: hash_token(&session_raw),
        user_id: user.id.clone(),
        created_ms: now_ms,
        expires_ms: now_ms + SESSION_TTL_MS,
    };
    store.create_session(&sess)?;
    Ok(LoggedIn {
        user,
        session_raw,
        session_expires_ms: sess.expires_ms,
        created,
    })
}

/// Resolve a session cookie to its user, or `None` if the cookie is unknown or the session has
/// expired. Expiry is enforced at read time here, independent of the periodic GC sweep.
pub fn validate_session(
    store: &dyn Store,
    raw_cookie: &str,
    now_ms: u64,
) -> StoreResult<Option<User>> {
    let Some(sess) = store.session_by_id_hash(&hash_token(raw_cookie))? else {
        return Ok(None);
    };
    if sess.expires_ms <= now_ms {
        return Ok(None);
    }
    store.user_by_id(&sess.user_id)
}

/// Invalidate a session (sign out). Idempotent: signing out an already-gone session is `Ok`.
pub fn logout(store: &dyn Store, raw_cookie: &str) -> StoreResult<()> {
    store.delete_session(&hash_token(raw_cookie))
}

/// The `Set-Cookie` value that plants a session. `HttpOnly` (no JS access), `SameSite=Lax` (survives
/// top-level navigation from the email link while blocking cross-site POST), `Secure`, `Path=/`.
pub fn set_cookie(raw: &str, max_age_secs: u64) -> String {
    format!(
        "{SESSION_COOKIE}={raw}; Max-Age={max_age_secs}; Path=/; HttpOnly; SameSite=Lax; Secure"
    )
}

/// The `Set-Cookie` value that clears the session on logout.
pub fn clear_cookie() -> String {
    format!("{SESSION_COOKIE}=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax; Secure")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemStore;

    const T0: u64 = 1_000_000;

    #[test]
    fn hash_is_deterministic_and_distinguishing() {
        assert_eq!(hash_token("abc"), hash_token("abc"));
        assert_ne!(hash_token("abc"), hash_token("abd"));
        assert_eq!(hash_token("abc").len(), 64); // sha256 hex
    }

    #[test]
    fn email_normalize_and_validate() {
        assert_eq!(normalize_email("  A@X.Co "), "a@x.co");
        assert!(is_valid_email("dev@hopme.sh"));
        assert!(!is_valid_email("nope"));
        assert!(!is_valid_email("a@b")); // no dot in domain
        assert!(!is_valid_email("a b@x.co")); // whitespace
        assert!(!is_valid_email("a@@x.co")); // two @
        assert!(!is_valid_email("@x.co")); // empty local
    }

    #[test]
    fn first_login_creates_account_and_signs_in() {
        let s = MemStore::new();
        let link = request_login(&s, "Dev@Hopme.sh", T0).unwrap();
        assert_eq!(link.email, "dev@hopme.sh");
        let out = redeem_login(&s, &link.raw, T0 + 1000).unwrap().unwrap();
        assert!(out.created, "new email creates the account");
        assert!(out.user.email_verified, "the click verifies the address");
        assert_eq!(out.user.email, "dev@hopme.sh");
        // the session resolves back to the same user
        let who = validate_session(&s, &out.session_raw, T0 + 2000)
            .unwrap()
            .unwrap();
        assert_eq!(who.id, out.user.id);
    }

    #[test]
    fn second_login_for_same_email_signs_in_not_duplicates() {
        let s = MemStore::new();
        let first = redeem_login(&s, &request_login(&s, "a@x.co", T0).unwrap().raw, T0)
            .unwrap()
            .unwrap();
        // a brand-new link for the SAME address
        let second = redeem_login(&s, &request_login(&s, "a@x.co", T0).unwrap().raw, T0)
            .unwrap()
            .unwrap();
        assert!(!second.created, "existing email signs in, no duplicate");
        assert_eq!(first.user.id, second.user.id);
    }

    #[test]
    fn link_is_single_use() {
        let s = MemStore::new();
        let link = request_login(&s, "a@x.co", T0).unwrap();
        assert!(redeem_login(&s, &link.raw, T0).unwrap().is_some());
        // a replay of the same link mints nothing
        assert!(redeem_login(&s, &link.raw, T0).unwrap().is_none());
    }

    #[test]
    fn expired_link_creates_nothing() {
        let s = MemStore::new();
        let link = request_login(&s, "new@x.co", T0).unwrap();
        let expired_at = T0 + LOGIN_TOKEN_TTL_MS + 1;
        assert!(redeem_login(&s, &link.raw, expired_at).unwrap().is_none());
        // and the account was NOT created off an expired link
        assert!(s.user_by_email("new@x.co").unwrap().is_none());
    }

    #[test]
    fn unknown_and_logged_out_sessions_do_not_resolve() {
        let s = MemStore::new();
        assert!(redeem_login(&s, "garbage", T0).unwrap().is_none());
        let out = redeem_login(&s, &request_login(&s, "a@x.co", T0).unwrap().raw, T0)
            .unwrap()
            .unwrap();
        assert!(validate_session(&s, "not-a-real-cookie", T0)
            .unwrap()
            .is_none());
        logout(&s, &out.session_raw).unwrap();
        assert!(validate_session(&s, &out.session_raw, T0)
            .unwrap()
            .is_none());
        logout(&s, &out.session_raw).unwrap(); // idempotent
    }

    #[test]
    fn expired_session_does_not_resolve() {
        let s = MemStore::new();
        let out = redeem_login(&s, &request_login(&s, "a@x.co", T0).unwrap().raw, T0)
            .unwrap()
            .unwrap();
        assert!(
            validate_session(&s, &out.session_raw, out.session_expires_ms + 1)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn cookie_attributes_are_hardened() {
        let c = set_cookie("abc", 100);
        assert!(c.starts_with("__Host-hop_session=abc;"));
        for attr in [
            "HttpOnly",
            "SameSite=Lax",
            "Secure",
            "Path=/",
            "Max-Age=100",
        ] {
            assert!(c.contains(attr), "cookie missing {attr}");
        }
        assert!(clear_cookie().contains("Max-Age=0"));
    }

    /// A `Store` that reproduces the create-race: `user_by_email` reports "absent" on its FIRST call
    /// (so `redeem_login` enters the create branch) while the account actually exists in the inner
    /// store (so `create_user` returns `Conflict` and the re-fetch finds it). Two concurrent redeems
    /// of distinct valid links for the same brand-new address, made deterministic.
    struct RaceStore {
        inner: MemStore,
        first_lookup: std::sync::atomic::AtomicBool,
    }
    impl RaceStore {
        fn new() -> Self {
            Self {
                inner: MemStore::new(),
                first_lookup: std::sync::atomic::AtomicBool::new(true),
            }
        }
    }
    impl Store for RaceStore {
        fn user_by_email(&self, email: &str) -> StoreResult<Option<User>> {
            if self
                .first_lookup
                .swap(false, std::sync::atomic::Ordering::SeqCst)
            {
                return Ok(None); // the race winner has not "committed" from this reader's view yet
            }
            self.inner.user_by_email(email)
        }
        fn create_user(&self, u: &User) -> StoreResult<()> {
            self.inner.create_user(u)
        }
        fn user_by_id(&self, id: &str) -> StoreResult<Option<User>> {
            self.inner.user_by_id(id)
        }
        fn mark_email_verified(&self, id: &str) -> StoreResult<()> {
            self.inner.mark_email_verified(id)
        }
        fn create_org(&self, o: &crate::domain::Org) -> StoreResult<()> {
            self.inner.create_org(o)
        }
        fn org_by_id(&self, id: &str) -> StoreResult<Option<crate::domain::Org>> {
            self.inner.org_by_id(id)
        }
        fn org_by_tenant(&self, t: &str) -> StoreResult<Option<crate::domain::Org>> {
            self.inner.org_by_tenant(t)
        }
        fn all_orgs(&self) -> StoreResult<Vec<crate::domain::Org>> {
            self.inner.all_orgs()
        }
        fn set_org_stripe_customer(&self, o: &str, c: &str) -> StoreResult<()> {
            self.inner.set_org_stripe_customer(o, c)
        }
        fn set_org_carriage_pubkey(&self, o: &str, k: &str) -> StoreResult<()> {
            self.inner.set_org_carriage_pubkey(o, k)
        }
        fn set_org_otlp_endpoint(&self, o: &str, e: &str) -> StoreResult<()> {
            self.inner.set_org_otlp_endpoint(o, e)
        }
        fn add_membership(&self, m: &crate::domain::Membership) -> StoreResult<()> {
            self.inner.add_membership(m)
        }
        fn membership(&self, u: &str, o: &str) -> StoreResult<Option<crate::domain::Membership>> {
            self.inner.membership(u, o)
        }
        fn members_of_org(&self, o: &str) -> StoreResult<Vec<crate::domain::Membership>> {
            self.inner.members_of_org(o)
        }
        fn memberships_for_user(&self, u: &str) -> StoreResult<Vec<crate::domain::Membership>> {
            self.inner.memberships_for_user(u)
        }
        fn set_role(&self, u: &str, o: &str, r: crate::domain::Role) -> StoreResult<()> {
            self.inner.set_role(u, o, r)
        }
        fn remove_membership(&self, u: &str, o: &str) -> StoreResult<()> {
            self.inner.remove_membership(u, o)
        }
        fn try_set_role(&self, u: &str, o: &str, r: crate::domain::Role) -> StoreResult<bool> {
            self.inner.try_set_role(u, o, r)
        }
        fn try_remove_member(&self, u: &str, o: &str) -> StoreResult<bool> {
            self.inner.try_remove_member(u, o)
        }
        fn create_invite(&self, i: &crate::domain::Invite) -> StoreResult<()> {
            self.inner.create_invite(i)
        }
        fn invite_by_token_hash(&self, h: &str) -> StoreResult<Option<crate::domain::Invite>> {
            self.inner.invite_by_token_hash(h)
        }
        fn delete_invite(&self, o: &str, e: &str) -> StoreResult<()> {
            self.inner.delete_invite(o, e)
        }
        fn create_login_token(&self, t: &LoginToken) -> StoreResult<()> {
            self.inner.create_login_token(t)
        }
        fn take_login_token(&self, h: &str) -> StoreResult<Option<LoginToken>> {
            self.inner.take_login_token(h)
        }
        fn create_session(&self, s: &Session) -> StoreResult<()> {
            self.inner.create_session(s)
        }
        fn session_by_id_hash(&self, h: &str) -> StoreResult<Option<Session>> {
            self.inner.session_by_id_hash(h)
        }
        fn delete_session(&self, h: &str) -> StoreResult<()> {
            self.inner.delete_session(h)
        }
        fn delete_expired(&self, now: u64) -> StoreResult<u64> {
            self.inner.delete_expired(now)
        }
    }

    #[test]
    fn redeem_survives_a_lost_create_race() {
        let s = RaceStore::new();
        // The "winner" already committed the account for this address.
        s.inner
            .create_user(&User {
                id: "winner".into(),
                email: "race@x.co".into(),
                password_hash: String::new(),
                email_verified: true,
                created_ms: T0,
            })
            .unwrap();
        // Our redeem of a distinct valid link sees None first, hits create_user Conflict, recovers as
        // the existing user rather than surfacing an error.
        let link = request_login(&s, "race@x.co", T0).unwrap();
        let out = redeem_login(&s, &link.raw, T0).unwrap().unwrap();
        assert!(!out.created, "a lost create race resolves to signing in");
        assert_eq!(out.user.id, "winner");
    }
}
