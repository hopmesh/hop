//! Cookie-authed console READ endpoints, pure like the rest: a session gate, then a read over the
//! store (and, for usage, the fleet's Firestore ledger). The socket layer writes the [`AuthResponse`].
//!
//!   GET /console/overview            -> 200 {user, workspaces:[{tenant,name,role,hasCarriageKey,hasOtlp}]}
//!   GET /console/invoices?tenant=..   -> 200 {invoices:[..]}   (Owner/Admin: ViewInvoices)
//!   GET /console/card?tenant=..       -> 200 {card:{brand,last4,..}|null}
//!
//! `overview` is the dashboard's bootstrap: it turns a session into the caller's workspaces + their
//! role in each, which every tenant-scoped view (billing, keys, team, usage) needs to know first. The
//! billing reads run the SAME tenant-scoped RBAC gate as everything else (ViewInvoices, Owner+Admin)
//! and only ever touch the caller's own Stripe customer, so an invoice/card is never cross-tenant.

use crate::auth_api::{authorize_tenant, session_from_cookie_header, AuthResponse};
use crate::domain::Permission;
use crate::store::Store;
use crate::stripe_api::{self, Transport};

/// GET /console/overview. The signed-in user + every workspace they belong to, with their role and a
/// hint at whether each has a carriage key / OTLP endpoint set (so the dashboard can nudge setup).
pub fn handle_overview(store: &dyn Store, cookie: Option<&str>, now_ms: u64) -> AuthResponse {
    let Some(raw) = session_from_cookie_header(cookie) else {
        return AuthResponse::json(401, r#"{"error":"unauthenticated"}"#);
    };
    let user = match crate::session::validate_session(store, &raw, now_ms) {
        Ok(Some(u)) => u,
        Ok(None) => return AuthResponse::json(401, r#"{"error":"unauthenticated"}"#),
        Err(_) => return AuthResponse::json(500, r#"{"error":"internal"}"#),
    };
    let memberships = match store.memberships_for_user(&user.id) {
        Ok(m) => m,
        Err(_) => return AuthResponse::json(500, r#"{"error":"internal"}"#),
    };
    let mut workspaces = Vec::new();
    for m in memberships {
        // A membership whose org has vanished is skipped rather than failing the whole overview.
        if let Ok(Some(org)) = store.org_by_id(&m.org_id) {
            workspaces.push(serde_json::json!({
                "tenant": org.tenant_hex,
                "name": org.name,
                "role": m.role.as_str(),
                "hasCarriageKey": org.carriage_pubkey.is_some(),
                "hasOtlp": org.otlp_endpoint.is_some(),
            }));
        }
    }
    let body = serde_json::json!({
        "user": { "id": user.id, "email": user.email },
        "workspaces": workspaces,
    });
    AuthResponse::json(200, &body.to_string())
}

/// POST /console/orgs {"name": "..."}. Create a new workspace the signed-in user OWNS and return it in
/// the same shape as an overview workspace, so the client can drop straight into it. Any authenticated
/// user may create a workspace: there is no cap (billing is per-tenant and usage-metered, so an empty
/// workspace costs nothing). The name is trimmed and length-bounded before any write.
pub fn handle_create_org(
    store: &dyn Store,
    cookie: Option<&str>,
    body: &str,
    now_ms: u64,
) -> AuthResponse {
    let Some(raw) = session_from_cookie_header(cookie) else {
        return AuthResponse::json(401, r#"{"error":"unauthenticated"}"#);
    };
    let user = match crate::session::validate_session(store, &raw, now_ms) {
        Ok(Some(u)) => u,
        Ok(None) => return AuthResponse::json(401, r#"{"error":"unauthenticated"}"#),
        Err(_) => return AuthResponse::json(500, r#"{"error":"internal"}"#),
    };
    let name = crate::auth_api::json_field(body, "name").unwrap_or_default();
    let name = name.trim();
    if name.is_empty() || name.chars().count() > crate::orgs::MAX_ORG_NAME {
        return AuthResponse::json(400, r#"{"error":"bad_name"}"#);
    }
    match crate::orgs::create_named_org(store, &user.id, name, now_ms) {
        Ok(org) => {
            let body = serde_json::json!({
                "tenant": org.tenant_hex,
                "name": org.name,
                "role": "owner",
                "hasCarriageKey": false,
                "hasOtlp": false,
            });
            AuthResponse::json(200, &body.to_string())
        }
        Err(_) => AuthResponse::json(500, r#"{"error":"internal"}"#),
    }
}

/// Resolve the tenant to its Stripe customer under the `ViewInvoices` gate (Owner+Admin), or the
/// ready error response / a "no billing yet" signal. Shared by the invoice + card reads so both gate
/// identically and neither can read another tenant's Stripe data.
fn billing_customer(
    store: &dyn Store,
    cookie: Option<&str>,
    tenant: &str,
    now_ms: u64,
) -> Result<Option<String>, AuthResponse> {
    let (_user, org) = authorize_tenant(store, cookie, tenant, Permission::ViewInvoices, now_ms)?;
    Ok(org.stripe_customer)
}

/// GET /console/invoices?tenant=.. The tenant's Stripe invoices (Owner/Admin). An org with no customer
/// yet (never paid) returns an empty list, not an error.
pub fn handle_invoices(
    store: &dyn Store,
    transport: &dyn Transport,
    cookie: Option<&str>,
    tenant: &str,
    now_ms: u64,
) -> AuthResponse {
    let customer = match billing_customer(store, cookie, tenant, now_ms) {
        Ok(Some(c)) => c,
        Ok(None) => return AuthResponse::json(200, r#"{"invoices":[]}"#),
        Err(resp) => return resp,
    };
    if !stripe_api::valid_stripe_id(&customer) {
        return AuthResponse::json(500, r#"{"error":"internal"}"#);
    }
    let (s, b) = match transport.get(&stripe_api::invoices_list_url(&customer)) {
        Ok(x) => x,
        Err(_) => return AuthResponse::json(502, r#"{"error":"billing_upstream"}"#),
    };
    match stripe_api::ok_or_err("invoices.list", s, &b)
        .and_then(|body| stripe_api::parse_invoice_list(&body))
    {
        Ok(list) => AuthResponse::json(200, &serde_json::json!({ "invoices": list }).to_string()),
        Err(_) => AuthResponse::json(502, r#"{"error":"billing_upstream"}"#),
    }
}

/// GET /console/subscription?tenant=.. The tenant's live plan + subscription status (Owner/Admin).
/// A free/unbilled tenant (no customer, or no subscription) reads as the Developer plan with no
/// status. The plan is derived live from Stripe; a stored copy (webhook) is a follow-up.
pub fn handle_subscription(
    store: &dyn Store,
    billing: &crate::billing::StripeBilling,
    catalog: &crate::billing::PlanCatalog,
    cookie: Option<&str>,
    tenant: &str,
    now_ms: u64,
) -> AuthResponse {
    let customer = match billing_customer(store, cookie, tenant, now_ms) {
        Ok(Some(c)) => c,
        Ok(None) => {
            return AuthResponse::json(
                200,
                r#"{"plan":"developer","status":"none","currentPeriodEnd":null,"active":false}"#,
            )
        }
        Err(resp) => return resp,
    };
    match billing.current_subscription(catalog, &customer) {
        Ok(Some(sub)) => {
            let active = matches!(sub.status.as_str(), "active" | "trialing");
            AuthResponse::json(
                200,
                &serde_json::json!({
                    "plan": sub.plan.as_str(),
                    "status": sub.status,
                    "currentPeriodEnd": sub.current_period_end,
                    "active": active,
                })
                .to_string(),
            )
        }
        Ok(None) => AuthResponse::json(
            200,
            r#"{"plan":"developer","status":"none","currentPeriodEnd":null,"active":false}"#,
        ),
        Err(_) => AuthResponse::json(502, r#"{"error":"billing_upstream"}"#),
    }
}

/// GET /console/card?tenant=.. The tenant's default card on file (Owner/Admin), or null. Used for the
/// "Visa ending 4242" display; never returns the full PAN (Stripe only ever exposes brand + last4).
pub fn handle_card(
    store: &dyn Store,
    transport: &dyn Transport,
    cookie: Option<&str>,
    tenant: &str,
    now_ms: u64,
) -> AuthResponse {
    let customer = match billing_customer(store, cookie, tenant, now_ms) {
        Ok(Some(c)) => c,
        Ok(None) => return AuthResponse::json(200, r#"{"card":null}"#),
        Err(resp) => return resp,
    };
    if !stripe_api::valid_stripe_id(&customer) {
        return AuthResponse::json(500, r#"{"error":"internal"}"#);
    }
    let (s, b) = match transport.get(&stripe_api::payment_methods_url(&customer)) {
        Ok(x) => x,
        Err(_) => return AuthResponse::json(502, r#"{"error":"billing_upstream"}"#),
    };
    match stripe_api::ok_or_err("payment_methods.list", s, &b)
        .and_then(|body| stripe_api::parse_card(&body))
    {
        Ok(card) => AuthResponse::json(200, &serde_json::json!({ "card": card }).to_string()),
        Err(_) => AuthResponse::json(502, r#"{"error":"billing_upstream"}"#),
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

    fn signed_in() -> (MemStore, String, String) {
        let s = MemStore::new();
        let out = login_or_create(&s, "owner@x.co", T0).unwrap();
        let c = set_cookie(&out.session_raw, 3600);
        let raw = c.split(['=', ';']).nth(1).unwrap().to_string();
        let hdr = format!("__Host-hop_session={raw}");
        let org = ensure_personal_workspace(&s, &out.user.id, "owner@x.co", T0).unwrap();
        (s, hdr, org.tenant_hex)
    }

    #[test]
    fn overview_returns_the_users_workspaces_with_role() {
        let (s, cookie, tenant) = signed_in();
        let r = handle_overview(&s, Some(&cookie), T0);
        assert_eq!(r.status, 200);
        let v: serde_json::Value = serde_json::from_str(&r.body).unwrap();
        assert_eq!(v["user"]["email"], "owner@x.co");
        let ws = v["workspaces"].as_array().unwrap();
        assert_eq!(ws.len(), 1);
        assert_eq!(ws[0]["tenant"], tenant);
        assert_eq!(ws[0]["role"], "owner");
        assert_eq!(ws[0]["hasCarriageKey"], false);
    }

    #[test]
    fn overview_lists_every_membership() {
        let (s, cookie, _tenant) = signed_in();
        // the user is added to a second org as Admin
        let user = s.user_by_email("owner@x.co").unwrap().unwrap();
        let second = ensure_personal_workspace(&s, "u2", "other@x.co", T0).unwrap();
        s.add_membership(&Membership {
            user_id: user.id,
            org_id: second.id,
            role: Role::Admin,
        })
        .unwrap();
        let r = handle_overview(&s, Some(&cookie), T0);
        let v: serde_json::Value = serde_json::from_str(&r.body).unwrap();
        assert_eq!(v["workspaces"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn overview_requires_a_session() {
        let (s, _c, _t) = signed_in();
        assert_eq!(handle_overview(&s, None, T0).status, 401);
        assert_eq!(
            handle_overview(&s, Some("__Host-hop_session=bogus"), T0).status,
            401
        );
    }

    struct FakeTransport(u16, String);
    impl Transport for FakeTransport {
        fn get(&self, _u: &str) -> Result<(u16, String), String> {
            Ok((self.0, self.1.clone()))
        }
        fn post_form(&self, _u: &str, _b: &str, _k: Option<&str>) -> Result<(u16, String), String> {
            Ok((200, "{}".into()))
        }
    }

    #[test]
    fn invoices_gate_and_no_customer_and_read() {
        let (s, cookie, tenant) = signed_in();
        let t = FakeTransport(200, r#"{"data":[]}"#.into());
        // owner, no customer yet -> empty list (not an error)
        let r = handle_invoices(&s, &t, Some(&cookie), &tenant, T0);
        assert_eq!(r.status, 200);
        assert!(r.body.contains(r#""invoices":[]"#));
        // a plain User lacks ViewInvoices -> 403
        let member = login_or_create(&s, "member@x.co", T0).unwrap();
        let org = s.org_by_tenant(&tenant).unwrap().unwrap();
        s.add_membership(&Membership {
            user_id: member.user.id,
            org_id: org.id.clone(),
            role: Role::User,
        })
        .unwrap();
        let mc = {
            let c = set_cookie(&member.session_raw, 3600);
            let raw = c.split(['=', ';']).nth(1).unwrap().to_string();
            format!("__Host-hop_session={raw}")
        };
        assert_eq!(handle_invoices(&s, &t, Some(&mc), &tenant, T0).status, 403);
        // with a customer, a real invoice list comes back
        s.set_org_stripe_customer(&org.id, "cus_live").unwrap();
        let t2 = FakeTransport(
            200,
            r#"{"data":[{"id":"in_1","status":"paid","amount_due":42610,"currency":"usd","created":1}]}"#
                .into(),
        );
        let r2 = handle_invoices(&s, &t2, Some(&cookie), &tenant, T0);
        assert_eq!(r2.status, 200);
        assert!(r2.body.contains("in_1"));
    }

    #[test]
    fn card_is_null_without_a_customer() {
        let (s, cookie, tenant) = signed_in();
        let t = FakeTransport(200, r#"{"data":[]}"#.into());
        let r = handle_card(&s, &t, Some(&cookie), &tenant, T0);
        assert_eq!(r.status, 200);
        assert!(r.body.contains(r#""card":null"#));
    }

    #[test]
    fn subscription_reads_developer_without_a_customer_and_the_plan_with_one() {
        use crate::billing::{PlanCatalog, StripeBilling};
        let (s, cookie, tenant) = signed_in();
        let cat = PlanCatalog::parse("price_reach", "price_reach", "price_base").unwrap();
        // no customer -> developer / not active, no upstream needed
        let t = FakeTransport(200, "{}".into());
        let bill = StripeBilling { transport: &t };
        let r = handle_subscription(&s, &bill, &cat, Some(&cookie), &tenant, T0);
        assert_eq!(r.status, 200);
        assert!(r.body.contains(r#""plan":"developer""#) && r.body.contains(r#""active":false"#));
        // with a customer + an active Scale subscription -> plan scale, active
        let org = s.org_by_tenant(&tenant).unwrap().unwrap();
        s.set_org_stripe_customer(&org.id, "cus_live").unwrap();
        let sub = r#"{"data":[{"status":"active","current_period_end":1893456000,"items":{"data":[{"price":{"id":"price_base"}}]}}]}"#;
        let t2 = FakeTransport(200, sub.into());
        let bill2 = StripeBilling { transport: &t2 };
        let r2 = handle_subscription(&s, &bill2, &cat, Some(&cookie), &tenant, T0);
        assert!(r2.body.contains(r#""plan":"scale""#) && r2.body.contains(r#""active":true"#));
        assert!(r2.body.contains("1893456000"));
    }
}
