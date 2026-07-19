//! The Stripe READ layer for the console's native billing surfaces: invoice list + line items,
//! previous payments, the card on file, and server-driven `invoice.pay`.
//!
//! Same discipline as hop-billingd's emitter: everything except the socket is pure and unit-tested
//! (URL construction, response parsing, the ownership check), and only [`Transport`] touches the
//! network, with a `reqwest` impl under `--features live` using the RESTRICTED `stripe-account-key`
//! (Invoices/Customers/Subscriptions/SetupIntents write; PaymentIntents/Charges/Payment
//! methods/Credit notes/Meters read; see `infra/billing_runtime.tf`).
//!
//! Parsers skip malformed entries rather than failing a whole page: one odd object from Stripe must
//! not blank the console's billing page.

use serde::Serialize;

/// The Stripe API network seam: authenticated GET, or a form POST with an optional Stripe
/// `Idempotency-Key` header (a deterministic key makes a retried or concurrent write collapse to a
/// single Stripe object instead of duplicating it). Returns `(status, body)`.
pub trait Transport {
    fn get(&self, url: &str) -> Result<(u16, String), String>;
    fn post_form(
        &self,
        url: &str,
        body: &str,
        idempotency_key: Option<&str>,
    ) -> Result<(u16, String), String>;
}

const BASE: &str = "https://api.stripe.com/v1";

/// A Stripe object id as used in a URL path/query. Stripe ids are `[A-Za-z0-9_]` (`in_...`,
/// `ch_...`, `cus_...`); anything else is rejected BEFORE it can reach a URL, so a crafted id can
/// never smuggle a path segment or query parameter into a Stripe call.
pub fn valid_stripe_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

pub fn invoices_list_url(customer: &str) -> String {
    format!("{BASE}/invoices?customer={customer}&limit=24")
}
pub fn invoice_url(invoice: &str) -> String {
    format!("{BASE}/invoices/{invoice}")
}
pub fn invoice_pay_url(invoice: &str) -> String {
    format!("{BASE}/invoices/{invoice}/pay")
}
pub fn charges_list_url(customer: &str) -> String {
    format!("{BASE}/charges?customer={customer}&limit=24")
}
pub fn payment_methods_url(customer: &str) -> String {
    format!("{BASE}/payment_methods?customer={customer}&type=card&limit=1")
}

/// One invoice in the console's history list.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct InvoiceSummary {
    pub id: String,
    /// Stripe's human number (`ABC123-0007`), if assigned.
    pub number: Option<String>,
    pub status: String,
    pub amount_due: i64,
    pub currency: String,
    pub created: i64,
    pub hosted_invoice_url: Option<String>,
    pub invoice_pdf: Option<String>,
}

/// A native-render line item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct LineItem {
    pub description: Option<String>,
    pub amount: i64,
    pub quantity: Option<i64>,
}

/// One invoice with its line items, plus the owning customer for the ownership check.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct InvoiceDetail {
    #[serde(flatten)]
    pub summary: InvoiceSummary,
    pub lines: Vec<LineItem>,
    /// The Stripe customer this invoice belongs to. NOT serialized to console clients; used by the
    /// API layer to refuse cross-tenant reads (an invoice id is not a capability).
    #[serde(skip)]
    pub customer: Option<String>,
}

/// One past payment (a charge) for the history view.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Payment {
    pub id: String,
    pub amount: i64,
    pub currency: String,
    pub status: String,
    pub created: i64,
    pub card_brand: Option<String>,
    pub card_last4: Option<String>,
}

/// The default card, for the "Visa ending 4242" display.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct CardOnFile {
    pub brand: String,
    pub last4: String,
    pub exp_month: i64,
    pub exp_year: i64,
}

fn parse_invoice_summary(v: &serde_json::Value) -> Option<InvoiceSummary> {
    Some(InvoiceSummary {
        id: v["id"].as_str()?.to_string(),
        number: v["number"].as_str().map(str::to_string),
        status: v["status"].as_str().unwrap_or("unknown").to_string(),
        amount_due: v["amount_due"].as_i64().unwrap_or(0),
        currency: v["currency"].as_str().unwrap_or("usd").to_string(),
        created: v["created"].as_i64().unwrap_or(0),
        hosted_invoice_url: v["hosted_invoice_url"].as_str().map(str::to_string),
        invoice_pdf: v["invoice_pdf"].as_str().map(str::to_string),
    })
}

/// Parse an invoice LIST response (`{"data": [...]}`); malformed entries are skipped.
pub fn parse_invoice_list(body: &str) -> Result<Vec<InvoiceSummary>, String> {
    let v: serde_json::Value = serde_json::from_str(body).map_err(|e| e.to_string())?;
    let items = v["data"].as_array().ok_or("no data array")?;
    Ok(items.iter().filter_map(parse_invoice_summary).collect())
}

/// Parse a single-invoice response, including its line items and owning customer.
pub fn parse_invoice_detail(body: &str) -> Result<InvoiceDetail, String> {
    let v: serde_json::Value = serde_json::from_str(body).map_err(|e| e.to_string())?;
    let summary = parse_invoice_summary(&v).ok_or("not an invoice object")?;
    let lines = v["lines"]["data"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|l| {
                    Some(LineItem {
                        description: l["description"].as_str().map(str::to_string),
                        amount: l["amount"].as_i64()?,
                        quantity: l["quantity"].as_i64(),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(InvoiceDetail {
        summary,
        lines,
        customer: v["customer"].as_str().map(str::to_string),
    })
}

/// Parse a charge LIST response into payments; malformed entries are skipped.
pub fn parse_payments(body: &str) -> Result<Vec<Payment>, String> {
    let v: serde_json::Value = serde_json::from_str(body).map_err(|e| e.to_string())?;
    let items = v["data"].as_array().ok_or("no data array")?;
    Ok(items
        .iter()
        .filter_map(|c| {
            let card = &c["payment_method_details"]["card"];
            Some(Payment {
                id: c["id"].as_str()?.to_string(),
                amount: c["amount"].as_i64().unwrap_or(0),
                currency: c["currency"].as_str().unwrap_or("usd").to_string(),
                status: c["status"].as_str().unwrap_or("unknown").to_string(),
                created: c["created"].as_i64().unwrap_or(0),
                card_brand: card["brand"].as_str().map(str::to_string),
                card_last4: card["last4"].as_str().map(str::to_string),
            })
        })
        .collect())
}

/// Parse the payment-methods list into the (first) card on file, `None` if there is none.
pub fn parse_card(body: &str) -> Result<Option<CardOnFile>, String> {
    let v: serde_json::Value = serde_json::from_str(body).map_err(|e| e.to_string())?;
    let Some(first) = v["data"].as_array().and_then(|d| d.first()) else {
        return Ok(None);
    };
    let card = &first["card"];
    Ok(Some(CardOnFile {
        brand: card["brand"].as_str().unwrap_or("card").to_string(),
        last4: card["last4"].as_str().unwrap_or("????").to_string(),
        exp_month: card["exp_month"].as_i64().unwrap_or(0),
        exp_year: card["exp_year"].as_i64().unwrap_or(0),
    }))
}

/// Map a Stripe response to a uniform error, keeping bodies out of errors past a short prefix (the
/// body can echo request details; console errors should not).
pub fn ok_or_err(what: &str, status: u16, body: &str) -> Result<String, String> {
    if (200..300).contains(&status) {
        Ok(body.to_string())
    } else {
        Err(format!(
            "{what} {status}: {}",
            body.chars().take(120).collect::<String>()
        ))
    }
}

/// High-level reads over any [`Transport`], used by the API layer. Every method validates ids
/// before URL construction.
pub struct StripeReader<T: Transport> {
    pub transport: T,
}

impl<T: Transport> StripeReader<T> {
    pub fn invoices(&self, customer: &str) -> Result<Vec<InvoiceSummary>, String> {
        if !valid_stripe_id(customer) {
            return Err("invalid customer id".into());
        }
        let (s, b) = self.transport.get(&invoices_list_url(customer))?;
        parse_invoice_list(&ok_or_err("invoices.list", s, &b)?)
    }

    pub fn invoice(&self, invoice: &str) -> Result<InvoiceDetail, String> {
        if !valid_stripe_id(invoice) {
            return Err("invalid invoice id".into());
        }
        let (s, b) = self.transport.get(&invoice_url(invoice))?;
        parse_invoice_detail(&ok_or_err("invoices.get", s, &b)?)
    }

    pub fn pay_invoice(&self, invoice: &str) -> Result<InvoiceDetail, String> {
        if !valid_stripe_id(invoice) {
            return Err("invalid invoice id".into());
        }
        let (s, b) = self
            .transport
            .post_form(&invoice_pay_url(invoice), "", None)?;
        parse_invoice_detail(&ok_or_err("invoices.pay", s, &b)?)
    }

    pub fn payments(&self, customer: &str) -> Result<Vec<Payment>, String> {
        if !valid_stripe_id(customer) {
            return Err("invalid customer id".into());
        }
        let (s, b) = self.transport.get(&charges_list_url(customer))?;
        parse_payments(&ok_or_err("charges.list", s, &b)?)
    }

    pub fn card(&self, customer: &str) -> Result<Option<CardOnFile>, String> {
        if !valid_stripe_id(customer) {
            return Err("invalid customer id".into());
        }
        let (s, b) = self.transport.get(&payment_methods_url(customer))?;
        parse_card(&ok_or_err("payment_methods.list", s, &b)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stripe_id_validation_blocks_url_smuggling() {
        assert!(valid_stripe_id("in_1PbA7dJ4kQ"));
        assert!(valid_stripe_id("cus_ABC123"));
        for bad in [
            "",
            "in_1/../secrets",
            "in 1",
            "in_1?limit=100",
            "in_1&x=y",
            "in#1",
        ] {
            assert!(!valid_stripe_id(bad), "must reject {bad:?}");
        }
        assert!(!valid_stripe_id(&"x".repeat(129)));
    }

    #[test]
    fn parses_an_invoice_list_and_skips_malformed_entries() {
        let body = serde_json::json!({
            "data": [
                { "id": "in_1", "number": "HOP-0007", "status": "paid", "amount_due": 42610,
                  "currency": "usd", "created": 1752000000,
                  "hosted_invoice_url": "https://inv.stripe.com/x", "invoice_pdf": "https://pdf" },
                { "not_an_invoice": true },
            ]
        })
        .to_string();
        let list = parse_invoice_list(&body).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, "in_1");
        assert_eq!(list[0].amount_due, 42610);
        assert_eq!(list[0].number.as_deref(), Some("HOP-0007"));
    }

    #[test]
    fn parses_invoice_detail_with_lines_and_owner() {
        let body = serde_json::json!({
            "id": "in_1", "status": "open", "amount_due": 337000, "currency": "usd",
            "created": 1752000000, "customer": "cus_A",
            "lines": { "data": [
                { "description": "Backbone reach", "amount": 240000, "quantity": 1200000 },
                { "description": null, "amount": 9000, "quantity": null },
                { "amount": "notanumber" },
            ]}
        })
        .to_string();
        let d = parse_invoice_detail(&body).unwrap();
        assert_eq!(d.customer.as_deref(), Some("cus_A"));
        assert_eq!(d.lines.len(), 2, "the malformed line is skipped");
        assert_eq!(d.lines[0].description.as_deref(), Some("Backbone reach"));
    }

    #[test]
    fn detail_serialization_never_leaks_the_customer_id() {
        let d = parse_invoice_detail(
            &serde_json::json!({
                "id": "in_1", "status": "open", "amount_due": 1, "currency": "usd",
                "created": 0, "customer": "cus_SECRET", "lines": {"data": []}
            })
            .to_string(),
        )
        .unwrap();
        let out = serde_json::to_string(&d).unwrap();
        assert!(
            !out.contains("cus_SECRET"),
            "customer is an internal field: {out}"
        );
    }

    #[test]
    fn parses_payments_with_card_summaries() {
        let body = serde_json::json!({
            "data": [{
                "id": "ch_1", "amount": 42610, "currency": "usd", "status": "succeeded",
                "created": 1752000000,
                "payment_method_details": { "card": { "brand": "visa", "last4": "4242" } }
            }]
        })
        .to_string();
        let p = parse_payments(&body).unwrap();
        assert_eq!(p[0].card_last4.as_deref(), Some("4242"));
        assert_eq!(p[0].status, "succeeded");
    }

    #[test]
    fn parses_the_card_on_file_and_its_absence() {
        let some = serde_json::json!({
            "data": [{ "card": { "brand": "visa", "last4": "4242", "exp_month": 12, "exp_year": 2028 } }]
        })
        .to_string();
        assert_eq!(
            parse_card(&some).unwrap(),
            Some(CardOnFile {
                brand: "visa".into(),
                last4: "4242".into(),
                exp_month: 12,
                exp_year: 2028
            })
        );
        assert_eq!(
            parse_card(&serde_json::json!({ "data": [] }).to_string()).unwrap(),
            None
        );
    }

    #[test]
    fn non_2xx_maps_to_a_truncated_error() {
        let long_body = "e".repeat(500);
        let err = ok_or_err("invoices.get", 402, &long_body).unwrap_err();
        assert!(err.starts_with("invoices.get 402:"));
        assert!(err.len() < 160, "body truncated: {}", err.len());
    }
}
