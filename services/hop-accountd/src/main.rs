//! hop-accountd: the console's billing backend, served over plain HTTP behind an authenticated
//! front (Cloud Run/LB terminates TLS; every `/v1/*` request must carry the `HOP_API_TOKEN`
//! bearer). Std-thread blocking like every Hop service; no tokio.
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
    use hop_accountd::stripe_api::{StripeReader, Transport};
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// Caps mirroring the other services: bounded head read, bounded concurrent connections, and an
    /// ABSOLUTE head-read deadline. The 10s read timeout only bounds the gap between reads; without
    /// a wall-clock deadline a client dripping one byte just under every 10s holds a connection slot
    /// for hours and, with only MAX_CONNS slots and no per-source cap, a few hundred such trickles
    /// starve the service (slowloris). The deadline caps total head-read time regardless of drip
    /// rate; the LB/Cloud Run front (request buffering, per-source limits) is the outer defense.
    const MAX_REQ_HEAD_BYTES: u64 = 8 * 1024;
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
        fn post_form(&self, url: &str, body: &str) -> Result<(u16, String), String> {
            let resp = self
                .http
                .post(url)
                .bearer_auth(&self.api_key)
                .header("Content-Type", "application/x-www-form-urlencoded")
                .body(body.to_string())
                .send()
                .map_err(|e| format!("stripe request failed: {e}"))?;
            Ok((resp.status().as_u16(), resp.text().unwrap_or_default()))
        }
    }

    struct App {
        reader: StripeReader<ReqwestStripe>,
        tenants: TenantMap,
        token: String,
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

    fn serve_conn(mut stream: TcpStream, app: &App) {
        let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(10)));
        let deadline = std::time::Instant::now() + HEAD_READ_DEADLINE;
        let Ok(clone) = stream.try_clone() else {
            return;
        };
        let mut reader = BufReader::new(clone.take(MAX_REQ_HEAD_BYTES));
        let mut line = String::new();
        if reader.read_line(&mut line).is_err() {
            return;
        }
        let mut parts = line.split_whitespace();
        let method = parts.next().unwrap_or("").to_string();
        let path = parts.next().unwrap_or("").to_string();
        // Headers: only Authorization matters; bodies are ignored (all POSTs here are empty).
        let mut auth: Option<String> = None;
        loop {
            if std::time::Instant::now() >= deadline {
                return; // absolute head-read deadline: no trickle client holds a slot past this
            }
            let mut h = String::new();
            if reader.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" || h == "\n" {
                break;
            }
            if let Some(v) = h
                .to_ascii_lowercase()
                .strip_prefix("authorization:")
                .map(str::trim)
            {
                // Re-take the original-cased value (tokens are case-sensitive).
                auth = Some(
                    h[h.find(':').map(|i| i + 1).unwrap_or(0)..]
                        .trim()
                        .to_string(),
                );
                let _ = v;
            }
        }

        let route = parse_route(&method, &path);
        let (code, body) = respond(app, route, auth.as_deref());
        let reason = match code {
            200 => "OK",
            401 => "Unauthorized",
            404 => "Not Found",
            _ => "Error",
        };
        let header = format!(
            "HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        let _ = stream.write_all(header.as_bytes());
        let _ = stream.write_all(body.as_bytes());
        let _ = stream.flush();
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
