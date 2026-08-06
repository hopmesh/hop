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

/// SVC-002: is `ip` a target the telemetry collector must NEVER be pointed at? The v4 arm is a
/// blocklist of every non-global range; the v6 arm is an ALLOWLIST (global unicast `2000::/3` only),
/// which is what closes the bypass class this function exists for. The old validator tested only
/// `is_loopback`/`is_unspecified`/`is_multicast`/`fc00::/7`/`fe80::/10`, and every alternate spelling
/// of an internal v4 address has a segment-0 that misses all five: IPv4-mapped `::ffff:169.254.169.254`,
/// IPv4-compatible `::169.254.169.254`, and NAT64 `64:ff9b::169.254.169.254` all passed. Requiring
/// `2000::/3` rejects those three by construction (their segment 0 is `0x0000`/`0x0064`), and the two
/// translation ranges INSIDE `2000::/3` (6to4 `2002::/16`, Teredo `2001::/32`) are folded through the
/// v4 arm on their embedded address, so `2002:a9fe:a9fe::` (169.254.169.254 in 6to4) is refused too.
///
/// The same fold exists in `hop-gateway` (`ip_is_forbidden`, services-r18-10); these are deliberate
/// twins in two crates that share no dependency, so a change to one belongs in the other.
fn ip_is_forbidden(ip: std::net::IpAddr) -> bool {
    use std::net::IpAddr;
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_documentation()
                || v4.is_unspecified()
                || v4.is_multicast()
                // "This network" 0.0.0.0/8 and carrier-grade NAT 100.64.0.0/10.
                || o[0] == 0
                || (o[0] == 100 && (o[1] & 0xc0) == 64)
                // Benchmarking 198.18.0.0/15 and reserved 240.0.0.0/4.
                || (o[0] == 198 && (o[1] & 0xfe) == 18)
                || (o[0] & 0xf0) == 240
        }
        IpAddr::V6(v6) => {
            let seg = v6.segments();
            // Fail closed outside global unicast: loopback, unspecified, multicast, unique-local,
            // link-local, IPv4-mapped, IPv4-compatible and NAT64 all live outside 2000::/3.
            if (seg[0] & 0xe000) != 0x2000 {
                return true;
            }
            // Documentation 2001:db8::/32.
            if seg[0] == 0x2001 && seg[1] == 0x0db8 {
                return true;
            }
            // 6to4 2002::/16 carries its v4 in segments 1-2; Teredo 2001::/32 carries the client's
            // v4 (obfuscated, hence the complement) in segments 6-7. Vet the embedded address.
            let embedded = if seg[0] == 0x2002 {
                Some(std::net::Ipv4Addr::from(
                    ((seg[1] as u32) << 16) | seg[2] as u32,
                ))
            } else if seg[0] == 0x2001 && seg[1] == 0x0000 {
                Some(std::net::Ipv4Addr::from(
                    !(((seg[6] as u32) << 16) | seg[7] as u32),
                ))
            } else {
                None
            };
            embedded
                .map(IpAddr::V4)
                .map(ip_is_forbidden)
                .unwrap_or(false)
        }
    }
}

/// A managed-OTLP forward endpoint the fleet's telemetry collector will POST this tenant's telemetry
/// to. This is the WRITE-TIME half of the SSRF boundary, and it is deliberately not the only half:
/// the collector vets the resolved connect address independently (`hop-telemetryd`'s
/// `ReqwestOtlpTransport`), because no string check can see where a hostname RESOLVES. This half is
/// strict: `https://` only (telemetry never leaves in the clear), bounded, no whitespace/control
/// bytes, a non-empty host, NO embedded credentials, an IP literal that is global unicast in EVERY
/// spelling ([`ip_is_forbidden`] normalizes IPv4-mapped/compatible/NAT64/6to4/Teredo forms, so
/// `[::ffff:169.254.169.254]` is refused exactly like `169.254.169.254`), and a hostname that is not
/// internal-only (`localhost`, a bare name with no dot, a `.local`/`.internal` suffix) and whose
/// rightmost label is not all digits (no real TLD is, so this refuses every alternate spelling of a
/// dotted IPv4 literal, e.g. the octal `0177.0.0.1`, which used to slip past the IP arm entirely and
/// land in the hostname arm).
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
    // An IP literal must be a global-unicast address in every spelling it can be written in.
    if let Ok(ip) = host.parse::<std::net::IpAddr>() {
        return !ip_is_forbidden(ip);
    }
    // A hostname must look like a public DNS name: dotted, no internal-only suffix, no empty label,
    // and a rightmost label carrying at least one non-digit. That last clause is what refuses the
    // alternate IPv4 spellings the parse above does not accept (`0177.0.0.1`, `0x7f.0.0.1`,
    // `2130706433.1`): a registry TLD is never all digits, so nothing legitimate is lost.
    let lower = host.to_ascii_lowercase();
    let tld = lower.rsplit('.').next().unwrap_or("");
    lower.contains('.')
        && lower != "localhost"
        && !lower.ends_with(".localhost")
        && !lower.ends_with(".local")
        && !lower.ends_with(".internal")
        && !lower.split('.').any(str::is_empty)
        && !tld.bytes().all(|b| b.is_ascii_digit())
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
        assert!(valid_otlp_endpoint("https://93.184.216.34:443/v1")); // public IP literal
        assert!(valid_otlp_endpoint("https://[2606:4700:4700::1111]/v1")); // public IPv6 literal
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

    /// SVC-002. Every literal spelling of an internal address the parser accepts must be refused.
    /// Before the [`ip_is_forbidden`] normalization, each of these returned TRUE and landed in the
    /// tenant registry: the v6 arm tested only `is_loopback`/`is_unspecified`/`is_multicast`/
    /// `fc00::/7`/`fe80::/10`, which every embedded-v4 form misses, and the octal spelling failed the
    /// IP parse entirely and passed the hostname arm (it has a dot and no internal suffix).
    #[test]
    fn otlp_rejects_every_mapped_and_translated_spelling_of_an_internal_target() {
        for url in [
            // IPv4-mapped: the metadata service, loopback, RFC1918.
            "https://[::ffff:169.254.169.254]/",
            "https://[::ffff:127.0.0.1]/v1",
            "https://[::ffff:10.0.0.5]/",
            "https://[::ffff:169.254.169.254]:4318/v1/metrics",
            // IPv4-compatible (deprecated, still parses).
            "https://[::169.254.169.254]/",
            "https://[::127.0.0.1]/",
            // NAT64 well-known prefix.
            "https://[64:ff9b::169.254.169.254]/",
            "https://[64:ff9b::a00:5]/",
            // 6to4 and Teredo, both INSIDE 2000::/3, carrying an internal v4.
            "https://[2002:a9fe:a9fe::]/",
            "https://[2002:7f00:1::]/",
            "https://[2001:0:0:0:0:0:5601:5601]/", // Teredo, client v4 = 169.254.169.254
            // Alternate dotted spellings of 127.0.0.1 that the IpAddr parse rejects.
            "https://0177.0.0.1/",
            "https://0x7f.0.0.1/",
            "https://2130706433.1/",
            // Other non-global v4 ranges the old blocklist missed.
            "https://100.64.0.1/",   // carrier-grade NAT
            "https://0.0.0.0/",      // this network
            "https://198.18.0.1/",   // benchmarking
            "https://240.0.0.1/",    // reserved
            "https://192.0.2.10/",   // documentation (TEST-NET-1)
            "https://203.0.113.10/", // documentation (TEST-NET-3)
            // Non-global v6 outside 2000::/3, plus documentation inside it.
            "https://[::]/",
            "https://[fe80::1]/",
            "https://[ff02::1]/",
            "https://[2001:db8::1]/",
            // Empty labels cannot form a resolvable public name.
            "https://collector..example.com/",
        ] {
            assert!(!valid_otlp_endpoint(url), "must be refused: {url}");
        }
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
