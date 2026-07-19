//! The public passwordless-auth surface, pure like `api.rs`: route parsing, cookie/body parsing,
//! rate limiting, and handlers that compose [`crate::session`] over a [`Store`] and an
//! [`EmailSender`], returning a plain [`AuthResponse`] the socket layer writes out. No sockets, no
//! network, so every auth decision is unit-tested.
//!
//! Unlike `/v1/*` (operator bearer token), these routes are USER-facing and carry no bearer gate:
//!   POST /auth/request-link  {"email": "..."}   -> 202 always (no enumeration), rate-limited
//!   POST /auth/redeem        {"token": "..."}   -> 200 + session cookie, or 410 link_invalid
//!   POST /auth/logout                            -> 204 + clearing cookie (idempotent)
//!   GET  /auth/me                                -> 200 {user} or 401
//!
//! Redeem is POST on purpose: the emailed URL lands on a console PAGE (a safe GET), and only a human
//! click POSTs the single-use token here, so mail-scanner prefetch cannot consume the link (see
//! `email.rs`). CSRF: state-changing routes are JSON-body POSTs (no form encoding), and the session
//! cookie is `SameSite=Lax`, so a cross-site form cannot replay them.

use crate::email::{login_link_url, magic_link_email, EmailSender, OutboundEmail};
use crate::session::{
    self, is_valid_email, normalize_email, LOGIN_TOKEN_TTL_MS, SESSION_COOKIE, SESSION_TTL_MS,
};
use crate::store::Store;
use std::collections::HashMap;
use std::sync::Mutex;

/// The parsed intent of one auth request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthRoute {
    RequestLink,
    Redeem,
    Logout,
    Me,
    NotFound,
}

/// Parse method + path into an [`AuthRoute`]. Strict, like `api.rs::parse_route`.
pub fn parse_auth_route(method: &str, path: &str) -> AuthRoute {
    let path = path.split(['?', '#']).next().unwrap_or("");
    let post = method.eq_ignore_ascii_case("POST");
    let get = method.eq_ignore_ascii_case("GET");
    match path.trim_end_matches('/') {
        "/auth/request-link" if post => AuthRoute::RequestLink,
        "/auth/redeem" if post => AuthRoute::Redeem,
        "/auth/logout" if post => AuthRoute::Logout,
        "/auth/me" if get => AuthRoute::Me,
        _ => AuthRoute::NotFound,
    }
}

/// A pure HTTP response: status, optional `Set-Cookie`, JSON body. The socket layer adds the rest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthResponse {
    pub status: u16,
    pub set_cookie: Option<String>,
    pub body: String,
}

impl AuthResponse {
    fn json(status: u16, body: &str) -> AuthResponse {
        AuthResponse {
            status,
            set_cookie: None,
            body: body.to_string(),
        }
    }
}

/// Extract the raw session id from a `Cookie` header, tolerating other cookies around ours.
pub fn session_from_cookie_header(header: Option<&str>) -> Option<String> {
    let h = header?;
    for part in h.split(';') {
        let part = part.trim();
        if let Some(v) = part.strip_prefix(SESSION_COOKIE) {
            if let Some(v) = v.strip_prefix('=') {
                if !v.is_empty() {
                    return Some(v.to_string());
                }
            }
        }
    }
    None
}

/// The client identity used for per-peer limiting. On Cloud Run (and behind the LB) the platform
/// APPENDS the real client address as the LAST `X-Forwarded-For` entry; anything earlier is
/// client-supplied and spoofable, so only the last entry counts. Absent the header (direct/dev),
/// fall back to the socket peer with its port stripped.
pub fn peer_identity(xff: Option<&str>, socket_peer: &str) -> String {
    if let Some(last) = xff
        .and_then(|h| h.split(',').next_back())
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        return last.to_string();
    }
    socket_peer
        .rsplit_once(':')
        .map(|(host, _port)| host)
        .unwrap_or(socket_peer)
        .to_string()
}

/// Pull a single string field out of a small JSON body (`{"email": "..."}`) without exposing the
/// whole serde surface to attacker-shaped input: parse strictly, reject non-objects.
pub fn json_field(body: &str, field: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    v.as_object()?.get(field)?.as_str().map(str::to_string)
}

/// A fixed-window rate limiter, pure against an injected clock. One instance per (route, key kind);
/// keys are normalized emails or peer addresses. HARD-bounded at `MAX_KEYS`: when the map is full,
/// expired windows are pruned, and if the map is STILL full a brand-new key is denied outright
/// (fail-closed). A within-window spray of distinct keys therefore caps both memory and throughput
/// at `MAX_KEYS`; it cannot grow the map or evict live windows.
pub struct RateLimiter {
    max_per_window: u32,
    window_ms: u64,
    hits: Mutex<HashMap<String, (u64, u32)>>, // key -> (window start, count)
}

const MAX_KEYS: usize = 10_000;

impl RateLimiter {
    pub fn new(max_per_window: u32, window_ms: u64) -> RateLimiter {
        RateLimiter {
            max_per_window,
            window_ms,
            hits: Mutex::new(HashMap::new()),
        }
    }

    /// Record a hit for `key` at `now_ms`; `true` if it is within the limit, `false` if throttled.
    pub fn allow(&self, key: &str, now_ms: u64) -> bool {
        let mut g = self.hits.lock().unwrap();
        if g.len() >= MAX_KEYS && !g.contains_key(key) {
            let w = self.window_ms;
            g.retain(|_, (start, _)| now_ms.saturating_sub(*start) < w);
            if g.len() >= MAX_KEYS {
                // Full of LIVE windows: deny the new key rather than growing without bound or
                // evicting someone's active window. Existing keys keep working.
                return false;
            }
        }
        let e = g.entry(key.to_string()).or_insert((now_ms, 0));
        if now_ms.saturating_sub(e.0) >= self.window_ms {
            *e = (now_ms, 0);
        }
        e.1 += 1;
        e.1 <= self.max_per_window
    }

    /// Give back one hit for `key` in its current window (floor 0). Used when the guarded action
    /// FAILED for reasons unrelated to the caller (an email-provider outage must not burn the
    /// caller's few attempts and lock them out for the window).
    pub fn refund(&self, key: &str, now_ms: u64) {
        let mut g = self.hits.lock().unwrap();
        if let Some(e) = g.get_mut(key) {
            if now_ms.saturating_sub(e.0) < self.window_ms {
                e.1 = e.1.saturating_sub(1);
            }
        }
    }
}

/// Production defaults. Per-address: 3 links per token-TTL window, so at most ~3 live links exist
/// per address. Per-peer: a coarser cap on distinct-address sends from one peer, the anti-spam /
/// anti-relay control; it is a REQUIRED argument to [`handle_request_link`] so no socket wiring can
/// ship without it.
pub const REQUEST_LINK_MAX_PER_EMAIL: u32 = 3;
pub const REQUEST_LINK_WINDOW_MS: u64 = LOGIN_TOKEN_TTL_MS;
pub const REQUEST_LINK_MAX_PER_PEER: u32 = 12;

/// POST /auth/request-link. Always 202 for a well-formed address, whether or not an account exists
/// (no enumeration; the email itself is the only difference). 400 is purely a shape error, 429 is
/// volume; neither depends on account existence. `peer` is the caller's network identity (the
/// LB-provided client address); the per-peer limiter is what stops one host from spraying sign-in
/// mail at arbitrary inboxes, so it is a required argument, not an optional socket-layer nicety.
#[allow(clippy::too_many_arguments)]
pub fn handle_request_link(
    store: &dyn Store,
    email_limiter: &RateLimiter,
    peer_limiter: &RateLimiter,
    peer: &str,
    sender: &dyn EmailSender,
    console_base: &str,
    body: &str,
    now_ms: u64,
) -> AuthResponse {
    let Some(email) = json_field(body, "email") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    if !is_valid_email(&email) {
        return AuthResponse::json(400, r#"{"error":"invalid_email"}"#);
    }
    if !peer_limiter.allow(peer, now_ms) {
        return AuthResponse::json(429, r#"{"error":"slow_down"}"#);
    }
    let key = normalize_email(&email);
    if !email_limiter.allow(&key, now_ms) {
        return AuthResponse::json(429, r#"{"error":"slow_down"}"#);
    }
    let link = match session::request_login(store, &email, now_ms) {
        Ok(l) => l,
        Err(_) => return AuthResponse::json(500, r#"{"error":"internal"}"#),
    };
    let msg: OutboundEmail = magic_link_email(
        &link.email,
        &login_link_url(console_base, &link.raw),
        LOGIN_TOKEN_TTL_MS / 60_000,
    );
    if sender.send(&msg).is_err() {
        // The send failed AFTER minting; the token simply expires unused (only its hash is stored).
        // Refund both rate-limit hits: a provider outage must not consume the caller's attempts and
        // lock them out for the window. Surface a retryable error rather than a silent 202.
        email_limiter.refund(&key, now_ms);
        peer_limiter.refund(peer, now_ms);
        return AuthResponse::json(502, r#"{"error":"email_failed"}"#);
    }
    AuthResponse::json(202, r#"{"ok":true}"#)
}

/// POST /auth/redeem. One outcome for unknown, consumed, and expired links (410), so nothing about
/// prior state leaks; success plants the session cookie.
pub fn handle_redeem(store: &dyn Store, body: &str, now_ms: u64) -> AuthResponse {
    let Some(token) = json_field(body, "token") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    match session::redeem_login(store, &token, now_ms) {
        Ok(Some(out)) => AuthResponse {
            status: 200,
            set_cookie: Some(session::set_cookie(&out.session_raw, SESSION_TTL_MS / 1000)),
            body: format!(
                r#"{{"ok":true,"created":{},"email":{}}}"#,
                out.created,
                serde_json::Value::String(out.user.email)
            ),
        },
        Ok(None) => AuthResponse::json(410, r#"{"error":"link_invalid"}"#),
        Err(_) => AuthResponse::json(500, r#"{"error":"internal"}"#),
    }
}

/// POST /auth/logout. Idempotent for any request that PRESENTS our cookie (stale or live, it gets
/// cleared and the session deleted). A request with no cookie gets a bare 204 with NO `Set-Cookie`:
/// under `SameSite=Lax` a cross-site form POST arrives cookieless, and answering it with a clearing
/// `Set-Cookie` would let any third-party page force-log-out a visitor (a CSRF nuisance).
pub fn handle_logout(store: &dyn Store, cookie_header: Option<&str>) -> AuthResponse {
    let Some(raw) = session_from_cookie_header(cookie_header) else {
        return AuthResponse {
            status: 204,
            set_cookie: None,
            body: String::new(),
        };
    };
    let _ = session::logout(store, &raw);
    AuthResponse {
        status: 204,
        set_cookie: Some(session::clear_cookie()),
        body: String::new(),
    }
}

/// GET /auth/me. The session probe the frontend calls on load.
pub fn handle_me(store: &dyn Store, cookie_header: Option<&str>, now_ms: u64) -> AuthResponse {
    let Some(raw) = session_from_cookie_header(cookie_header) else {
        return AuthResponse::json(401, r#"{"error":"unauthenticated"}"#);
    };
    match session::validate_session(store, &raw, now_ms) {
        Ok(Some(user)) => AuthResponse::json(
            200,
            &format!(
                r#"{{"id":{},"email":{},"email_verified":{}}}"#,
                serde_json::Value::String(user.id),
                serde_json::Value::String(user.email),
                user.email_verified
            ),
        ),
        Ok(None) => AuthResponse::json(401, r#"{"error":"unauthenticated"}"#),
        Err(_) => AuthResponse::json(500, r#"{"error":"internal"}"#),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemStore;
    use std::sync::Mutex as StdMutex;

    const T0: u64 = 1_000_000;
    const BASE: &str = "https://dashboard.hopme.sh";

    /// Records outbound emails; can be told to fail.
    #[derive(Default)]
    struct FakeSender {
        sent: StdMutex<Vec<OutboundEmail>>,
        fail: bool,
    }
    impl EmailSender for FakeSender {
        fn send(&self, msg: &OutboundEmail) -> Result<(), String> {
            if self.fail {
                return Err("down".into());
            }
            self.sent.lock().unwrap().push(msg.clone());
            Ok(())
        }
    }

    fn limiter() -> RateLimiter {
        RateLimiter::new(REQUEST_LINK_MAX_PER_EMAIL, REQUEST_LINK_WINDOW_MS)
    }

    fn peer_limiter() -> RateLimiter {
        RateLimiter::new(REQUEST_LINK_MAX_PER_PEER, REQUEST_LINK_WINDOW_MS)
    }

    /// The full request-link call with one email limiter and a fresh, roomy peer limiter.
    #[allow(clippy::too_many_arguments)]
    fn req(
        store: &dyn Store,
        lim: &RateLimiter,
        peers: &RateLimiter,
        sender: &dyn EmailSender,
        body: &str,
        now: u64,
    ) -> AuthResponse {
        handle_request_link(store, lim, peers, "9.9.9.9", sender, BASE, body, now)
    }

    /// Pull the raw token back out of the emailed link.
    fn token_from(sender: &FakeSender) -> String {
        let sent = sender.sent.lock().unwrap();
        let text = &sent.last().expect("an email was sent").text;
        let url = text
            .lines()
            .find(|l| l.contains("/auth/link#token="))
            .expect("link line");
        url.split("token=").nth(1).unwrap().trim().to_string()
    }

    #[test]
    fn routes_parse_strictly() {
        assert_eq!(
            parse_auth_route("POST", "/auth/request-link"),
            AuthRoute::RequestLink
        );
        assert_eq!(parse_auth_route("POST", "/auth/redeem"), AuthRoute::Redeem);
        assert_eq!(parse_auth_route("POST", "/auth/logout"), AuthRoute::Logout);
        assert_eq!(parse_auth_route("GET", "/auth/me?x=1"), AuthRoute::Me);
        for (m, p) in [
            ("GET", "/auth/request-link"), // wrong method
            ("GET", "/auth/redeem"),       // redeem must be POST (mail-scanner rule)
            ("POST", "/auth/me"),
            ("POST", "/auth/unknown"),
            ("POST", "/auth"),
        ] {
            assert_eq!(parse_auth_route(m, p), AuthRoute::NotFound, "{m} {p}");
        }
    }

    #[test]
    fn full_passwordless_round_trip_over_the_api() {
        let (store, sender) = (MemStore::new(), FakeSender::default());
        // request a link
        let r = req(
            &store,
            &limiter(),
            &peer_limiter(),
            &sender,
            r#"{"email":"Dev@Hopme.sh"}"#,
            T0,
        );
        assert_eq!(r.status, 202);
        // redeem the token from the email
        let tok = token_from(&sender);
        let r = handle_redeem(&store, &format!(r#"{{"token":"{tok}"}}"#), T0 + 1000);
        assert_eq!(r.status, 200);
        assert!(r.body.contains(r#""created":true"#));
        assert!(r.body.contains("dev@hopme.sh"), "normalized email echoed");
        let cookie = r.set_cookie.expect("session cookie set");
        assert!(cookie.starts_with("__Host-hop_session="));
        // /auth/me resolves through the cookie header
        let raw = cookie.split(['=', ';']).nth(1).unwrap().to_string();
        let hdr = format!("other=1; __Host-hop_session={raw}"); // tolerate sibling cookies
        let me = handle_me(&store, Some(&hdr), T0 + 2000);
        assert_eq!(me.status, 200);
        assert!(me.body.contains("dev@hopme.sh"));
        // logout clears and invalidates
        let out = handle_logout(&store, Some(&hdr));
        assert_eq!(out.status, 204);
        assert!(out.set_cookie.unwrap().contains("Max-Age=0"));
        assert_eq!(handle_me(&store, Some(&hdr), T0 + 3000).status, 401);
    }

    #[test]
    fn cookieless_logout_sets_nothing_so_cross_site_posts_cannot_force_logout() {
        let store = MemStore::new();
        // A SameSite=Lax cross-site form POST arrives with no cookie: it must get NO Set-Cookie
        // (answering with a clearing cookie would let any page force-log-out a visitor).
        let r = handle_logout(&store, None);
        assert_eq!((r.status, r.set_cookie), (204, None));
        // A stale-but-present cookie still gets cleared (idempotent logout).
        let r = handle_logout(&store, Some("__Host-hop_session=stale"));
        assert_eq!(r.status, 204);
        assert!(r.set_cookie.unwrap().contains("Max-Age=0"));
    }

    #[test]
    fn request_link_responses_do_not_depend_on_account_existence() {
        let (store, sender) = (MemStore::new(), FakeSender::default());
        let (lim, peers) = (limiter(), peer_limiter());
        // no account exists
        let a = req(&store, &lim, &peers, &sender, r#"{"email":"a@x.co"}"#, T0);
        // create the account by redeeming
        let tok = token_from(&sender);
        handle_redeem(&store, &format!(r#"{{"token":"{tok}"}}"#), T0);
        // the account now exists; the response must be byte-identical
        let b = req(
            &store,
            &lim,
            &peers,
            &sender,
            r#"{"email":"a@x.co"}"#,
            T0 + 1,
        );
        assert_eq!(a, b, "existing vs new account must be indistinguishable");
    }

    #[test]
    fn bad_shapes_and_volume_are_the_only_errors() {
        let (store, sender) = (MemStore::new(), FakeSender::default());
        let (lim, peers) = (limiter(), peer_limiter());
        assert_eq!(
            req(&store, &lim, &peers, &sender, "not json", T0).status,
            400
        );
        assert_eq!(
            req(&store, &lim, &peers, &sender, r#"{"email":"nope"}"#, T0).status,
            400
        );
        // 3 sends pass, the 4th within the window throttles
        for i in 0..3 {
            assert_eq!(
                req(
                    &store,
                    &lim,
                    &peers,
                    &sender,
                    r#"{"email":"a@x.co"}"#,
                    T0 + i
                )
                .status,
                202
            );
        }
        assert_eq!(
            req(
                &store,
                &lim,
                &peers,
                &sender,
                r#"{"email":"a@x.co"}"#,
                T0 + 3
            )
            .status,
            429
        );
        // a different address is unaffected, and the window resets
        assert_eq!(
            req(&store, &lim, &peers, &sender, r#"{"email":"b@x.co"}"#, T0).status,
            202
        );
        assert_eq!(
            req(
                &store,
                &lim,
                &peers,
                &sender,
                r#"{"email":"a@x.co"}"#,
                T0 + REQUEST_LINK_WINDOW_MS + 10
            )
            .status,
            202
        );
    }

    #[test]
    fn email_send_failure_is_surfaced_not_silent() {
        let store = MemStore::new();
        let sender = FakeSender {
            fail: true,
            ..Default::default()
        };
        let (lim, peers) = (limiter(), peer_limiter());
        let r = req(&store, &lim, &peers, &sender, r#"{"email":"a@x.co"}"#, T0);
        assert_eq!(r.status, 502, "a dead email path must not 202");
    }

    #[test]
    fn send_failures_refund_the_limit_so_an_outage_cannot_lock_out() {
        let store = MemStore::new();
        let (lim, peers) = (limiter(), peer_limiter());
        let dead = FakeSender {
            fail: true,
            ..Default::default()
        };
        // burn MORE tries than the per-email cap against a dead provider
        for i in 0..5u64 {
            assert_eq!(
                req(&store, &lim, &peers, &dead, r#"{"email":"a@x.co"}"#, T0 + i).status,
                502
            );
        }
        // provider recovers inside the SAME window: the user still gets a link
        let ok = FakeSender::default();
        assert_eq!(
            req(&store, &lim, &peers, &ok, r#"{"email":"a@x.co"}"#, T0 + 10).status,
            202,
            "an email-provider outage must not consume the caller's window"
        );
    }

    #[test]
    fn one_peer_cannot_spray_links_across_many_addresses() {
        let store = MemStore::new();
        let sender = FakeSender::default();
        let (lim, peers) = (limiter(), peer_limiter());
        // distinct addresses so the per-email limiter never trips; the peer cap must
        for i in 0..REQUEST_LINK_MAX_PER_PEER {
            assert_eq!(
                req(
                    &store,
                    &lim,
                    &peers,
                    &sender,
                    &format!(r#"{{"email":"u{i}@x.co"}}"#),
                    T0 + u64::from(i)
                )
                .status,
                202
            );
        }
        assert_eq!(
            req(
                &store,
                &lim,
                &peers,
                &sender,
                r#"{"email":"straw@x.co"}"#,
                T0 + 100
            )
            .status,
            429,
            "the per-peer cap is the anti-spam control"
        );
        // a different peer is unaffected
        let r = handle_request_link(
            &store,
            &lim,
            &peers,
            "8.8.8.8",
            &sender,
            BASE,
            r#"{"email":"other@x.co"}"#,
            T0 + 101,
        );
        assert_eq!(r.status, 202);
    }

    #[test]
    fn redeem_collapses_all_invalid_cases_to_410() {
        let store = MemStore::new();
        for body in [r#"{"token":"never-issued"}"#, r#"{"token":""}"#] {
            assert_eq!(handle_redeem(&store, body, T0).status, 410);
        }
        assert_eq!(handle_redeem(&store, "{}", T0).status, 400);
    }

    #[test]
    fn cookie_parsing_is_exact() {
        assert_eq!(
            session_from_cookie_header(Some("__Host-hop_session=abc")),
            Some("abc".into())
        );
        assert_eq!(
            session_from_cookie_header(Some("a=1; __Host-hop_session=abc; b=2")),
            Some("abc".into())
        );
        assert_eq!(
            session_from_cookie_header(Some("__Host-hop_session=")),
            None
        );
        assert_eq!(session_from_cookie_header(Some("hop_session=abc")), None);
        assert_eq!(session_from_cookie_header(None), None);
    }

    #[test]
    fn rate_limiter_prunes_expired_windows() {
        let lim = RateLimiter::new(1, 1000);
        for i in 0..10_000 {
            lim.allow(&format!("k{i}"), T0);
        }
        // far in the future: the insert path prunes the dead windows and admits the new key
        assert!(lim.allow("fresh", T0 + 10_000));
        let g = lim.hits.lock().unwrap();
        assert!(
            g.len() < 10_000,
            "expired windows were pruned, len={}",
            g.len()
        );
    }

    #[test]
    fn rate_limiter_is_hard_bounded_within_a_window() {
        let lim = RateLimiter::new(3, 1_000_000);
        for i in 0..10_000 {
            lim.allow(&format!("k{i}"), T0);
        }
        // Map full of LIVE windows: a within-window spray of new keys is DENIED, not stored.
        assert!(!lim.allow("attacker-new-key", T0 + 1));
        assert_eq!(
            lim.hits.lock().unwrap().len(),
            10_000,
            "no growth past the cap"
        );
        // Existing keys keep working while the map is full.
        assert!(lim.allow("k42", T0 + 2));
    }

    #[test]
    fn refund_gives_back_exactly_one_hit_in_window() {
        // Mirrors the real flow: refund only ever follows a SUCCESSFUL allow whose guarded action
        // then failed (the 502 path), reopening that one slot.
        let lim = RateLimiter::new(2, 1000);
        assert!(lim.allow("k", T0)); // 1
        assert!(lim.allow("k", T0 + 1)); // 2 (at cap)
        lim.refund("k", T0 + 2); // back to 1
        assert!(lim.allow("k", T0 + 3), "refund reopened one slot"); // 2
        assert!(
            !lim.allow("k", T0 + 4),
            "cap still enforced after the refund"
        );
        // refunding an unknown key or an expired window is a no-op, never a panic
        lim.refund("ghost", T0);
        lim.refund("k", T0 + 999_999);
    }

    #[test]
    fn peer_identity_trusts_only_the_appended_xff_entry() {
        // Cloud Run appends the REAL client last; spoofed leading entries are ignored.
        assert_eq!(
            peer_identity(Some("6.6.6.6, 1.2.3.4"), "10.0.0.9:33112"),
            "1.2.3.4"
        );
        assert_eq!(peer_identity(Some(" 1.2.3.4 "), "10.0.0.9:1"), "1.2.3.4");
        // no header: socket peer, port stripped (IPv6 bracket form included)
        assert_eq!(peer_identity(None, "9.9.9.9:5124"), "9.9.9.9");
        assert_eq!(peer_identity(None, "[::1]:5124"), "[::1]");
        // empty header falls back too
        assert_eq!(peer_identity(Some(""), "9.9.9.9:5124"), "9.9.9.9");
    }
}
