//! The Stripe WRITE layer for self-serve signup + billing management, pure like `stripe_api` (its
//! read counterpart): URL builders, form-body builders, and response parsers behind the same
//! [`Transport`] seam, so every request is unit-tested with no network. The reqwest `Transport` under
//! `--features live` carries these too.
//!
//! Self-serve, no sales gate: EVERY plan (including the committed Scale tier) checks out through
//! Stripe Checkout. The three plans meter identically (see the pricing page); they differ only in
//! which prices ride the subscription. `PlanCatalog` maps a plan to its Stripe price ids, read from
//! env, so no price id is ever hard-coded.

use crate::stripe_api::{ok_or_err, valid_stripe_id, Transport};

/// The three self-serve plans. All meter the same two ways; higher tiers add commitment + support.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Plan {
    /// Free forever for personal projects: a customer, no subscription, no card.
    Developer,
    /// Pay as you go: a subscription of the metered reach + telemetry prices.
    Usage,
    /// Committed, self-serve: the committed base price plus the metered prices, volume-discounted.
    Scale,
}

impl Plan {
    pub fn parse(s: &str) -> Option<Plan> {
        match s.to_ascii_lowercase().as_str() {
            "developer" => Some(Plan::Developer),
            "usage" => Some(Plan::Usage),
            "scale" => Some(Plan::Scale),
            _ => None,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Plan::Developer => "developer",
            Plan::Usage => "usage",
            Plan::Scale => "scale",
        }
    }
    /// Whether the plan needs a card / Checkout. Developer is free (customer only).
    pub fn is_paid(self) -> bool {
        !matches!(self, Plan::Developer)
    }
}

/// One Checkout line item: a Stripe price, and a quantity for licensed prices (metered prices carry
/// no quantity, Stripe rejects one on a metered price).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LineItem {
    pub price: String,
    pub quantity: Option<u32>,
}

/// The Stripe price ids per paid plan, from env, so ids live in config, never code. Usage rides the
/// metered prices; Scale rides an optional committed base price (quantity 1) plus the same metered
/// prices. `HOP_STRIPE_USAGE_PRICES` / `HOP_STRIPE_SCALE_METERED_PRICES` are comma-separated metered
/// price ids; `HOP_STRIPE_SCALE_BASE_PRICE` is the single committed price.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PlanCatalog {
    pub usage_metered: Vec<String>,
    pub scale_metered: Vec<String>,
    pub scale_base: Option<String>,
}

impl PlanCatalog {
    /// Parse a catalog from raw env values. Returns `None` if a paid plan has no usable prices, OR if
    /// any configured price is malformed, so a half-configured billing surface refuses to offer a
    /// broken Checkout rather than silently dropping a meter and under-billing.
    pub fn parse(usage: &str, scale_metered: &str, scale_base: &str) -> Option<PlanCatalog> {
        // A comma-separated price list. Empty segments (a stray/trailing comma) are ignored as
        // formatting noise, but any NON-empty segment that is not a valid Stripe id fails the whole
        // parse: a typo'd price must refuse the catalog, never quietly drop a meter.
        let ids = |s: &str| -> Option<Vec<String>> {
            let mut out = Vec::new();
            for seg in s.split(',') {
                let seg = seg.trim();
                if seg.is_empty() {
                    continue;
                }
                if !valid_stripe_id(seg) {
                    return None;
                }
                out.push(seg.to_string());
            }
            Some(out)
        };
        let usage_metered = ids(usage)?;
        let scale_metered = ids(scale_metered)?;
        // An empty base is the legitimate "no committed base" case; a non-empty but malformed base is
        // a config error that must refuse the catalog, not degrade Scale into an uncommitted tier.
        let scale_base = {
            let b = scale_base.trim();
            if b.is_empty() {
                None
            } else if valid_stripe_id(b) {
                Some(b.to_string())
            } else {
                return None;
            }
        };
        if usage_metered.is_empty() || scale_metered.is_empty() {
            return None;
        }
        Some(PlanCatalog {
            usage_metered,
            scale_metered,
            scale_base,
        })
    }

    /// Derive the plan a set of subscribed price ids corresponds to: the committed base price present
    /// means Scale; any metered price present (but no base) means Usage; neither means Developer.
    pub fn plan_of(&self, price_ids: &[String]) -> Plan {
        if let Some(base) = &self.scale_base {
            if price_ids.iter().any(|p| p == base) {
                return Plan::Scale;
            }
        }
        let metered = |p: &String| self.usage_metered.contains(p) || self.scale_metered.contains(p);
        if price_ids.iter().any(metered) {
            return Plan::Usage;
        }
        Plan::Developer
    }

    /// The Checkout line items for `plan`. Empty for Developer (no Checkout).
    pub fn line_items(&self, plan: Plan) -> Vec<LineItem> {
        let metered = |prices: &[String]| {
            prices
                .iter()
                .map(|p| LineItem {
                    price: p.clone(),
                    quantity: None,
                })
                .collect::<Vec<_>>()
        };
        match plan {
            Plan::Developer => Vec::new(),
            Plan::Usage => metered(&self.usage_metered),
            Plan::Scale => {
                let mut items = Vec::new();
                if let Some(base) = &self.scale_base {
                    items.push(LineItem {
                        price: base.clone(),
                        quantity: Some(1),
                    });
                }
                items.extend(metered(&self.scale_metered));
                items
            }
        }
    }
}

// ---- form encoding ----

/// Percent-encode one x-www-form-urlencoded component (unreserved chars pass through).
fn enc(s: &str) -> String {
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

/// `key=value&...`, each side percent-encoded. Stripe expects nested keys like
/// `line_items[0][price]`; the caller builds those keys and this only escapes them.
fn form(pairs: &[(String, String)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", enc(k), enc(v)))
        .collect::<Vec<_>>()
        .join("&")
}

// ---- URLs ----

pub fn customers_url() -> String {
    "https://api.stripe.com/v1/customers".to_string()
}
pub fn checkout_sessions_url() -> String {
    "https://api.stripe.com/v1/checkout/sessions".to_string()
}
pub fn portal_sessions_url() -> String {
    "https://api.stripe.com/v1/billing_portal/sessions".to_string()
}
/// Active subscriptions for a customer (limit 1: presence is all we need). The caller has already
/// validated `customer` as a Stripe id, so it cannot smuggle extra query parameters.
pub fn subscriptions_active_url(customer: &str) -> String {
    format!("https://api.stripe.com/v1/subscriptions?customer={customer}&status=active&limit=1")
}
/// A customer's most recent subscription across ALL statuses (for the billing view: shows a past_due
/// or canceled sub too, not only active). The caller validated `customer`.
pub fn subscriptions_all_url(customer: &str) -> String {
    format!("https://api.stripe.com/v1/subscriptions?customer={customer}&status=all&limit=1")
}

/// The console billing view's snapshot of a tenant's subscription.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubscriptionState {
    /// Stripe status (`active`, `trialing`, `past_due`, `canceled`, ...).
    pub status: String,
    /// Unix seconds when the current period ends (0 if absent).
    pub current_period_end: i64,
    /// The plan the subscribed prices map to.
    pub plan: Plan,
}

// ---- bodies ----

/// Create-customer body. `metadata[tenant]` stamps the tenant so the reconciler + webhooks map a
/// Stripe customer straight back to its Hop tenant.
pub fn customer_create_body(email: &str, tenant_hex: &str) -> String {
    form(&[
        ("email".into(), email.into()),
        ("metadata[tenant]".into(), tenant_hex.into()),
    ])
}

/// Checkout-session body for a subscription of `items`, tied to `customer`. `client_reference_id` and
/// `subscription_data[metadata][tenant]` both carry the tenant so the resulting subscription is
/// attributable no matter which webhook fires.
pub fn checkout_session_body(
    customer: &str,
    tenant_hex: &str,
    items: &[LineItem],
    success_url: &str,
    cancel_url: &str,
) -> String {
    let mut pairs = vec![
        ("mode".into(), "subscription".into()),
        ("customer".into(), customer.into()),
        ("client_reference_id".into(), tenant_hex.into()),
        (
            "subscription_data[metadata][tenant]".into(),
            tenant_hex.into(),
        ),
        ("success_url".into(), success_url.into()),
        ("cancel_url".into(), cancel_url.into()),
    ];
    for (i, item) in items.iter().enumerate() {
        pairs.push((format!("line_items[{i}][price]"), item.price.clone()));
        if let Some(q) = item.quantity {
            pairs.push((format!("line_items[{i}][quantity]"), q.to_string()));
        }
    }
    form(&pairs)
}

/// Billing-portal-session body: opens the hosted portal for `customer`, returning to `return_url`.
pub fn portal_session_body(customer: &str, return_url: &str) -> String {
    form(&[
        ("customer".into(), customer.into()),
        ("return_url".into(), return_url.into()),
    ])
}

// ---- parsers ----

fn json_str(body: &str, field: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    v.get(field)?.as_str().map(str::to_string)
}

/// The `cus_...` id from a created customer.
pub fn parse_customer_id(body: &str) -> Result<String, String> {
    json_str(body, "id")
        .filter(|id| valid_stripe_id(id))
        .ok_or_else(|| "customer create: no id".to_string())
}

/// The hosted `url` a Checkout or Portal session redirects the browser to.
pub fn parse_session_url(body: &str) -> Result<String, String> {
    json_str(body, "url")
        .filter(|u| u.starts_with("https://"))
        .ok_or_else(|| "session: no url".to_string())
}

// ---- high-level writes ----

/// Stripe writes over any [`Transport`]. Validates ids before building URLs.
pub struct StripeBilling<'a> {
    pub transport: &'a dyn Transport,
}

impl StripeBilling<'_> {
    /// Create a Stripe customer for a tenant, returning its `cus_...` id. The Stripe
    /// `Idempotency-Key` is deterministic in the tenant, so two concurrent first checkouts (or a
    /// retry after a timed-out-but-succeeded create) collapse to ONE customer instead of minting a
    /// duplicate that the registry would then disagree with.
    pub fn create_customer(&self, email: &str, tenant_hex: &str) -> Result<String, String> {
        let key = format!("hop-customer:{tenant_hex}");
        let (s, b) = self.transport.post_form(
            &customers_url(),
            &customer_create_body(email, tenant_hex),
            Some(&key),
        )?;
        parse_customer_id(&ok_or_err("customers.create", s, &b)?)
    }

    /// Whether `customer` already has an active subscription. Used to refuse a second Checkout that
    /// would stack a duplicate subscription and double-bill; plan changes go through the Billing
    /// Portal instead. A read error propagates so the caller can fail closed. (The plans carry no
    /// Stripe trial: the free tier is the separate Developer plan, so `active` is the whole story.)
    pub fn has_active_subscription(&self, customer: &str) -> Result<bool, String> {
        if !valid_stripe_id(customer) {
            return Err("invalid customer id".into());
        }
        let (s, b) = self.transport.get(&subscriptions_active_url(customer))?;
        let body = ok_or_err("subscriptions.list", s, &b)?;
        let v: serde_json::Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
        Ok(v["data"].as_array().is_some_and(|d| !d.is_empty()))
    }

    /// The tenant's current subscription: status, period end, and the plan derived from the subscribed
    /// price ids via `catalog`. `None` if the customer has no subscription (a fresh/free tenant). Used
    /// by the console billing view; the live counterpart to a stored plan (a webhook is a follow-up).
    pub fn current_subscription(
        &self,
        catalog: &PlanCatalog,
        customer: &str,
    ) -> Result<Option<SubscriptionState>, String> {
        if !valid_stripe_id(customer) {
            return Err("invalid customer id".into());
        }
        let (s, b) = self.transport.get(&subscriptions_all_url(customer))?;
        let body = ok_or_err("subscriptions.list", s, &b)?;
        let v: serde_json::Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
        let Some(sub) = v["data"].as_array().and_then(|d| d.first()) else {
            return Ok(None);
        };
        let price_ids: Vec<String> = sub["items"]["data"]
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(|i| i["price"]["id"].as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        Ok(Some(SubscriptionState {
            status: sub["status"].as_str().unwrap_or("unknown").to_string(),
            current_period_end: sub["current_period_end"].as_i64().unwrap_or(0),
            plan: catalog.plan_of(&price_ids),
        }))
    }

    /// Create a Checkout session for `plan` and return the hosted URL to redirect the browser to.
    /// Errors on the free plan (Developer needs no Checkout) or a missing customer.
    pub fn create_checkout(
        &self,
        catalog: &PlanCatalog,
        customer: &str,
        tenant_hex: &str,
        plan: Plan,
        success_url: &str,
        cancel_url: &str,
    ) -> Result<String, String> {
        if !valid_stripe_id(customer) {
            return Err("invalid customer id".into());
        }
        let items = catalog.line_items(plan);
        if items.is_empty() {
            return Err("plan has no checkout (free tier)".into());
        }
        let body = checkout_session_body(customer, tenant_hex, &items, success_url, cancel_url);
        // No idempotency key: each checkout attempt is its own intent, and the caller has already
        // refused a second checkout when a subscription is active (has_active_subscription).
        let (s, b) = self
            .transport
            .post_form(&checkout_sessions_url(), &body, None)?;
        parse_session_url(&ok_or_err("checkout.create", s, &b)?)
    }

    /// Open the hosted Billing Portal for a customer, returning the URL to redirect to.
    pub fn create_portal(&self, customer: &str, return_url: &str) -> Result<String, String> {
        if !valid_stripe_id(customer) {
            return Err("invalid customer id".into());
        }
        let (s, b) = self.transport.post_form(
            &portal_sessions_url(),
            &portal_session_body(customer, return_url),
            None,
        )?;
        parse_session_url(&ok_or_err("portal.create", s, &b)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn catalog() -> PlanCatalog {
        PlanCatalog::parse(
            "price_reach, price_tel",
            "price_reach2,price_tel2",
            "price_commit",
        )
        .unwrap()
    }

    #[test]
    fn plan_of_derives_from_subscribed_prices() {
        let c = catalog();
        // the committed base present -> Scale
        assert_eq!(
            c.plan_of(&["price_commit".into(), "price_reach2".into()]),
            Plan::Scale
        );
        // a metered price, no base -> Usage
        assert_eq!(c.plan_of(&["price_reach".into()]), Plan::Usage);
        // nothing recognizable / empty -> Developer
        assert_eq!(c.plan_of(&["price_unknown".into()]), Plan::Developer);
        assert_eq!(c.plan_of(&[]), Plan::Developer);
    }

    #[test]
    fn plan_parse_and_paid() {
        assert_eq!(Plan::parse("Usage"), Some(Plan::Usage));
        assert_eq!(Plan::parse("SCALE"), Some(Plan::Scale));
        assert_eq!(Plan::parse("nope"), None);
        assert!(!Plan::Developer.is_paid());
        assert!(Plan::Usage.is_paid() && Plan::Scale.is_paid());
    }

    #[test]
    fn catalog_rejects_a_half_configured_paid_surface() {
        assert!(PlanCatalog::parse("", "price_x", "price_b").is_none()); // no usage prices
        assert!(PlanCatalog::parse("price_x", "not-an-id", "").is_none()); // no scale metered
                                                                           // valid: scale_base optional
        let c = PlanCatalog::parse("price_u", "price_s", "").unwrap();
        assert!(c.scale_base.is_none());
    }

    #[test]
    fn catalog_refuses_a_partially_malformed_list_instead_of_dropping_a_meter() {
        // One good id + one typo'd id (hyphen is not a valid Stripe id char) must refuse the WHOLE
        // catalog, not silently keep the good one and under-bill by the dropped meter.
        assert!(PlanCatalog::parse("price_reach,price-tel", "price_s", "").is_none());
        assert!(PlanCatalog::parse("price_u", "price_reach,price tel", "").is_none());
        // A non-empty but malformed committed base must refuse too (not degrade Scale to uncommitted).
        assert!(PlanCatalog::parse("price_u", "price_s", "price-base").is_none());
        // But formatting noise (trailing/stray commas, surrounding spaces) is tolerated.
        let c = PlanCatalog::parse(" price_u , ", "price_s,", "").unwrap();
        assert_eq!(c.usage_metered, vec!["price_u".to_string()]);
        assert_eq!(c.scale_metered, vec!["price_s".to_string()]);
    }

    #[test]
    fn line_items_per_plan() {
        let c = catalog();
        assert!(c.line_items(Plan::Developer).is_empty());
        let u = c.line_items(Plan::Usage);
        assert_eq!(u.len(), 2);
        assert!(
            u.iter().all(|i| i.quantity.is_none()),
            "metered prices carry no quantity"
        );
        let s = c.line_items(Plan::Scale);
        assert_eq!(s.len(), 3, "committed base + 2 metered");
        assert_eq!(s[0].quantity, Some(1), "committed base has quantity 1");
        assert!(s[1..].iter().all(|i| i.quantity.is_none()));
    }

    #[test]
    fn bodies_encode_and_stamp_the_tenant() {
        let cust = customer_create_body("dev@hopme.sh", "a3f1c0");
        assert!(cust.contains("email=dev%40hopme.sh"));
        assert!(cust.contains("metadata%5Btenant%5D=a3f1c0")); // metadata[tenant]

        let items = catalog().line_items(Plan::Scale);
        let co = checkout_session_body("cus_1", "a3f1c0", &items, "https://d/ok", "https://d/no");
        assert!(co.contains("mode=subscription") && co.contains("customer=cus_1"));
        assert!(co.contains("client_reference_id=a3f1c0"));
        assert!(co.contains("subscription_data%5Bmetadata%5D%5Btenant%5D=a3f1c0"));
        assert!(co.contains("line_items%5B0%5D%5Bprice%5D=price_commit"));
        assert!(co.contains("line_items%5B0%5D%5Bquantity%5D=1"));
        assert!(co.contains("success_url=https%3A%2F%2Fd%2Fok"));

        let portal = portal_session_body("cus_1", "https://d/home");
        assert!(
            portal.contains("customer=cus_1")
                && portal.contains("return_url=https%3A%2F%2Fd%2Fhome")
        );
    }

    #[test]
    fn parsers_validate() {
        assert_eq!(parse_customer_id(r#"{"id":"cus_ABC"}"#).unwrap(), "cus_ABC");
        assert!(parse_customer_id(r#"{"id":"http://evil"}"#).is_err()); // not a stripe id shape
        assert!(parse_customer_id("{}").is_err());
        assert_eq!(
            parse_session_url(r#"{"url":"https://checkout.stripe.com/x"}"#).unwrap(),
            "https://checkout.stripe.com/x"
        );
        assert!(parse_session_url(r#"{"url":"javascript:alert(1)"}"#).is_err());
    }

    /// Records the last posted (url, body) + idempotency key, and replays a canned response.
    struct FakeTransport {
        last: RefCell<(String, String)>,
        last_key: RefCell<Option<String>>,
        resp: (u16, String),
    }
    impl Transport for FakeTransport {
        fn get(&self, _url: &str) -> Result<(u16, String), String> {
            Ok((200, "{}".into()))
        }
        fn post_form(
            &self,
            url: &str,
            body: &str,
            idempotency_key: Option<&str>,
        ) -> Result<(u16, String), String> {
            *self.last.borrow_mut() = (url.to_string(), body.to_string());
            *self.last_key.borrow_mut() = idempotency_key.map(str::to_string);
            Ok(self.resp.clone())
        }
    }

    #[test]
    fn create_flows_hit_the_right_endpoints() {
        let t = FakeTransport {
            last: RefCell::new((String::new(), String::new())),
            last_key: RefCell::new(None),
            resp: (
                200,
                r#"{"id":"cus_9","url":"https://checkout.stripe.com/s"}"#.into(),
            ),
        };
        let b = StripeBilling { transport: &t };
        assert_eq!(b.create_customer("a@x.co", "t1").unwrap(), "cus_9");
        assert!(t.last.borrow().0.ends_with("/v1/customers"));
        // customer creation is idempotent per tenant, so a retry cannot mint a duplicate
        assert_eq!(t.last_key.borrow().as_deref(), Some("hop-customer:t1"));

        let url = b
            .create_checkout(
                &catalog(),
                "cus_9",
                "t1",
                Plan::Usage,
                "https://d/ok",
                "https://d/no",
            )
            .unwrap();
        assert_eq!(url, "https://checkout.stripe.com/s");
        assert!(t.last.borrow().0.ends_with("/v1/checkout/sessions"));

        // Developer has no checkout
        assert!(b
            .create_checkout(&catalog(), "cus_9", "t1", Plan::Developer, "a", "b")
            .is_err());

        let purl = b.create_portal("cus_9", "https://d/home").unwrap();
        assert_eq!(purl, "https://checkout.stripe.com/s");
        assert!(t.last.borrow().0.ends_with("/v1/billing_portal/sessions"));
    }

    #[test]
    fn non_2xx_surfaces_a_truncated_error() {
        let t = FakeTransport {
            last: RefCell::new((String::new(), String::new())),
            last_key: RefCell::new(None),
            resp: (400, "{\"error\":{\"message\":\"no such price\"}}".into()),
        };
        let b = StripeBilling { transport: &t };
        let e = b.create_customer("a@x.co", "t1").unwrap_err();
        assert!(e.contains("400") && e.contains("customers.create"));
    }
}
