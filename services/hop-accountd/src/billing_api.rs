//! The billing endpoints on the console surface, pure like `auth_api`: a session + RBAC gate, then a
//! plan -> Stripe Checkout / Billing Portal handoff. The socket layer writes the returned
//! [`AuthResponse`] out. Self-serve, no sales gate: every paid plan (Scale included) returns a hosted
//! Checkout URL the browser follows.
//!
//!   POST /billing/checkout {"tenant": "...", "plan": "usage|scale|developer"} -> 200 {url} | 200 {free}
//!   POST /billing/portal   {"tenant": "..."}                                  -> 200 {url}
//!
//! Both are Owner-only (`Permission::ManageBilling`) and scoped to a tenant the caller owns, so a
//! member cannot start billing for an org they do not control, nor for someone else's tenant.

use crate::auth_api::{json_field, session_from_cookie_header, AuthResponse};
use crate::billing::{Plan, PlanCatalog, StripeBilling};
use crate::domain::Permission;
use crate::store::Store;

/// Resolve the session to a user, then to their membership in the requested tenant, enforcing
/// `ManageBilling` (Owner). Returns the owned [`Org`] on success, or the ready `AuthResponse` to
/// return (401 unauthenticated, 400 bad tenant, 404 no such tenant / not a member, 403 not permitted).
fn authorize_billing(
    store: &dyn Store,
    cookie: Option<&str>,
    tenant_hex: &str,
    now_ms: u64,
) -> Result<(crate::domain::User, crate::domain::Org), AuthResponse> {
    let raw = session_from_cookie_header(cookie)
        .ok_or_else(|| AuthResponse::json(401, r#"{"error":"unauthenticated"}"#))?;
    let user = crate::session::validate_session(store, &raw, now_ms)
        .ok()
        .flatten()
        .ok_or_else(|| AuthResponse::json(401, r#"{"error":"unauthenticated"}"#))?;
    // Reject a malformed tenant before it reaches the store. Checked AFTER the session so an
    // unauthenticated caller always gets 401 and learns nothing about tenant shape or existence.
    if !crate::api::valid_tenant_hex(tenant_hex) {
        return Err(AuthResponse::json(400, r#"{"error":"bad_request"}"#));
    }
    let org = store
        .org_by_tenant(tenant_hex)
        .ok()
        .flatten()
        // A tenant the caller cannot see is indistinguishable from one that does not exist.
        .ok_or_else(|| AuthResponse::json(404, r#"{"error":"not_found"}"#))?;
    let role = store
        .membership(&user.id, &org.id)
        .ok()
        .flatten()
        .map(|m| m.role)
        .ok_or_else(|| AuthResponse::json(404, r#"{"error":"not_found"}"#))?;
    if !role.can(Permission::ManageBilling) {
        return Err(AuthResponse::json(403, r#"{"error":"forbidden"}"#));
    }
    Ok((user, org))
}

/// POST /billing/checkout. Owner picks a plan; free lands instantly, paid returns a hosted Checkout
/// URL. Ensures the tenant has a Stripe customer (creating + persisting one on first paid checkout),
/// so the registry's `stripe_customer` is written exactly when billing begins.
#[allow(clippy::too_many_arguments)]
pub fn handle_checkout(
    store: &dyn Store,
    billing: &StripeBilling,
    catalog: &PlanCatalog,
    console_base: &str,
    cookie: Option<&str>,
    body: &str,
    now_ms: u64,
) -> AuthResponse {
    let Some(tenant) = json_field(body, "tenant") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let Some(plan) = json_field(body, "plan").and_then(|p| Plan::parse(&p)) else {
        return AuthResponse::json(400, r#"{"error":"invalid_plan"}"#);
    };
    let (user, org) = match authorize_billing(store, cookie, &tenant, now_ms) {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    if !plan.is_paid() {
        // Developer is free, but "downgrade to Developer" is not a no-op if the tenant is actively
        // paying: cancelling a live subscription happens in the Billing Portal, so steer there
        // instead of falsely reporting success while Stripe keeps billing.
        if let Some(customer) = &org.stripe_customer {
            match billing.has_active_subscription(customer) {
                Ok(true) => {
                    return AuthResponse::json(
                        409,
                        r#"{"error":"active_subscription","manage":"portal"}"#,
                    )
                }
                Ok(false) => {}
                Err(_) => return AuthResponse::json(502, r#"{"error":"billing_upstream"}"#),
            }
        }
        return AuthResponse::json(200, r#"{"ok":true,"plan":"developer","free":true}"#);
    }
    // Ensure a Stripe customer, writing it into the registry the first time. create_customer is
    // idempotent per tenant and the write is set-if-absent, so racing first checkouts converge on a
    // single customer and the checkout below is built against the one actually persisted.
    let customer = match org.stripe_customer.clone() {
        Some(c) => c,
        None => {
            // The customer's email is the owning user's; the tenant metadata is what binds it in Hop.
            let created = match billing.create_customer(&user.email, &org.tenant_hex) {
                Ok(c) => c,
                Err(_) => return AuthResponse::json(502, r#"{"error":"billing_upstream"}"#),
            };
            match store.set_org_stripe_customer_if_absent(&org.id, &created) {
                Ok(persisted) => persisted,
                Err(_) => return AuthResponse::json(500, r#"{"error":"internal"}"#),
            }
        }
    };
    // Refuse a second checkout that would stack a duplicate subscription and double-bill. Plan
    // changes are a Portal action (Stripe prorates upgrades/downgrades natively). Fail closed on a
    // read error: better to block one checkout than to risk a double subscription.
    match billing.has_active_subscription(&customer) {
        Ok(true) => {
            return AuthResponse::json(409, r#"{"error":"active_subscription","manage":"portal"}"#)
        }
        Ok(false) => {}
        Err(_) => return AuthResponse::json(502, r#"{"error":"billing_upstream"}"#),
    }
    let base = console_base.trim_end_matches('/');
    let success = format!("{base}/billing?checkout=success");
    let cancel = format!("{base}/billing?checkout=cancel");
    match billing.create_checkout(catalog, &customer, &org.tenant_hex, plan, &success, &cancel) {
        Ok(url) => AuthResponse::json(
            200,
            &format!(r#"{{"url":{}}}"#, serde_json::Value::String(url)),
        ),
        Err(_) => AuthResponse::json(502, r#"{"error":"billing_upstream"}"#),
    }
}

/// POST /billing/portal. Opens the hosted Billing Portal for the tenant's customer (Owner-only). 409
/// if the tenant has no customer yet (nothing to manage until a paid checkout has run).
pub fn handle_portal(
    store: &dyn Store,
    billing: &StripeBilling,
    console_base: &str,
    cookie: Option<&str>,
    body: &str,
    now_ms: u64,
) -> AuthResponse {
    let Some(tenant) = json_field(body, "tenant") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let (_user, org) = match authorize_billing(store, cookie, &tenant, now_ms) {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let Some(customer) = org.stripe_customer.clone() else {
        return AuthResponse::json(409, r#"{"error":"no_billing_yet"}"#);
    };
    let return_url = format!("{}/billing", console_base.trim_end_matches('/'));
    match billing.create_portal(&customer, &return_url) {
        Ok(url) => AuthResponse::json(
            200,
            &format!(r#"{{"url":{}}}"#, serde_json::Value::String(url)),
        ),
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
    use crate::stripe_api::Transport;
    use std::cell::RefCell;

    const T0: u64 = 1_000_000;
    const BASE: &str = "https://dashboard.hopme.sh";

    fn catalog() -> PlanCatalog {
        PlanCatalog::parse("price_u", "price_s", "price_base").unwrap()
    }

    struct FakeTransport {
        resp: (u16, String),
        posts: RefCell<usize>,
        /// What GET /v1/subscriptions returns: an active sub (blocks a second checkout) or none.
        subs_active: bool,
    }
    impl Transport for FakeTransport {
        fn get(&self, url: &str) -> Result<(u16, String), String> {
            if url.contains("/subscriptions") {
                let body = if self.subs_active {
                    r#"{"data":[{"id":"sub_1","status":"active"}]}"#
                } else {
                    r#"{"data":[]}"#
                };
                return Ok((200, body.into()));
            }
            Ok((200, "{}".into()))
        }
        fn post_form(
            &self,
            _u: &str,
            _b: &str,
            _key: Option<&str>,
        ) -> Result<(u16, String), String> {
            *self.posts.borrow_mut() += 1;
            Ok(self.resp.clone())
        }
    }
    fn fake() -> FakeTransport {
        FakeTransport {
            resp: (
                200,
                r#"{"id":"cus_new","url":"https://checkout.stripe.com/s"}"#.into(),
            ),
            posts: RefCell::new(0),
            subs_active: false,
        }
    }
    fn fake_subscribed() -> FakeTransport {
        FakeTransport {
            subs_active: true,
            ..fake()
        }
    }

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

    #[test]
    fn owner_checkout_creates_customer_writes_registry_and_returns_url() {
        let (s, cookie, tenant) = signed_in();
        let t = fake();
        let bill = StripeBilling { transport: &t };
        let body = format!(r#"{{"tenant":"{tenant}","plan":"usage"}}"#);
        let r = handle_checkout(&s, &bill, &catalog(), BASE, Some(&cookie), &body, T0);
        assert_eq!(r.status, 200);
        assert!(r.body.contains("https://checkout.stripe.com/s"));
        // customer was written into the registry
        let org = crate::orgs::registry_entry(&s, &tenant).unwrap().unwrap();
        assert_eq!(org.stripe_customer.as_deref(), Some("cus_new"));
        // 2 upstream posts: create customer + create checkout
        assert_eq!(*t.posts.borrow(), 2);
    }

    #[test]
    fn second_checkout_reuses_the_existing_customer() {
        let (s, cookie, tenant) = signed_in();
        let t = fake();
        let bill = StripeBilling { transport: &t };
        let body = format!(r#"{{"tenant":"{tenant}","plan":"usage"}}"#);
        handle_checkout(&s, &bill, &catalog(), BASE, Some(&cookie), &body, T0);
        *t.posts.borrow_mut() = 0;
        handle_checkout(&s, &bill, &catalog(), BASE, Some(&cookie), &body, T0);
        assert_eq!(
            *t.posts.borrow(),
            1,
            "reuses customer: only the checkout post"
        );
    }

    #[test]
    fn developer_plan_is_free_no_upstream_call() {
        let (s, cookie, tenant) = signed_in();
        let t = fake();
        let bill = StripeBilling { transport: &t };
        let body = format!(r#"{{"tenant":"{tenant}","plan":"developer"}}"#);
        let r = handle_checkout(&s, &bill, &catalog(), BASE, Some(&cookie), &body, T0);
        assert_eq!(r.status, 200);
        assert!(r.body.contains(r#""free":true"#));
        assert_eq!(*t.posts.borrow(), 0);
    }

    #[test]
    fn non_owner_and_other_tenant_are_rejected() {
        let (s, _owner_cookie, tenant) = signed_in();
        // a second user who is only a User of the org
        let member = login_or_create(&s, "member@x.co", T0).unwrap();
        let org = s.org_by_tenant(&tenant).unwrap().unwrap();
        s.add_membership(&Membership {
            user_id: member.user.id.clone(),
            org_id: org.id.clone(),
            role: Role::User,
        })
        .unwrap();
        let mcookie = {
            let c = set_cookie(&member.session_raw, 3600);
            let raw = c.split(['=', ';']).nth(1).unwrap().to_string();
            format!("__Host-hop_session={raw}")
        };
        let t = fake();
        let bill = StripeBilling { transport: &t };
        let body = format!(r#"{{"tenant":"{tenant}","plan":"usage"}}"#);
        // a User cannot manage billing
        assert_eq!(
            handle_checkout(&s, &bill, &catalog(), BASE, Some(&mcookie), &body, T0).status,
            403
        );
        // an unknown tenant is 404, no upstream call
        let bad = r#"{"tenant":"00000000000000000000000000000000","plan":"usage"}"#;
        assert_eq!(
            handle_checkout(&s, &bill, &catalog(), BASE, Some(&mcookie), bad, T0).status,
            404
        );
        // no cookie is 401
        assert_eq!(
            handle_checkout(&s, &bill, &catalog(), BASE, None, &body, T0).status,
            401
        );
        assert_eq!(*t.posts.borrow(), 0, "no upstream on any rejected request");
    }

    #[test]
    fn portal_requires_an_existing_customer() {
        let (s, cookie, tenant) = signed_in();
        let t = fake();
        let bill = StripeBilling { transport: &t };
        let body = format!(r#"{{"tenant":"{tenant}"}}"#);
        // no customer yet -> 409
        assert_eq!(
            handle_portal(&s, &bill, BASE, Some(&cookie), &body, T0).status,
            409
        );
        // after a paid checkout mints one, the portal opens
        let cbody = format!(r#"{{"tenant":"{tenant}","plan":"usage"}}"#);
        handle_checkout(&s, &bill, &catalog(), BASE, Some(&cookie), &cbody, T0);
        let r = handle_portal(&s, &bill, BASE, Some(&cookie), &body, T0);
        assert_eq!(r.status, 200);
        assert!(r.body.contains("https://checkout.stripe.com/s"));
    }

    #[test]
    fn active_subscription_blocks_a_second_checkout() {
        // A tenant that already pays cannot start a second Checkout (that would double-subscribe);
        // it is steered to the Portal for plan changes. No checkout post is made.
        let (s, cookie, tenant) = signed_in();
        let org = s.org_by_tenant(&tenant).unwrap().unwrap();
        s.set_org_stripe_customer(&org.id, "cus_live").unwrap();
        let t = fake_subscribed();
        let bill = StripeBilling { transport: &t };
        let body = format!(r#"{{"tenant":"{tenant}","plan":"scale"}}"#);
        let r = handle_checkout(&s, &bill, &catalog(), BASE, Some(&cookie), &body, T0);
        assert_eq!(r.status, 409);
        assert!(r.body.contains("active_subscription") && r.body.contains("portal"));
        assert_eq!(
            *t.posts.borrow(),
            0,
            "no checkout created when already subscribed"
        );
    }

    #[test]
    fn developer_downgrade_while_subscribed_steers_to_portal() {
        // "Downgrade to Developer" must not silently claim success while a paid subscription keeps
        // billing: it 409s to the Portal (where cancellation actually happens).
        let (s, cookie, tenant) = signed_in();
        let org = s.org_by_tenant(&tenant).unwrap().unwrap();
        s.set_org_stripe_customer(&org.id, "cus_live").unwrap();
        let t = fake_subscribed();
        let bill = StripeBilling { transport: &t };
        let body = format!(r#"{{"tenant":"{tenant}","plan":"developer"}}"#);
        let r = handle_checkout(&s, &bill, &catalog(), BASE, Some(&cookie), &body, T0);
        assert_eq!(r.status, 409);
        assert!(r.body.contains("active_subscription"));
        // ...but with no active subscription, Developer is a clean free no-op.
        let t2 = fake();
        let bill2 = StripeBilling { transport: &t2 };
        let r2 = handle_checkout(&s, &bill2, &catalog(), BASE, Some(&cookie), &body, T0);
        assert_eq!(r2.status, 200);
        assert!(r2.body.contains(r#""free":true"#));
    }

    #[test]
    fn first_checkout_binds_to_the_persisted_customer_not_a_racing_duplicate() {
        // Simulate a race that already wrote a customer: the set-if-absent write keeps the first one,
        // and the checkout is built against THAT customer, never the just-created duplicate.
        let (s, cookie, tenant) = signed_in();
        let org = s.org_by_tenant(&tenant).unwrap().unwrap();
        // A concurrent request won the race and persisted cus_first.
        let persisted = s
            .set_org_stripe_customer_if_absent(&org.id, "cus_first")
            .unwrap();
        assert_eq!(persisted, "cus_first");
        // A second write (as our handler would attempt with its own created id) does NOT overwrite.
        let still = s
            .set_org_stripe_customer_if_absent(&org.id, "cus_second")
            .unwrap();
        assert_eq!(
            still, "cus_first",
            "set-if-absent never overwrites the winner"
        );
        // And a checkout now reuses cus_first (customer already set: no create post).
        let t = fake();
        let bill = StripeBilling { transport: &t };
        let body = format!(r#"{{"tenant":"{tenant}","plan":"usage"}}"#);
        assert_eq!(
            handle_checkout(&s, &bill, &catalog(), BASE, Some(&cookie), &body, T0).status,
            200
        );
        assert_eq!(
            *t.posts.borrow(),
            1,
            "customer reused: only the checkout post"
        );
    }

    #[test]
    fn malformed_tenant_is_a_400() {
        let (s, cookie, _tenant) = signed_in();
        let t = fake();
        let bill = StripeBilling { transport: &t };
        // 'xyz' is not 32 lowercase-hex chars.
        let body = r#"{"tenant":"xyz","plan":"usage"}"#;
        assert_eq!(
            handle_checkout(&s, &bill, &catalog(), BASE, Some(&cookie), body, T0).status,
            400
        );
        assert_eq!(*t.posts.borrow(), 0, "no upstream on a malformed tenant");
    }
}
