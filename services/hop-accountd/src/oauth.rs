//! GitHub OAuth ("Continue with GitHub"), the second entry into the same session issuance as the
//! magic link. Pure like the rest: URL building, query/state parsing, and response parsing are all
//! unit-tested; the two upstream calls (code exchange, email fetch) sit behind [`OauthTransport`],
//! with the reqwest impl only under `--features live`.
//!
//! Flow (both endpoints are BROWSER navigations, not fetches):
//!   GET /auth/github/start     -> 302 to github.com/login/oauth/authorize, planting a state cookie
//!   GET /auth/github/callback  -> verify state (cookie == query), exchange the code, read the
//!                                 user's primary VERIFIED email, then session::login_or_create
//!                                 (same create-or-sign-in semantics as the magic link) and 302 home.
//!
//! The state cookie is the CSRF guard: `__Host-` prefixed, HttpOnly, `SameSite=Lax` (it must survive
//! the top-level redirect back from GitHub, which Lax allows), 10-minute Max-Age, cleared on use.
//! An email GitHub has not verified is REJECTED: it would let anyone claim an address they don't
//! own just by adding it to a GitHub profile, which would merge into that address's Hop account.

/// The state cookie name (same `__Host-` binding rationale as the session cookie).
pub const STATE_COOKIE: &str = "__Host-hop_oauth_state";
/// How long a started OAuth dance may take before the state expires with the cookie.
pub const STATE_TTL_SECS: u64 = 600;

/// Static client configuration (from env in the binary).
#[derive(Clone, Debug)]
pub struct OauthConfig {
    pub client_id: String,
    pub client_secret: String,
    /// The console origin, e.g. `https://dashboard.hopme.sh`; the registered redirect URI is
    /// `{console_base}/api/auth/github/callback`.
    pub console_base: String,
}

impl OauthConfig {
    /// The registered redirect URI carries the `/api` prefix on purpose. The callback is a
    /// server-side handler (exchange the code, set the session cookie, redirect to the console),
    /// not a console page, so the browser must reach it through the console's `/api/*` proxy, which
    /// strips `/api` and forwards `/auth/github/callback` to this service. Without the prefix the
    /// browser lands on the Next app, which has no such route and 404s. This must exactly match the
    /// GitHub OAuth app's registered callback URL and is reused verbatim in the token exchange.
    pub fn redirect_uri(&self) -> String {
        format!(
            "{}/api/auth/github/callback",
            self.console_base.trim_end_matches('/')
        )
    }
}

/// The GitHub authorize URL for a `start` redirect. `scope=user:email` is read-only access to the
/// email list, the minimum needed. `state` is the CSPRNG value also planted in the state cookie.
pub fn authorize_url(cfg: &OauthConfig, state: &str) -> String {
    format!(
        "https://github.com/login/oauth/authorize?client_id={}&redirect_uri={}&scope=user%3Aemail&state={state}",
        url_encode(&cfg.client_id),
        url_encode(&cfg.redirect_uri()),
    )
}

/// The `Set-Cookie` planting the state for the round trip, and its clearing counterpart.
pub fn state_cookie(state: &str) -> String {
    format!(
        "{STATE_COOKIE}={state}; Max-Age={STATE_TTL_SECS}; Path=/; HttpOnly; SameSite=Lax; Secure"
    )
}
pub fn clear_state_cookie() -> String {
    format!("{STATE_COOKIE}=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax; Secure")
}

/// Extract a named cookie's value from a `Cookie` header (exact-name match, same discipline as
/// `auth_api::session_from_cookie_header`).
pub fn cookie_value(header: Option<&str>, name: &str) -> Option<String> {
    let h = header?;
    for part in h.split(';') {
        let part = part.trim();
        if let Some(v) = part.strip_prefix(name) {
            if let Some(v) = v.strip_prefix('=') {
                if !v.is_empty() {
                    return Some(v.to_string());
                }
            }
        }
    }
    None
}

/// Parse `code` and `state` out of the callback query string. Strict: both must be present, within
/// GitHub's character set (`[A-Za-z0-9_-]`, up to 256 chars), or the whole callback is rejected. No
/// percent-decoding is attempted; values needing it are outside the accepted alphabet by definition.
pub fn parse_callback_query(query: &str) -> Option<(String, String)> {
    let mut code = None;
    let mut state = None;
    for pair in query.trim_start_matches('?').split('&') {
        let mut kv = pair.splitn(2, '=');
        match (kv.next(), kv.next()) {
            (Some("code"), Some(v)) => code = Some(v),
            (Some("state"), Some(v)) => state = Some(v),
            _ => {}
        }
    }
    let ok = |s: &str| {
        !s.is_empty()
            && s.len() <= 256
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    };
    match (code, state) {
        (Some(c), Some(s)) if ok(c) && ok(s) => Some((c.to_string(), s.to_string())),
        _ => None,
    }
}

/// The code-exchange request: URL + form body for `POST github.com/login/oauth/access_token`.
pub fn token_request(cfg: &OauthConfig, code: &str) -> (String, String) {
    (
        "https://github.com/login/oauth/access_token".to_string(),
        format!(
            "client_id={}&client_secret={}&code={}&redirect_uri={}",
            url_encode(&cfg.client_id),
            url_encode(&cfg.client_secret),
            url_encode(code),
            url_encode(&cfg.redirect_uri()),
        ),
    )
}

/// Parse the access token out of the exchange response (JSON form; the transport sends
/// `Accept: application/json`).
pub fn parse_access_token(json: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    v.get("access_token")?.as_str().map(str::to_string)
}

/// The email-list request URL (`GET api.github.com/user/emails` with the bearer token).
pub const EMAILS_URL: &str = "https://api.github.com/user/emails";

/// Pick the login email out of GitHub's email list: the entry marked `primary` AND `verified`, else
/// the first `verified` one. Unverified addresses are never accepted (see the module doc).
pub fn parse_login_email(json: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    let list = v.as_array()?;
    let verified =
        |e: &&serde_json::Value| e.get("verified").and_then(|b| b.as_bool()) == Some(true);
    let email_of =
        |e: &serde_json::Value| e.get("email").and_then(|s| s.as_str()).map(str::to_string);
    list.iter()
        .filter(verified)
        .find(|e| e.get("primary").and_then(|b| b.as_bool()) == Some(true))
        .and_then(email_of)
        .or_else(|| list.iter().filter(verified).find_map(email_of))
}

/// Constant-time check that the state echoed in the callback query equals the one we planted in the
/// cookie. Absent cookie = definite mismatch (an unsolicited callback).
pub fn state_matches(cookie_header: Option<&str>, query_state: &str) -> bool {
    match cookie_value(cookie_header, STATE_COOKIE) {
        Some(planted) => crate::auth::tokens_match(&planted, query_state),
        None => false,
    }
}

/// The two upstream calls, as a seam. `post_form_json` sends a form body and asks for a JSON
/// response; `get_bearer_json` performs an authenticated GET. Both return (status, body).
pub trait OauthTransport {
    fn post_form_json(&self, url: &str, body: &str) -> Result<(u16, String), String>;
    fn get_bearer_json(&self, url: &str, bearer: &str) -> Result<(u16, String), String>;
}

/// Run the server side of the callback: exchange the code, fetch the verified email. Returns the
/// normalized email to log in, or a coarse error string (safe to log; never contains the code or
/// token). The caller has already verified the state.
pub fn exchange_for_email(
    t: &dyn OauthTransport,
    cfg: &OauthConfig,
    code: &str,
) -> Result<String, String> {
    let (url, body) = token_request(cfg, code);
    let (status, resp) = t.post_form_json(&url, &body)?;
    if !(200..300).contains(&status) {
        return Err(format!("github token exchange returned {status}"));
    }
    let Some(token) = parse_access_token(&resp) else {
        return Err("github token exchange: no access_token".into());
    };
    let (status, resp) = t.get_bearer_json(EMAILS_URL, &token)?;
    if !(200..300).contains(&status) {
        return Err(format!("github emails fetch returned {status}"));
    }
    let Some(email) = parse_login_email(&resp) else {
        return Err("github account has no verified email".into());
    };
    Ok(crate::session::normalize_email(&email))
}

/// Minimal percent-encoding for URL/query components (unreserved chars pass through).
fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// The live transport (reqwest), only with `--features live`.
#[cfg(feature = "live")]
pub struct ReqwestOauth {
    pub http: reqwest::blocking::Client,
}

#[cfg(feature = "live")]
impl OauthTransport for ReqwestOauth {
    fn post_form_json(&self, url: &str, body: &str) -> Result<(u16, String), String> {
        let resp = self
            .http
            .post(url)
            .header("Accept", "application/json")
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(body.to_string())
            .send()
            .map_err(|e| format!("oauth request failed: {}", e.without_url()))?;
        Ok((resp.status().as_u16(), resp.text().unwrap_or_default()))
    }
    fn get_bearer_json(&self, url: &str, bearer: &str) -> Result<(u16, String), String> {
        let resp = self
            .http
            .get(url)
            .header("Accept", "application/vnd.github+json")
            .header("User-Agent", "hop-accountd")
            .bearer_auth(bearer)
            .send()
            .map_err(|e| format!("oauth request failed: {}", e.without_url()))?;
        Ok((resp.status().as_u16(), resp.text().unwrap_or_default()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> OauthConfig {
        OauthConfig {
            client_id: "Iv1.abc".into(),
            client_secret: "sekrit".into(),
            console_base: "https://dashboard.hopme.sh/".into(),
        }
    }

    #[test]
    fn authorize_url_carries_the_registered_redirect_and_state() {
        let u = authorize_url(&cfg(), "st4te");
        assert!(u.starts_with("https://github.com/login/oauth/authorize?"));
        assert!(u.contains("client_id=Iv1.abc"));
        assert!(u.contains(
            "redirect_uri=https%3A%2F%2Fdashboard.hopme.sh%2Fapi%2Fauth%2Fgithub%2Fcallback"
        ));
        assert!(u.contains("scope=user%3Aemail"));
        assert!(u.ends_with("state=st4te"));
    }

    #[test]
    fn state_cookie_is_hardened_and_short_lived() {
        let c = state_cookie("s1");
        assert!(c.starts_with("__Host-hop_oauth_state=s1;"));
        for attr in [
            "HttpOnly",
            "SameSite=Lax",
            "Secure",
            "Path=/",
            "Max-Age=600",
        ] {
            assert!(c.contains(attr), "missing {attr}");
        }
        assert!(clear_state_cookie().contains("Max-Age=0"));
        // parsing round-trips through a Cookie header with siblings
        assert_eq!(
            cookie_value(Some("a=1; __Host-hop_oauth_state=s1; b=2"), STATE_COOKIE),
            Some("s1".into())
        );
        assert_eq!(
            cookie_value(Some("__Host-hop_oauth_state="), STATE_COOKIE),
            None
        );
    }

    #[test]
    fn state_check_requires_the_planted_cookie() {
        let hdr = format!("{STATE_COOKIE}=abc123");
        assert!(state_matches(Some(&hdr), "abc123"));
        assert!(!state_matches(Some(&hdr), "abc124"));
        assert!(!state_matches(None, "abc123"), "unsolicited callback");
        assert!(!state_matches(Some("other=x"), "abc123"));
    }

    #[test]
    fn callback_query_parses_strictly() {
        assert_eq!(
            parse_callback_query("code=abc123&state=xyz_-9"),
            Some(("abc123".into(), "xyz_-9".into()))
        );
        assert_eq!(
            parse_callback_query("?state=s&code=c&extra=1"),
            Some(("c".into(), "s".into()))
        );
        for bad in [
            "code=abc",               // no state
            "state=s",                // no code
            "code=&state=s",          // empty code
            "code=a%20b&state=s",     // outside the alphabet
            "code=a&state=s\u{0141}", // non-ascii
        ] {
            assert_eq!(parse_callback_query(bad), None, "{bad}");
        }
        let long = "a".repeat(257);
        assert_eq!(parse_callback_query(&format!("code={long}&state=s")), None);
    }

    #[test]
    fn token_request_encodes_and_targets_github() {
        let (url, body) = token_request(&cfg(), "c0de");
        assert_eq!(url, "https://github.com/login/oauth/access_token");
        assert!(body.contains("client_id=Iv1.abc"));
        assert!(body.contains("client_secret=sekrit"));
        assert!(body.contains("code=c0de"));
        // The exchange redirect_uri must match the authorize redirect_uri byte for byte, /api and
        // all; GitHub rejects the exchange otherwise.
        assert!(body.contains(
            "redirect_uri=https%3A%2F%2Fdashboard.hopme.sh%2Fapi%2Fauth%2Fgithub%2Fcallback"
        ));
    }

    #[test]
    fn login_email_requires_verified_and_prefers_primary() {
        let list = r#"[
            {"email":"unverified@x.co","primary":true,"verified":false},
            {"email":"secondary@x.co","primary":false,"verified":true},
            {"email":"primary@x.co","primary":true,"verified":true}
        ]"#;
        // the unverified "primary" is skipped; the VERIFIED primary wins over the verified secondary
        assert_eq!(parse_login_email(list), Some("primary@x.co".into()));
        // no verified primary: fall back to the first verified
        let no_primary = r#"[
            {"email":"unverified@x.co","primary":true,"verified":false},
            {"email":"ok@x.co","primary":false,"verified":true}
        ]"#;
        assert_eq!(parse_login_email(no_primary), Some("ok@x.co".into()));
        // nothing verified: refuse (an unverified address must never log in)
        let none = r#"[{"email":"unverified@x.co","primary":true,"verified":false}]"#;
        assert_eq!(parse_login_email(none), None);
        assert_eq!(parse_login_email("not json"), None);
        assert_eq!(parse_login_email("{}"), None);
    }

    struct FakeTransport {
        token_resp: (u16, String),
        emails_resp: (u16, String),
    }
    impl OauthTransport for FakeTransport {
        fn post_form_json(&self, _u: &str, _b: &str) -> Result<(u16, String), String> {
            Ok(self.token_resp.clone())
        }
        fn get_bearer_json(&self, _u: &str, _b: &str) -> Result<(u16, String), String> {
            Ok(self.emails_resp.clone())
        }
    }

    #[test]
    fn exchange_happy_path_normalizes_the_email() {
        let t = FakeTransport {
            token_resp: (
                200,
                r#"{"access_token":"gho_x","token_type":"bearer"}"#.into(),
            ),
            emails_resp: (
                200,
                r#"[{"email":"Dev@Hopme.sh","primary":true,"verified":true}]"#.into(),
            ),
        };
        assert_eq!(exchange_for_email(&t, &cfg(), "c").unwrap(), "dev@hopme.sh");
    }

    #[test]
    fn exchange_failures_are_coarse_and_tokenless() {
        // non-2xx exchange
        let t = FakeTransport {
            token_resp: (401, "{}".into()),
            emails_resp: (200, "[]".into()),
        };
        let e = exchange_for_email(&t, &cfg(), "c0deSECRET").unwrap_err();
        assert!(e.contains("401") && !e.contains("gho_") && !e.contains("c0deSECRET"));
        // missing token
        let t = FakeTransport {
            token_resp: (200, r#"{"error":"bad_verification_code"}"#.into()),
            emails_resp: (200, "[]".into()),
        };
        assert!(exchange_for_email(&t, &cfg(), "c").is_err());
        // no verified email
        let t = FakeTransport {
            token_resp: (200, r#"{"access_token":"gho_x"}"#.into()),
            emails_resp: (
                200,
                r#"[{"email":"u@x.co","primary":true,"verified":false}]"#.into(),
            ),
        };
        assert!(exchange_for_email(&t, &cfg(), "c").is_err());
    }
}
