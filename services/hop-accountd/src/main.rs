//! hop-accountd: the console's account + billing backend, served over plain HTTP behind an
//! authenticated front (Cloud Run/LB terminates TLS). Two surfaces: `/v1/*` (operator bearer via
//! `HOP_API_TOKEN`) and the USER-facing `/auth/*` (cookie sessions; active only when DATABASE_URL
//! is configured). Std-thread blocking like every Hop service; no tokio.
//!
//! The Stripe transport only compiles under `--features live` (the hop-billingd discipline), so a
//! default build has no network surface and CI exercises all routing/parsing/ownership logic
//! through the pure library tests.

use hop_accountd::api::{parse_route, token_ok, TenantMap};

fn main() {
    #[cfg(not(feature = "live"))]
    {
        eprintln!(
            "hop-accountd: built without the `live` feature. The routing/parsing logic is in the \
             library; the live Stripe wiring builds with `--features live` once STRIPE_ACCOUNT_KEY \
             + HOP_API_TOKEN + HOP_TENANT_MAP are configured."
        );
        // Keep the pure symbols referenced so a default build type-checks the whole surface.
        let _ = (
            parse_route("GET", "/healthz"),
            token_ok(None, "x"),
            TenantMap::default(),
        );
    }
    #[cfg(feature = "live")]
    live::serve();
}

#[cfg(feature = "live")]
mod live {
    use super::*;
    use hop_accountd::api::{invoice_access, InvoiceAccess, Route};
    use hop_accountd::auth_api::{
        self, AuthResponse, AuthRoute, RateLimiter, REQUEST_LINK_MAX_PER_EMAIL,
        REQUEST_LINK_MAX_PER_PEER, REQUEST_LINK_WINDOW_MS,
    };
    use hop_accountd::billing::{PlanCatalog, StripeBilling};
    use hop_accountd::email::ResendSender;
    use hop_accountd::oauth::{self, OauthConfig, ReqwestOauth};
    use hop_accountd::pg::PgStore;
    use hop_accountd::stripe_api::{StripeReader, Transport};
    #[cfg(feature = "firestore")]
    use hop_accountd::usage;
    use hop_accountd::{auth, session};
    use hop_accountd::{billing_api, console_api, keys_api, team_api};
    use std::io::{ErrorKind, Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    /// Caps mirroring the other services: bounded head read, bounded concurrent connections, and an
    /// ABSOLUTE head-read deadline. The 10s read timeout only bounds the gap between reads; without
    /// a wall-clock deadline a client dripping one byte just under every 10s holds a connection slot
    /// for hours and, with only MAX_CONNS slots and no per-source cap, a few hundred such trickles
    /// starve the service (slowloris). The deadline caps total head-read time regardless of drip
    /// rate; the LB/Cloud Run front (request buffering, per-source limits) is the outer defense.
    const MAX_REQ_HEAD_BYTES: u64 = 16 * 1024; // head + a bounded auth body fit inside this take()
    const MAX_BODY_BYTES: usize = 8 * 1024;
    const MAX_CONNS: usize = 256;
    const HEAD_READ_DEADLINE: std::time::Duration = std::time::Duration::from_secs(15);
    static ACTIVE_CONNS: AtomicUsize = AtomicUsize::new(0);

    struct ConnGuard;
    impl Drop for ConnGuard {
        fn drop(&mut self) {
            ACTIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
        }
    }

    /// The real Stripe transport with the restricted account key.
    struct ReqwestStripe {
        http: reqwest::blocking::Client,
        api_key: String,
    }
    impl Transport for ReqwestStripe {
        fn get(&self, url: &str) -> Result<(u16, String), String> {
            let resp = self
                .http
                .get(url)
                .bearer_auth(&self.api_key)
                .send()
                .map_err(|e| format!("stripe request failed: {e}"))?;
            Ok((resp.status().as_u16(), resp.text().unwrap_or_default()))
        }
        fn post_form(
            &self,
            url: &str,
            body: &str,
            idempotency_key: Option<&str>,
        ) -> Result<(u16, String), String> {
            let mut req = self
                .http
                .post(url)
                .bearer_auth(&self.api_key)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .body(body.to_string());
            if let Some(key) = idempotency_key {
                req = req.header("Idempotency-Key", key);
            }
            let resp = req
                .send()
                .map_err(|e| format!("stripe request failed: {e}"))?;
            Ok((resp.status().as_u16(), resp.text().unwrap_or_default()))
        }
    }

    struct App {
        reader: StripeReader<ReqwestStripe>,
        tenants: TenantMap,
        token: String,
        /// The user-facing auth surface; present only when DATABASE_URL (+ Resend config) is set,
        /// so the invoice service still runs standalone without it.
        auth: Option<AuthState>,
    }

    struct AuthState {
        store: PgStore,
        email_limiter: RateLimiter,
        peer_limiter: RateLimiter,
        sender: ResendSender,
        oauth_http: ReqwestOauth,
        console_base: String,
        github: Option<OauthConfig>,
        /// The Stripe transport (restricted account key), always present — it powers the console's
        /// invoice/card READS as well as the billing writes.
        stripe: ReqwestStripe,
        /// The resolved price catalog for self-serve Checkout. Present only when HOP_STRIPE_*_PRICES is
        /// configured; absent, `/billing/*` reports 503 while reads + auth + keys still run.
        catalog: Option<PlanCatalog>,
    }

    fn now_ms() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    pub fn serve() {
        let Ok(api_key) = std::env::var("STRIPE_ACCOUNT_KEY") else {
            eprintln!("hop-accountd: STRIPE_ACCOUNT_KEY is not set; refusing to start");
            std::process::exit(2);
        };
        let Ok(token) = std::env::var("HOP_API_TOKEN") else {
            eprintln!("hop-accountd: HOP_API_TOKEN is not set; refusing to serve unauthenticated");
            std::process::exit(2);
        };
        if token.len() < 16 {
            eprintln!("hop-accountd: HOP_API_TOKEN is too short (>= 16 bytes); refusing");
            std::process::exit(2);
        }
        let tenants = std::env::var("HOP_TENANT_MAP")
            .ok()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|t| TenantMap::parse(&t))
            .unwrap_or_default();
        if tenants.is_empty() {
            eprintln!("hop-accountd: HOP_TENANT_MAP empty or unset; every tenant will 404");
        }
        let listen = std::env::var("PORT")
            .map(|p| format!("0.0.0.0:{p}"))
            .unwrap_or_else(|_| "0.0.0.0:9446".to_string());

        // The auth surface activates only when its configuration is complete; a partial config is
        // a hard startup error (a silently missing piece would strand users), absence is fine.
        let auth_state = match std::env::var("DATABASE_URL") {
            Err(_) => {
                eprintln!("hop-accountd: DATABASE_URL unset; /auth/* disabled (invoice-only mode)");
                None
            }
            Ok(db_url) => {
                let (Ok(resend_key), Ok(resend_from), Ok(console_base)) = (
                    std::env::var("RESEND_API_KEY"),
                    std::env::var("RESEND_FROM"),
                    std::env::var("HOP_CONSOLE_BASE"),
                ) else {
                    eprintln!(
                        "hop-accountd: DATABASE_URL is set but RESEND_API_KEY / RESEND_FROM / \
                         HOP_CONSOLE_BASE is missing; refusing a half-configured auth surface"
                    );
                    std::process::exit(2);
                };
                let github = match (
                    std::env::var("GITHUB_CLIENT_ID"),
                    std::env::var("GITHUB_CLIENT_SECRET"),
                ) {
                    (Ok(client_id), Ok(client_secret)) => Some(OauthConfig {
                        client_id,
                        client_secret,
                        console_base: console_base.clone(),
                    }),
                    (Err(_), Err(_)) => None,
                    _ => {
                        eprintln!(
                            "hop-accountd: exactly one of GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET \
                             is set; refusing a half-configured OAuth client"
                        );
                        std::process::exit(2);
                    }
                };
                let store = match PgStore::connect(&db_url) {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("hop-accountd: postgres connect failed: {e}");
                        std::process::exit(2);
                    }
                };
                // Fleet sync: when built with `--features firestore` AND HOP_TENANT_SYNC_PROJECT is
                // set, project the Postgres tenant registry into Firestore on an interval so relays +
                // collectors read live tenant keys / OTLP endpoints instead of static operator files.
                #[cfg(feature = "firestore")]
                if let Ok(project) = std::env::var("HOP_TENANT_SYNC_PROJECT") {
                    let interval = std::env::var("HOP_TENANT_SYNC_SECS")
                        .ok()
                        .and_then(|s| s.parse::<u64>().ok())
                        .filter(|s| *s >= 5)
                        .unwrap_or(60);
                    println!(
                        "hop-accountd: tenant registry sync ON (project {project}, every {interval}s)"
                    );
                    hop_accountd::sync::spawn_sync(
                        store.clone(),
                        hop_store_firestore::TenantRegistry::new(&project),
                        std::time::Duration::from_secs(interval),
                    );
                }
                let http = reqwest::blocking::Client::builder()
                    .timeout(std::time::Duration::from_secs(15))
                    .build()
                    .expect("http client");
                // Self-serve billing activates only when the Stripe price catalog is fully set. A
                // PARTIAL catalog is a hard startup error (a broken Checkout must never be offered);
                // a fully-absent catalog just leaves /billing/* disabled (503) while the rest runs.
                // The Stripe transport is always built (STRIPE_ACCOUNT_KEY is required at startup); it
                // serves the console's invoice/card reads AND billing writes.
                let stripe = ReqwestStripe {
                    http: reqwest::blocking::Client::builder()
                        .timeout(std::time::Duration::from_secs(30))
                        .build()
                        .expect("http client"),
                    api_key: api_key.clone(),
                };
                // Self-serve Checkout activates only when the price catalog is fully set. A PARTIAL
                // catalog is a hard startup error (a broken Checkout must never be offered); a
                // fully-absent catalog just leaves /billing/* disabled (503) while the rest runs.
                let usage_prices = std::env::var("HOP_STRIPE_USAGE_PRICES").unwrap_or_default();
                let scale_metered =
                    std::env::var("HOP_STRIPE_SCALE_METERED_PRICES").unwrap_or_default();
                let scale_base = std::env::var("HOP_STRIPE_SCALE_BASE_PRICE").unwrap_or_default();
                let catalog = if usage_prices.is_empty() && scale_metered.is_empty() {
                    eprintln!("hop-accountd: HOP_STRIPE_*_PRICES unset; /billing/* disabled");
                    None
                } else {
                    let Some(c) = PlanCatalog::parse(&usage_prices, &scale_metered, &scale_base)
                    else {
                        eprintln!(
                            "hop-accountd: HOP_STRIPE_*_PRICES is set but malformed; refusing a \
                             half-configured billing surface"
                        );
                        std::process::exit(2);
                    };
                    Some(c)
                };
                println!(
                    "hop-accountd: /auth/* enabled (github oauth: {}, billing: {})",
                    if github.is_some() { "on" } else { "off" },
                    if catalog.is_some() { "on" } else { "off" }
                );
                Some(AuthState {
                    store,
                    email_limiter: RateLimiter::new(
                        REQUEST_LINK_MAX_PER_EMAIL,
                        REQUEST_LINK_WINDOW_MS,
                    ),
                    peer_limiter: RateLimiter::new(
                        REQUEST_LINK_MAX_PER_PEER,
                        REQUEST_LINK_WINDOW_MS,
                    ),
                    sender: ResendSender {
                        http: http.clone(),
                        api_key: resend_key,
                        from: resend_from,
                    },
                    oauth_http: ReqwestOauth { http },
                    console_base,
                    github,
                    stripe,
                    catalog,
                })
            }
        };

        let app = Arc::new(App {
            reader: StripeReader {
                transport: ReqwestStripe {
                    http: reqwest::blocking::Client::builder()
                        .timeout(std::time::Duration::from_secs(30))
                        .build()
                        .expect("http client"),
                    api_key,
                },
            },
            tenants,
            token,
            auth: auth_state,
        });

        let listener = TcpListener::bind(&listen).expect("bind listen address");
        println!(
            "hop-accountd: serving on {listen} ({} tenants mapped)",
            app.tenants.len()
        );
        for stream in listener.incoming().flatten() {
            if ACTIVE_CONNS.fetch_add(1, Ordering::SeqCst) >= MAX_CONNS {
                ACTIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
                drop(stream);
                continue;
            }
            let app = app.clone();
            let spawned = std::thread::Builder::new().spawn(move || {
                let _guard = ConnGuard;
                let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    serve_conn(stream, &app)
                }));
            });
            if spawned.is_err() {
                ACTIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
            }
        }
    }

    /// First index of `needle` in `hay`.
    fn find_sub(hay: &[u8], needle: &[u8]) -> Option<usize> {
        if needle.is_empty() || hay.len() < needle.len() {
            return None;
        }
        (0..=hay.len() - needle.len()).find(|&i| &hay[i..i + needle.len()] == needle)
    }

    /// Read into `out` under an ABSOLUTE wall-clock `deadline` enforced across EVERY read, until
    /// `done(out)` returns `Some` (its returned length is the accepted prefix) or a hard limit / EOF /
    /// error / the deadline is hit. Each read blocks at most `PER_READ_MS`, so a byte-dribble (within
    /// OR between reads) is caught within that of the deadline rather than resetting an inter-read
    /// timer forever (the slowloris the head loop's between-lines check alone did not stop). Returns
    /// the accepted length, or None to drop the connection.
    fn deadline_read(
        sock: &mut TcpStream,
        deadline: Instant,
        out: &mut Vec<u8>,
        cap: usize,
        done: impl Fn(&[u8]) -> Option<usize>,
    ) -> Option<usize> {
        const PER_READ_MS: u64 = 500;
        let mut tmp = [0u8; 2048];
        loop {
            if let Some(n) = done(out) {
                return Some(n);
            }
            if out.len() > cap || Instant::now() >= deadline {
                return None;
            }
            let _ = sock.set_read_timeout(Some(Duration::from_millis(PER_READ_MS)));
            match sock.read(&mut tmp) {
                Ok(0) => return None, // EOF before the terminator / expected length
                Ok(n) => out.extend_from_slice(&tmp[..n]),
                // per-read timeout: loop back and re-check the ABSOLUTE deadline
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
                Err(_) => return None,
            }
        }
    }

    fn serve_conn(mut stream: TcpStream, app: &App) {
        let deadline = std::time::Instant::now() + HEAD_READ_DEADLINE;
        let Ok(mut sock) = stream.try_clone() else {
            return;
        };

        // Read the request head (through the blank CRLF line) under the absolute deadline.
        let mut buf: Vec<u8> = Vec::with_capacity(2048);
        let head_cap = MAX_REQ_HEAD_BYTES as usize;
        let Some(term) = deadline_read(&mut sock, deadline, &mut buf, head_cap, |b| {
            find_sub(b, b"\r\n\r\n").map(|i| i + 4)
        }) else {
            return;
        };
        let body_prefetch = buf.split_off(term); // bytes read past the head belong to the body
        let head = String::from_utf8_lossy(&buf).into_owned();

        let mut lines = head.split("\r\n");
        let mut req = lines.next().unwrap_or("").split_whitespace();
        let method = req.next().unwrap_or("").to_string();
        let path = req.next().unwrap_or("").to_string();
        let mut auth_hdr: Option<String> = None;
        let mut cookie_hdr: Option<String> = None;
        let mut xff_hdr: Option<String> = None;
        let mut content_length: usize = 0;
        for h in lines {
            if h.is_empty() {
                continue;
            }
            let lower = h.to_ascii_lowercase();
            let value = || {
                h[h.find(':').map(|i| i + 1).unwrap_or(0)..]
                    .trim()
                    .to_string()
            };
            if lower.starts_with("authorization:") {
                auth_hdr = Some(value());
            } else if lower.starts_with("cookie:") {
                cookie_hdr = Some(value());
            } else if lower.starts_with("x-forwarded-for:") {
                xff_hdr = Some(value());
            } else if lower.starts_with("content-length:") {
                content_length = value().parse().unwrap_or(0);
            }
        }

        // The user-facing console surface (cookie sessions, no bearer). Bodies exist only here:
        // /auth/* (login), plus the authenticated tenant endpoints /keys/* and /settings/*.
        let is_auth = path.starts_with("/auth/");
        if is_auth
            || path.starts_with("/keys/")
            || path.starts_with("/settings/")
            || path.starts_with("/billing/")
            || path.starts_with("/console/")
        {
            let Some(st) = app.auth.as_ref() else {
                return write_response(&mut stream, 404, &[], "{\"error\":\"not found\"}");
            };
            if content_length > MAX_BODY_BYTES {
                return write_response(&mut stream, 413, &[], "{\"error\":\"too_large\"}");
            }
            // Finish the body under the SAME absolute deadline, starting from whatever the head read
            // already pulled in. A short/dribbled body cannot hold the slot past the deadline.
            let mut body = body_prefetch;
            if body.len() < content_length {
                let want = content_length;
                if deadline_read(
                    &mut sock,
                    deadline,
                    &mut body,
                    MAX_BODY_BYTES + 2048,
                    move |b| (b.len() >= want).then_some(want),
                )
                .is_none()
                {
                    return;
                }
            }
            body.truncate(content_length);
            let body = String::from_utf8_lossy(&body).into_owned();
            let peer = auth_api::peer_identity(
                xff_hdr.as_deref(),
                &stream
                    .peer_addr()
                    .map(|a| a.to_string())
                    .unwrap_or_default(),
            );
            let (status, headers, resp_body) = if is_auth {
                dispatch_auth(st, &method, &path, cookie_hdr.as_deref(), &peer, &body)
            } else {
                dispatch_console(st, &method, &path, cookie_hdr.as_deref(), &body)
            };
            return write_response(&mut stream, status, &headers, &resp_body);
        }

        let route = parse_route(&method, &path);
        let (code, body) = respond(app, route, auth_hdr.as_deref());
        write_response(&mut stream, code, &[], &body);
    }

    /// Write one response and close. `extra` carries Set-Cookie / Location lines; auth responses
    /// are marked no-store so a shared cache can never replay a session or user body.
    fn write_response(stream: &mut TcpStream, code: u16, extra: &[(String, String)], body: &str) {
        let reason = match code {
            200 => "OK",
            202 => "Accepted",
            204 => "No Content",
            302 => "Found",
            400 => "Bad Request",
            401 => "Unauthorized",
            404 => "Not Found",
            410 => "Gone",
            413 => "Payload Too Large",
            429 => "Too Many Requests",
            _ => "Error",
        };
        let mut header = format!(
            "HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n",
            body.len()
        );
        for (k, v) in extra {
            header.push_str(&format!("{k}: {v}\r\n"));
        }
        header.push_str("\r\n");
        let _ = stream.write_all(header.as_bytes());
        let _ = stream.write_all(body.as_bytes());
        let _ = stream.flush();
    }

    /// Dispatch one `/auth/*` request through the pure handlers. Returns (status, extra headers,
    /// body); every response is `Cache-Control: no-store`.
    fn dispatch_auth(
        st: &AuthState,
        method: &str,
        path: &str,
        cookie: Option<&str>,
        peer: &str,
        body: &str,
    ) -> (u16, Vec<(String, String)>, String) {
        let mut headers: Vec<(String, String)> = vec![("Cache-Control".into(), "no-store".into())];
        let now = now_ms();

        // GitHub OAuth: browser navigations, not JSON fetches.
        if path.split(['?', '#']).next() == Some("/auth/github/start")
            && method.eq_ignore_ascii_case("GET")
        {
            let Some(gh) = st.github.as_ref() else {
                return (404, headers, "{\"error\":\"not found\"}".into());
            };
            if !st.peer_limiter.allow(peer, now) {
                return (429, headers, "{\"error\":\"slow_down\"}".into());
            }
            let state = auth::generate_token();
            headers.push(("Set-Cookie".into(), oauth::state_cookie(&state)));
            headers.push(("Location".into(), oauth::authorize_url(gh, &state)));
            return (302, headers, String::new());
        }
        if path.split(['?', '#']).next() == Some("/auth/github/callback")
            && method.eq_ignore_ascii_case("GET")
        {
            let Some(gh) = st.github.as_ref() else {
                return (404, headers, "{\"error\":\"not found\"}".into());
            };
            // Whatever happens, the state cookie is spent.
            headers.push(("Set-Cookie".into(), oauth::clear_state_cookie()));
            let fail = |mut headers: Vec<(String, String)>, why: &str| {
                eprintln!("hop-accountd: github callback rejected: {why}");
                headers.push((
                    "Location".into(),
                    format!(
                        "{}/?auth_error=github",
                        st.console_base.trim_end_matches('/')
                    ),
                ));
                (302, headers, String::new())
            };
            if !st.peer_limiter.allow(peer, now) {
                return fail(headers, "rate limited");
            }
            let query = path.split_once('?').map(|(_, q)| q).unwrap_or("");
            let Some((code, qstate)) = oauth::parse_callback_query(query) else {
                return fail(headers, "malformed query");
            };
            if !oauth::state_matches(cookie, &qstate) {
                return fail(headers, "state mismatch");
            }
            let email = match oauth::exchange_for_email(&st.oauth_http, gh, &code) {
                Ok(e) => e,
                Err(why) => return fail(headers, &why),
            };
            match session::login_or_create(&st.store, &email, now) {
                Ok(out) => {
                    headers.push((
                        "Set-Cookie".into(),
                        session::set_cookie(&out.session_raw, session::SESSION_TTL_MS / 1000),
                    ));
                    headers.push((
                        "Location".into(),
                        format!("{}/", st.console_base.trim_end_matches('/')),
                    ));
                    (302, headers, String::new())
                }
                Err(e) => fail(headers, &format!("login failed: {e}")),
            }
        } else {
            let r: AuthResponse = match auth_api::parse_auth_route(method, path) {
                AuthRoute::RequestLink => auth_api::handle_request_link(
                    &st.store,
                    &st.email_limiter,
                    &st.peer_limiter,
                    peer,
                    &st.sender,
                    &st.console_base,
                    body,
                    now,
                ),
                AuthRoute::Redeem => auth_api::handle_redeem(&st.store, body, now),
                AuthRoute::Logout => auth_api::handle_logout(&st.store, cookie),
                AuthRoute::Me => auth_api::handle_me(&st.store, cookie, now),
                AuthRoute::NotFound => AuthResponse {
                    status: 404,
                    set_cookie: None,
                    body: "{\"error\":\"not found\"}".into(),
                },
            };
            if let Some(c) = r.set_cookie {
                headers.push(("Set-Cookie".into(), c));
            }
            (r.status, headers, r.body)
        }
    }

    /// Dispatch one authenticated console request (`/keys/*`, `/settings/*`) through the pure
    /// handlers. Cookie-session RBAC lives inside each handler; responses are `Cache-Control:
    /// no-store` and never set a cookie.
    fn dispatch_console(
        st: &AuthState,
        method: &str,
        path: &str,
        cookie: Option<&str>,
        body: &str,
    ) -> (u16, Vec<(String, String)>, String) {
        let headers: Vec<(String, String)> = vec![("Cache-Control".into(), "no-store".into())];
        let now = now_ms();
        let bare = path.split(['?', '#']).next().unwrap_or(path);
        let is_post = method.eq_ignore_ascii_case("POST");
        let is_get = method.eq_ignore_ascii_case("GET");
        // Checkout/portal need the price catalog too (503 when unconfigured); the Stripe transport
        // itself is always present.
        let billing_call = |run: &dyn Fn(&StripeBilling, &PlanCatalog) -> AuthResponse| {
            let Some(cat) = st.catalog.as_ref() else {
                return AuthResponse::json(503, "{\"error\":\"billing_unavailable\"}");
            };
            run(
                &StripeBilling {
                    transport: &st.stripe,
                },
                cat,
            )
        };
        // The tenant for a read is a query param (?tenant=..); validated downstream by authorize_tenant.
        let tenant = auth_api::query_param(path, "tenant").unwrap_or_default();
        let r: AuthResponse = match bare {
            "/keys/carriage" if is_post => {
                keys_api::handle_set_carriage_key(&st.store, cookie, body, now)
            }
            "/settings/otlp" if is_post => keys_api::handle_set_otlp(&st.store, cookie, body, now),
            "/billing/checkout" if is_post => billing_call(&|bill, cat| {
                billing_api::handle_checkout(
                    &st.store,
                    bill,
                    cat,
                    &st.console_base,
                    cookie,
                    body,
                    now,
                )
            }),
            "/billing/portal" if is_post => billing_call(&|bill, _cat| {
                billing_api::handle_portal(&st.store, bill, &st.console_base, cookie, body, now)
            }),
            "/console/overview" if is_get => console_api::handle_overview(&st.store, cookie, now),
            "/console/invoices" if is_get => {
                console_api::handle_invoices(&st.store, &st.stripe, cookie, &tenant, now)
            }
            "/console/card" if is_get => {
                console_api::handle_card(&st.store, &st.stripe, cookie, &tenant, now)
            }
            "/console/subscription" if is_get => billing_call(&|bill, cat| {
                console_api::handle_subscription(&st.store, bill, cat, cookie, &tenant, now)
            }),
            "/console/team" if is_get => team_api::handle_list(&st.store, cookie, &tenant, now),
            "/console/team/role" if is_post => {
                team_api::handle_set_role(&st.store, cookie, body, now)
            }
            "/console/team/remove" if is_post => {
                team_api::handle_remove(&st.store, cookie, body, now)
            }
            "/console/team/transfer" if is_post => {
                team_api::handle_transfer(&st.store, cookie, body, now)
            }
            // Near-realtime usage off the fleet Firestore ledgers. Only built + routed with the
            // firestore feature; the project is the fleet's (HOP_FIRESTORE_PROJECT).
            #[cfg(feature = "firestore")]
            "/console/usage" if is_get => match std::env::var("HOP_FIRESTORE_PROJECT") {
                Ok(project) => usage::handle_usage(&st.store, &project, cookie, &tenant, now),
                Err(_) => AuthResponse::json(503, "{\"error\":\"usage_unavailable\"}"),
            },
            _ => AuthResponse::json(404, "{\"error\":\"not found\"}"),
        };
        (r.status, headers, r.body)
    }

    fn json_err(msg: &str) -> String {
        serde_json::json!({ "error": msg }).to_string()
    }

    /// Route dispatch. Every arm resolves tenant -> customer first; per-invoice arms then run the
    /// ownership rule through `invoice_access`, which answers an identical 404 for absent, mismatch,
    /// AND upstream error, so an invoice id cannot be probed for existence.
    fn respond(app: &App, route: Route, auth: Option<&str>) -> (u16, String) {
        if matches!(route, Route::Healthz) {
            return (200, "{\"ok\":true}".into());
        }
        if !token_ok(auth, &app.token) {
            return (401, json_err("unauthorized"));
        }
        let customer_of = |tenant: &str| app.tenants.customer_of(tenant).map(str::to_string);
        match route {
            Route::Healthz => unreachable!("handled above"),
            Route::NotFound => (404, json_err("not found")),
            Route::Invoices { tenant } => match customer_of(&tenant) {
                None => (404, json_err("not found")),
                Some(c) => match app.reader.invoices(&c) {
                    Ok(list) => (
                        200,
                        serde_json::to_string(&list).unwrap_or_else(|_| "[]".into()),
                    ),
                    Err(e) => (502, json_err(&e)),
                },
            },
            Route::Invoice { tenant, invoice } => match customer_of(&tenant) {
                None => (404, json_err("not found")),
                Some(c) => {
                    let fetched = app.reader.invoice(&invoice);
                    if let Err(e) = &fetched {
                        // Masked as 404 to the client (existence oracle); logged server-side.
                        eprintln!("hop-accountd: invoice fetch failed (masked as 404): {e}");
                    }
                    let owner = fetched
                        .as_ref()
                        .map(|d| d.customer.as_deref())
                        .map_err(|_| ());
                    match invoice_access(&c, owner) {
                        InvoiceAccess::Owned => (
                            200,
                            serde_json::to_string(&fetched.unwrap())
                                .unwrap_or_else(|_| "{}".into()),
                        ),
                        InvoiceAccess::Denied => (404, json_err("not found")),
                    }
                }
            },
            Route::PayInvoice { tenant, invoice } => match customer_of(&tenant) {
                None => (404, json_err("not found")),
                Some(c) => {
                    // Ownership is checked BEFORE the pay call: fetch, verify, then pay. Every
                    // non-owned fetch outcome (absent, mismatch, error) is an identical 404.
                    let fetched = app.reader.invoice(&invoice);
                    if let Err(e) = &fetched {
                        eprintln!("hop-accountd: invoice fetch failed (masked as 404): {e}");
                    }
                    let owner = fetched
                        .as_ref()
                        .map(|d| d.customer.as_deref())
                        .map_err(|_| ());
                    match invoice_access(&c, owner) {
                        InvoiceAccess::Owned => match app.reader.pay_invoice(&invoice) {
                            // Ownership already verified, so surfacing a pay error leaks no probing
                            // signal about other invoices.
                            Ok(paid) => (
                                200,
                                serde_json::to_string(&paid).unwrap_or_else(|_| "{}".into()),
                            ),
                            Err(e) => (502, json_err(&e)),
                        },
                        InvoiceAccess::Denied => (404, json_err("not found")),
                    }
                }
            },
            Route::Payments { tenant } => match customer_of(&tenant) {
                None => (404, json_err("not found")),
                Some(c) => match app.reader.payments(&c) {
                    Ok(p) => (
                        200,
                        serde_json::to_string(&p).unwrap_or_else(|_| "[]".into()),
                    ),
                    Err(e) => (502, json_err(&e)),
                },
            },
            Route::Card { tenant } => match customer_of(&tenant) {
                None => (404, json_err("not found")),
                Some(c) => match app.reader.card(&c) {
                    Ok(card) => (
                        200,
                        serde_json::to_string(&card).unwrap_or_else(|_| "null".into()),
                    ),
                    Err(e) => (502, json_err(&e)),
                },
            },
        }
    }
}
