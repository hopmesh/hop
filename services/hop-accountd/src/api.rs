//! The console-facing API: routing, the bearer-token gate, the tenant map, and the ownership rule.
//! All pure (no sockets, no Stripe), so every security-relevant decision here is unit-tested.
//!
//! Surface (all under the token gate except `/healthz`):
//!   GET  /healthz
//!   GET  /v1/tenants/{tenant_hex}/invoices
//!   GET  /v1/tenants/{tenant_hex}/invoices/{invoice_id}
//!   POST /v1/tenants/{tenant_hex}/invoices/{invoice_id}/pay
//!   GET  /v1/tenants/{tenant_hex}/payments
//!   GET  /v1/tenants/{tenant_hex}/card
//!
//! THE OWNERSHIP RULE: an invoice id is NOT a capability. Every per-invoice route resolves the
//! tenant to its Stripe customer and verifies `invoice.customer == that customer` before returning
//! or paying anything; via `invoice_access`, a mismatch, an absent invoice, AND an upstream fetch
//! error all return the same 404, so an id can't be probed for existence (the account key can read
//! any invoice, so a 404-vs-502 split would otherwise enumerate the whole account's ids).

use std::collections::BTreeMap;

/// A 16-byte tenant, as 32 lowercase hex chars in URLs (the same shape the ledger uses).
pub fn valid_tenant_hex(s: &str) -> bool {
    s.len() == 32
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// tenant-hex -> Stripe customer id. Same file format as the reconciler's map
/// (`<tenant-hex-32> <cus_...>` lines, `#` comments), provisioned by the operator until the signup
/// flow owns it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TenantMap {
    map: BTreeMap<String, String>,
}

impl TenantMap {
    pub fn parse(text: &str) -> TenantMap {
        let mut map = BTreeMap::new();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut parts = line.split_whitespace();
            let (Some(tenant), Some(customer)) = (parts.next(), parts.next()) else {
                continue;
            };
            if valid_tenant_hex(tenant) && crate::stripe_api::valid_stripe_id(customer) {
                map.insert(tenant.to_string(), customer.to_string());
            }
        }
        TenantMap { map }
    }

    pub fn customer_of(&self, tenant_hex: &str) -> Option<&str> {
        self.map.get(tenant_hex).map(String::as_str)
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}

/// The parsed intent of one request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Route {
    Healthz,
    Invoices { tenant: String },
    Invoice { tenant: String, invoice: String },
    PayInvoice { tenant: String, invoice: String },
    Payments { tenant: String },
    Card { tenant: String },
    NotFound,
}

/// Parse method + path into a [`Route`]. Strict: unknown shapes, bad tenant hex, or bad Stripe id
/// shapes all land on `NotFound` (no partial matches, no probing signal).
pub fn parse_route(method: &str, path: &str) -> Route {
    let path = path.split(['?', '#']).next().unwrap_or("");
    if method.eq_ignore_ascii_case("GET") && path == "/healthz" {
        return Route::Healthz;
    }
    let segs: Vec<&str> = path.trim_matches('/').split('/').collect();
    let get = method.eq_ignore_ascii_case("GET");
    let post = method.eq_ignore_ascii_case("POST");
    match segs.as_slice() {
        ["v1", "tenants", t, "invoices"] if get && valid_tenant_hex(t) => Route::Invoices {
            tenant: (*t).to_string(),
        },
        ["v1", "tenants", t, "invoices", i]
            if get && valid_tenant_hex(t) && crate::stripe_api::valid_stripe_id(i) =>
        {
            Route::Invoice {
                tenant: (*t).to_string(),
                invoice: (*i).to_string(),
            }
        }
        ["v1", "tenants", t, "invoices", i, "pay"]
            if post && valid_tenant_hex(t) && crate::stripe_api::valid_stripe_id(i) =>
        {
            Route::PayInvoice {
                tenant: (*t).to_string(),
                invoice: (*i).to_string(),
            }
        }
        ["v1", "tenants", t, "payments"] if get && valid_tenant_hex(t) => Route::Payments {
            tenant: (*t).to_string(),
        },
        ["v1", "tenants", t, "card"] if get && valid_tenant_hex(t) => Route::Card {
            tenant: (*t).to_string(),
        },
        _ => Route::NotFound,
    }
}

/// Whether the `Authorization` header carries the expected bearer token. Comparison is
/// length-independent-then-fold so a byte-by-byte early exit can't leak a prefix match; `/healthz`
/// is the only ungated route, decided by the caller.
pub fn token_ok(auth_header: Option<&str>, expected: &str) -> bool {
    let Some(h) = auth_header else { return false };
    let Some(got) = h.strip_prefix("Bearer ") else {
        return false;
    };
    if expected.is_empty() {
        return false; // an unset token must never mean "open"
    }
    let (a, b) = (got.as_bytes(), expected.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// The ownership rule for per-invoice routes: the invoice's owning customer must be EXACTLY the
/// tenant's mapped customer. Absent owner (Stripe omitted it) fails closed.
pub fn owns_invoice(tenant_customer: &str, invoice_customer: Option<&str>) -> bool {
    invoice_customer == Some(tenant_customer)
}

/// The outcome of a per-invoice access check, collapsing every non-owned case to ONE
/// indistinguishable result so an invoice id cannot be probed for existence.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InvoiceAccess {
    /// The invoice exists and belongs to this tenant: proceed to render or pay.
    Owned,
    /// Absent, owned by someone else, or unreadable upstream: all answered as an identical 404.
    Denied,
}

/// Decide per-invoice access from the tenant's customer and the invoice-fetch outcome.
/// `Ok(Some(owner))` is the invoice's owning customer, `Ok(None)` means Stripe omitted the owner,
/// and `Err(())` means the fetch failed (an absent invoice is a Stripe 404, i.e. an `Err`, as is a
/// transport error). EVERY non-owned path returns `Denied`, so a caller cannot tell "not yours"
/// from "does not exist" from "upstream error": the whole point of the ownership rule. The
/// restricted account key can read ANY invoice in the account, so without this an authenticated
/// tenant could distinguish 404-mismatch from 502-absent and enumerate the account's invoice ids.
pub fn invoice_access(tenant_customer: &str, owner: Result<Option<&str>, ()>) -> InvoiceAccess {
    match owner {
        Ok(Some(o)) if o == tenant_customer => InvoiceAccess::Owned,
        _ => InvoiceAccess::Denied,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: &str = "000102030405060708090a0b0c0d0e0f";

    #[test]
    fn routes_parse_strictly() {
        assert_eq!(parse_route("GET", "/healthz"), Route::Healthz);
        assert_eq!(
            parse_route("GET", &format!("/v1/tenants/{T}/invoices")),
            Route::Invoices { tenant: T.into() }
        );
        assert_eq!(
            parse_route("GET", &format!("/v1/tenants/{T}/invoices/in_123?x=1")),
            Route::Invoice {
                tenant: T.into(),
                invoice: "in_123".into()
            }
        );
        assert_eq!(
            parse_route("POST", &format!("/v1/tenants/{T}/invoices/in_123/pay")),
            Route::PayInvoice {
                tenant: T.into(),
                invoice: "in_123".into()
            }
        );
        assert_eq!(
            parse_route("GET", &format!("/v1/tenants/{T}/payments")),
            Route::Payments { tenant: T.into() }
        );
        assert_eq!(
            parse_route("GET", &format!("/v1/tenants/{T}/card")),
            Route::Card { tenant: T.into() }
        );
    }

    #[test]
    fn bad_shapes_land_on_not_found() {
        for (m, p) in [
            ("GET", "/v1/tenants/short/invoices"), // bad tenant
            ("GET", &format!("/v1/tenants/{T}/invoices/in|123")[..]), // bad invoice id
            ("POST", &format!("/v1/tenants/{T}/invoices")[..]), // wrong method
            ("GET", &format!("/v1/tenants/{T}/invoices/in_1/pay")[..]), // pay must be POST
            ("GET", "/v1/tenants"),                // truncated
            ("GET", "/v2/tenants/x/invoices"),     // wrong version
        ] {
            assert_eq!(parse_route(m, p), Route::NotFound, "{m} {p}");
        }
    }

    #[test]
    fn token_gate_is_strict() {
        assert!(token_ok(Some("Bearer sekrit"), "sekrit"));
        assert!(!token_ok(Some("Bearer wrong"), "sekrit"));
        assert!(!token_ok(Some("sekrit"), "sekrit")); // no Bearer prefix
        assert!(!token_ok(None, "sekrit"));
        assert!(!token_ok(Some("Bearer "), "sekrit"));
        // The failure mode that matters: an UNSET expected token must never mean open.
        assert!(!token_ok(Some("Bearer "), ""));
        assert!(!token_ok(Some("Bearer anything"), ""));
    }

    #[test]
    fn ownership_fails_closed() {
        assert!(owns_invoice("cus_A", Some("cus_A")));
        assert!(!owns_invoice("cus_A", Some("cus_B")));
        assert!(
            !owns_invoice("cus_A", None),
            "absent owner must fail closed"
        );
    }

    #[test]
    fn invoice_access_closes_the_existence_oracle() {
        // Only a confirmed-owned invoice is Owned; absent (Err), mismatch, and Stripe-omitted-owner
        // are all the SAME Denied, so 404 responses are byte-identical and ids can't be probed.
        assert_eq!(
            invoice_access("cus_A", Ok(Some("cus_A"))),
            InvoiceAccess::Owned
        );
        assert_eq!(
            invoice_access("cus_A", Ok(Some("cus_B"))),
            InvoiceAccess::Denied,
            "another tenant's invoice must be Denied, not distinguishable"
        );
        assert_eq!(
            invoice_access("cus_A", Err(())),
            InvoiceAccess::Denied,
            "an absent/unreadable invoice must be Denied, NOT a different (502) status"
        );
        assert_eq!(invoice_access("cus_A", Ok(None)), InvoiceAccess::Denied);
    }

    #[test]
    fn tenant_map_parses_and_validates_both_sides() {
        let text = format!(
            "# comment\n{T} cus_AAA\nnothex cus_BBB\n{} bad/customer\n",
            "ffffffffffffffffffffffffffffffff"
        );
        let m = TenantMap::parse(&text);
        assert_eq!(m.len(), 1, "only the fully-valid line survives");
        assert_eq!(m.customer_of(T), Some("cus_AAA"));
        assert_eq!(m.customer_of("ffffffffffffffffffffffffffffffff"), None);
    }
}
