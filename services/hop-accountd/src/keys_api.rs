//! Console key + settings endpoints, pure like `billing_api`: a session + RBAC gate, then a write to
//! the tenant registry (the `Org` row the fleet reads). The socket layer writes the returned
//! [`AuthResponse`].
//!
//!   POST /keys/carriage  {"tenant","pubkey"}    -> 200 {ok}   register OR rotate the carriage key
//!   POST /settings/otlp  {"tenant","endpoint"}  -> 200 {ok}   set the managed-OTLP forward endpoint
//!
//! The carriage key is the Ed25519 PUBLIC key the paid relay fabric verifies a tenant's carriage
//! stamps against (`hop_core::access`): the tenant's own infrastructure holds the private key and
//! stamps its outbound bundles, and the console only ever stores the public half. Registering a key
//! is `ManageKeys` (Owner + Admin); the OTLP endpoint is `ManageSettings` (Owner + Admin).

use crate::auth_api::{authorize_tenant, json_field, AuthResponse};
use crate::domain::Permission;
use crate::store::Store;

/// A carriage-stamp public key: exactly 32 bytes as 64 lowercase-hex chars, an Ed25519 public key
/// (the node address shape in `hop_core::crypto`). Rejected here so the fleet never syncs a malformed
/// key that would silently fail every stamp verification.
pub fn valid_carriage_pubkey(hex: &str) -> bool {
    hex.len() == 64
        && hex
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// A managed-OTLP forward endpoint the fleet's telemetry collector will POST this tenant's telemetry
/// to. This validator IS the trust boundary that keeps a dangerous target out of the registry, so it
/// is strict: `https://` only (telemetry never leaves in the clear), bounded, no whitespace/control
/// bytes, a non-empty host, NO embedded credentials, and NOT an internal/metadata address (loopback,
/// link-local incl. 169.254.169.254, RFC1918/unique-local, unspecified, multicast) nor an
/// internal-only hostname (`localhost`, a bare name with no dot, or a `.local`/`.internal` suffix).
/// This blocks the SSRF where a tenant admin points their own export target at cloud metadata or an
/// internal service.
pub fn valid_otlp_endpoint(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else {
        return false;
    };
    if url.len() > 512 || url.bytes().any(|b| b.is_ascii_whitespace() || b < 0x20) {
        return false;
    }
    // The authority is everything up to the first path/query/fragment delimiter.
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    // No embedded userinfo (`user:pass@host` can disguise the real host / carry credentials).
    if authority.is_empty() || authority.contains('@') {
        return false;
    }
    // Split host from an optional :port. An IPv6 literal is bracketed: `[::1]:443`.
    let host = if let Some(after) = authority.strip_prefix('[') {
        match after.split_once(']') {
            Some((inner, _port)) => inner,
            None => return false,
        }
    } else {
        match authority.rsplit_once(':') {
            // `host:port` only when the tail is a real (non-empty, all-digit) port.
            Some((h, p)) if !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) => h,
            _ => authority,
        }
    };
    if host.is_empty() {
        return false;
    }
    // An IP literal must be a public (global-unicast-ish) address.
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        return match ip {
            std::net::IpAddr::V4(v4) => {
                !(v4.is_loopback()
                    || v4.is_private()
                    || v4.is_link_local()
                    || v4.is_unspecified()
                    || v4.is_multicast()
                    || v4.is_broadcast())
            }
            std::net::IpAddr::V6(v6) => {
                let seg0 = v6.segments()[0];
                !(v6.is_loopback()
                    || v6.is_unspecified()
                    || v6.is_multicast()
                    || (seg0 & 0xfe00) == 0xfc00  // unique-local fc00::/7
                    || (seg0 & 0xffc0) == 0xfe80) // link-local  fe80::/10
            }
        };
    }
    // A hostname must look like a public DNS name: has a dot, and no internal-only suffix.
    let lower = host.to_ascii_lowercase();
    lower.contains('.')
        && lower != "localhost"
        && !lower.ends_with(".localhost")
        && !lower.ends_with(".local")
        && !lower.ends_with(".internal")
}

/// POST /keys/carriage. Register or rotate the tenant's carriage-stamp public key. Idempotent: the
/// same key twice is a no-op; a new key rotates (the fleet picks it up on the next registry sync).
pub fn handle_set_carriage_key(
    store: &dyn Store,
    cookie: Option<&str>,
    body: &str,
    now_ms: u64,
) -> AuthResponse {
    let Some(tenant) = json_field(body, "tenant") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let Some(pubkey) = json_field(body, "pubkey") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    if !valid_carriage_pubkey(&pubkey) {
        return AuthResponse::json(400, r#"{"error":"invalid_pubkey"}"#);
    }
    let (_user, org) =
        match authorize_tenant(store, cookie, &tenant, Permission::ManageKeys, now_ms) {
            Ok(v) => v,
            Err(resp) => return resp,
        };
    match store.set_org_carriage_pubkey(&org.id, &pubkey) {
        Ok(()) => AuthResponse::json(200, r#"{"ok":true}"#),
        Err(_) => AuthResponse::json(500, r#"{"error":"internal"}"#),
    }
}

/// POST /settings/otlp. Set the tenant's managed-OTLP forward endpoint (where the fleet exports this
/// tenant's telemetry). `ManageSettings` (Owner + Admin).
pub fn handle_set_otlp(
    store: &dyn Store,
    cookie: Option<&str>,
    body: &str,
    now_ms: u64,
) -> AuthResponse {
    let Some(tenant) = json_field(body, "tenant") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let Some(endpoint) = json_field(body, "endpoint") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    if !valid_otlp_endpoint(&endpoint) {
        return AuthResponse::json(400, r#"{"error":"invalid_endpoint"}"#);
    }
    let (_user, org) =
        match authorize_tenant(store, cookie, &tenant, Permission::ManageSettings, now_ms) {
            Ok(v) => v,
            Err(resp) => return resp,
        };
    match store.set_org_otlp_endpoint(&org.id, &endpoint) {
        Ok(()) => AuthResponse::json(200, r#"{"ok":true}"#),
        Err(_) => AuthResponse::json(500, r#"{"error":"internal"}"#),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Membership, Role};
    use crate::orgs::ensure_personal_workspace;
    use crate::session::{login_or_create, set_cookie};
    use crate::store::MemStore;

    const T0: u64 = 1_000_000;
    const KEY: &str = "aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44"; // 64 hex

    /// Log a user in (creating their owned workspace) and return (store, cookie_header, tenant_hex).
    fn signed_in() -> (MemStore, String, String) {
        let s = MemStore::new();
        let out = login_or_create(&s, "owner@x.co", T0).unwrap();
        let cookie = set_cookie(&out.session_raw, 3600);
        let raw = cookie.split(['=', ';']).nth(1).unwrap().to_string();
        let hdr = format!("__Host-hop_session={raw}");
        let org = ensure_personal_workspace(&s, &out.user.id, "owner@x.co", T0).unwrap();
        (s, hdr, org.tenant_hex)
    }

    /// Add a second user to the org at `role`, returning their cookie header.
    fn member_at(s: &MemStore, tenant: &str, email: &str, role: Role) -> String {
        let m = login_or_create(s, email, T0).unwrap();
        let org = s.org_by_tenant(tenant).unwrap().unwrap();
        s.add_membership(&Membership {
            user_id: m.user.id.clone(),
            org_id: org.id,
            role,
        })
        .unwrap();
        let c = set_cookie(&m.session_raw, 3600);
        let raw = c.split(['=', ';']).nth(1).unwrap().to_string();
        format!("__Host-hop_session={raw}")
    }

    #[test]
    fn pubkey_validation() {
        assert!(valid_carriage_pubkey(KEY));
        assert!(!valid_carriage_pubkey("")); // empty
        assert!(!valid_carriage_pubkey(&KEY[..63])); // 63 chars
        assert!(!valid_carriage_pubkey(&format!("{KEY}0"))); // 65 chars
        assert!(!valid_carriage_pubkey(&KEY.to_uppercase())); // uppercase rejected
        assert!(!valid_carriage_pubkey(&"g".repeat(64))); // non-hex
    }

    #[test]
    fn otlp_validation() {
        // public https endpoints (with paths, ports) are fine
        assert!(valid_otlp_endpoint("https://otlp.datadoghq.com/v1/traces"));
        assert!(valid_otlp_endpoint(
            "https://collector.example.com:4318/v1/metrics"
        ));
        assert!(valid_otlp_endpoint("https://203.0.113.10:443/v1")); // public IP literal
                                                                     // scheme / shape
        assert!(!valid_otlp_endpoint("http://otlp.example.com")); // must be https
        assert!(!valid_otlp_endpoint("https://x.com/ path")); // whitespace
        assert!(!valid_otlp_endpoint(&format!(
            "https://x.com/{}",
            "a".repeat(600)
        ))); // too long
        assert!(!valid_otlp_endpoint("https://")); // empty host
        assert!(!valid_otlp_endpoint("https:///v1/traces")); // empty authority
                                                             // SSRF: internal / metadata / credentialed targets are refused
        assert!(!valid_otlp_endpoint(
            "https://169.254.169.254/latest/meta-data/"
        )); // link-local (IMDS)
        assert!(!valid_otlp_endpoint("https://10.0.0.5/admin")); // RFC1918
        assert!(!valid_otlp_endpoint("https://192.168.1.1:8080/")); // RFC1918
        assert!(!valid_otlp_endpoint("https://127.0.0.1/")); // loopback
        assert!(!valid_otlp_endpoint("https://[::1]/v1")); // IPv6 loopback
        assert!(!valid_otlp_endpoint("https://[fd00::1]/v1")); // IPv6 unique-local
        assert!(!valid_otlp_endpoint("https://localhost/v1")); // internal name
        assert!(!valid_otlp_endpoint("https://collector/v1")); // bare name, no dot
        assert!(!valid_otlp_endpoint("https://metadata.google.internal/")); // .internal suffix
        assert!(!valid_otlp_endpoint(
            "https://user:pass@internal-collector.example.com/"
        )); // userinfo
    }

    #[test]
    fn owner_registers_and_rotates_the_carriage_key() {
        let (s, cookie, tenant) = signed_in();
        let body = format!(r#"{{"tenant":"{tenant}","pubkey":"{KEY}"}}"#);
        let r = handle_set_carriage_key(&s, Some(&cookie), &body, T0);
        assert_eq!(r.status, 200);
        let org = crate::orgs::registry_entry(&s, &tenant).unwrap().unwrap();
        assert_eq!(org.carriage_pubkey.as_deref(), Some(KEY));
        // rotate to a different key
        let key2 = "bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55";
        let body2 = format!(r#"{{"tenant":"{tenant}","pubkey":"{key2}"}}"#);
        assert_eq!(
            handle_set_carriage_key(&s, Some(&cookie), &body2, T0).status,
            200
        );
        assert_eq!(
            crate::orgs::registry_entry(&s, &tenant)
                .unwrap()
                .unwrap()
                .carriage_pubkey
                .as_deref(),
            Some(key2)
        );
    }

    #[test]
    fn admin_can_manage_keys_but_a_user_cannot() {
        let (s, _owner, tenant) = signed_in();
        let admin = member_at(&s, &tenant, "admin@x.co", Role::Admin);
        let user = member_at(&s, &tenant, "user@x.co", Role::User);
        let body = format!(r#"{{"tenant":"{tenant}","pubkey":"{KEY}"}}"#);
        // Admin has ManageKeys
        assert_eq!(
            handle_set_carriage_key(&s, Some(&admin), &body, T0).status,
            200
        );
        // A plain User does not
        assert_eq!(
            handle_set_carriage_key(&s, Some(&user), &body, T0).status,
            403
        );
    }

    #[test]
    fn rejects_malformed_pubkey_before_touching_the_store() {
        let (s, cookie, tenant) = signed_in();
        let body = format!(r#"{{"tenant":"{tenant}","pubkey":"nothex"}}"#);
        assert_eq!(
            handle_set_carriage_key(&s, Some(&cookie), &body, T0).status,
            400
        );
        assert!(crate::orgs::registry_entry(&s, &tenant)
            .unwrap()
            .unwrap()
            .carriage_pubkey
            .is_none());
    }

    #[test]
    fn unauth_and_cross_tenant_and_bad_tenant_are_rejected() {
        let (s, cookie, tenant) = signed_in();
        let body = format!(r#"{{"tenant":"{tenant}","pubkey":"{KEY}"}}"#);
        // no cookie -> 401
        assert_eq!(handle_set_carriage_key(&s, None, &body, T0).status, 401);
        // a real session, but a tenant the caller is not a member of -> 404 (hides existence)
        let other = "00000000000000000000000000000000";
        let obody = format!(r#"{{"tenant":"{other}","pubkey":"{KEY}"}}"#);
        assert_eq!(
            handle_set_carriage_key(&s, Some(&cookie), &obody, T0).status,
            404
        );
        // malformed tenant -> 400
        let bbody = format!(r#"{{"tenant":"xyz","pubkey":"{KEY}"}}"#);
        assert_eq!(
            handle_set_carriage_key(&s, Some(&cookie), &bbody, T0).status,
            400
        );
    }

    #[test]
    fn owner_sets_the_otlp_endpoint() {
        let (s, cookie, tenant) = signed_in();
        let body = format!(r#"{{"tenant":"{tenant}","endpoint":"https://otlp.datadoghq.com"}}"#);
        assert_eq!(handle_set_otlp(&s, Some(&cookie), &body, T0).status, 200);
        assert_eq!(
            crate::orgs::registry_entry(&s, &tenant)
                .unwrap()
                .unwrap()
                .otlp_endpoint
                .as_deref(),
            Some("https://otlp.datadoghq.com")
        );
        // http is refused (telemetry must not leave in the clear)
        let bad = format!(r#"{{"tenant":"{tenant}","endpoint":"http://otlp.example.com"}}"#);
        assert_eq!(handle_set_otlp(&s, Some(&cookie), &bad, T0).status, 400);
    }
}
