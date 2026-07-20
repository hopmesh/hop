//! Outbound email behind a transport seam, the same discipline as the Stripe layer: the message
//! building and addressing logic is pure and unit-tested, and the real Resend call only compiles
//! under `--features live`. The only email the console sends today is the magic sign-in link.
//!
//! The emailed URL points at the console PAGE (`{base}/auth/verify#token=...`), never directly at the
//! redeem API: mail scanners prefetch GETs, and the link is single-use, so the page must be a safe
//! GET that then POSTs the token to `/auth/redeem` on a human click. The token rides the URL
//! FRAGMENT, not a query string: fragments never leave the browser, so the raw bearer credential
//! stays out of the console's access logs, any CDN/LB logs in front of it, and the Referer header;
//! the page JS reads `location.hash`. Keep both halves of that contract when wiring the frontend.

use serde::Serialize;

/// One outbound message. `text` is the plain-text alternative for clients that skip HTML.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct OutboundEmail {
    pub to: String,
    pub subject: String,
    pub html: String,
    pub text: String,
}

/// The send seam. The live impl is Resend; tests use a recording fake.
pub trait EmailSender: Send + Sync {
    fn send(&self, msg: &OutboundEmail) -> Result<(), String>;
}

/// Build the sign-in link URL carried by the email. `base` is the console origin
/// (e.g. `https://dashboard.hopme.sh`), with or without a trailing slash. The token is in the
/// fragment (see the module doc): servers, proxies, and logs never see it.
///
/// The path MUST match the console page that redeems it (`apps/web/console/app/auth/verify/page.tsx`,
/// the contract locked in that package's CLAUDE.md). These drifted once (this built `/auth/link` while
/// the console served `/auth/verify`), which 404'd every emailed sign-in link; keep them in step.
pub fn login_link_url(base: &str, raw_token: &str) -> String {
    format!(
        "{}/auth/verify#token={raw_token}",
        base.trim_end_matches('/')
    )
}

/// The team-invite accept URL. Like the login link, the token rides the FRAGMENT (`#token=`), so it is
/// never sent to a server or logged; the console page reads it and POSTs it to `/console/team/accept`.
pub fn invite_link_url(base: &str, raw_token: &str) -> String {
    format!("{}/invite#token={raw_token}", base.trim_end_matches('/'))
}

/// Compose a team-invite email: who invited them, to which workspace, and the accept link. The copy
/// works whether or not the recipient already has a Hop account (accepting signs them in / creates the
/// account first, then joins).
pub fn invite_email(to: &str, workspace: &str, inviter: &str, accept_url: &str) -> OutboundEmail {
    let ws = html_escape(workspace);
    let inv = html_escape(inviter);
    let subject = format!("{inviter} invited you to {workspace} on Hop");
    let text = format!(
        "You're invited to Hop\n\n\
         {inviter} added you to the {workspace} workspace. Open this link to accept and sign in \
         (it creates your account if you don't have one yet):\n\n\
         {accept_url}\n\n\
         If you weren't expecting this, you can ignore this email.\n"
    );
    let html = format!(
        "<div style=\"font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;\
         max-width:420px;margin:0 auto;padding:32px 20px;color:#0c1613;\">\
         <h2 style=\"margin:0 0 12px;font-size:20px;\">You&rsquo;re invited to Hop</h2>\
         <p style=\"margin:0 0 20px;color:#4a5a52;font-size:14px;line-height:1.6;\">\
         <strong>{inv}</strong> added you to the <strong>{ws}</strong> workspace. Accept to join \
         (we&rsquo;ll sign you in, or create your account first).</p>\
         <p style=\"margin:0 0 24px;\"><a href=\"{accept_url}\" \
         style=\"display:inline-block;background:#0f9d72;color:#ffffff;text-decoration:none;\
         font-weight:600;font-size:14px;padding:12px 22px;border-radius:9px;\">Accept invite</a></p>\
         <p style=\"margin:0;color:#7e8c85;font-size:12px;\">\
         If you weren&rsquo;t expecting this, you can ignore this email.</p>\
         </div>"
    );
    OutboundEmail {
        to: to.to_string(),
        subject,
        html,
        text,
    }
}

/// Minimal HTML-escaping for the untrusted workspace name + inviter email interpolated into the invite
/// HTML (an org name is user-chosen; never inject it raw into markup).
fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// Compose the magic-link email. Deliberately spare: one purpose, one button, an expiry note, and a
/// "not you? ignore it" line. The copy never distinguishes new vs existing accounts (the flow does
/// not either), and never includes the recipient's name (we may not have one).
pub fn magic_link_email(to: &str, link_url: &str, ttl_minutes: u64) -> OutboundEmail {
    let subject = "Your Hop sign-in link".to_string();
    let text = format!(
        "Sign in to Hop\n\n\
         Open this link to continue. It works once and expires in {ttl_minutes} minutes.\n\n\
         {link_url}\n\n\
         If you did not request this, you can safely ignore this email.\n"
    );
    let html = format!(
        "<div style=\"font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;\
         max-width:420px;margin:0 auto;padding:32px 20px;color:#0c1613;\">\
         <h2 style=\"margin:0 0 12px;font-size:20px;\">Sign in to Hop</h2>\
         <p style=\"margin:0 0 20px;color:#4a5a52;font-size:14px;line-height:1.6;\">\
         Open this link to continue. It works once and expires in {ttl_minutes} minutes.</p>\
         <p style=\"margin:0 0 24px;\"><a href=\"{link_url}\" \
         style=\"display:inline-block;background:#0f9d72;color:#ffffff;text-decoration:none;\
         font-weight:600;font-size:14px;padding:12px 22px;border-radius:9px;\">Sign in</a></p>\
         <p style=\"margin:0 0 6px;color:#7e8c85;font-size:12px;line-height:1.6;\">\
         Or paste this into your browser:</p>\
         <p style=\"margin:0 0 24px;color:#4a5a52;font-size:12px;word-break:break-all;\">{link_url}</p>\
         <p style=\"margin:0;color:#7e8c85;font-size:12px;\">\
         If you did not request this, you can safely ignore this email.</p>\
         </div>"
    );
    OutboundEmail {
        to: to.to_string(),
        subject,
        html,
        text,
    }
}

/// The live Resend sender (`POST https://api.resend.com/emails`). Only compiled with `live`, so the
/// default build has no network surface.
#[cfg(feature = "live")]
pub struct ResendSender {
    pub http: reqwest::blocking::Client,
    pub api_key: String,
    /// The verified From address, e.g. `Hop <console@hopme.sh>`.
    pub from: String,
}

#[cfg(feature = "live")]
impl EmailSender for ResendSender {
    fn send(&self, msg: &OutboundEmail) -> Result<(), String> {
        #[derive(Serialize)]
        struct Payload<'a> {
            from: &'a str,
            to: [&'a str; 1],
            subject: &'a str,
            html: &'a str,
            text: &'a str,
        }
        let resp = self
            .http
            .post("https://api.resend.com/emails")
            .bearer_auth(&self.api_key)
            .json(&Payload {
                from: &self.from,
                to: [&msg.to],
                subject: &msg.subject,
                html: &msg.html,
                text: &msg.text,
            })
            .send()
            // Strip any URL from the error so an address never reaches logs (the OTLP lesson).
            .map_err(|e| format!("resend request failed: {}", e.without_url()))?;
        let status = resp.status().as_u16();
        if (200..300).contains(&status) {
            Ok(())
        } else {
            // Status only; the body may echo the recipient address.
            Err(format!("resend returned {status}"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn link_url_joins_cleanly_and_keeps_the_token_in_the_fragment() {
        assert_eq!(
            login_link_url("https://dashboard.hopme.sh", "abc123"),
            "https://dashboard.hopme.sh/auth/verify#token=abc123"
        );
        assert_eq!(
            login_link_url("https://dashboard.hopme.sh/", "abc123"),
            "https://dashboard.hopme.sh/auth/verify#token=abc123"
        );
        // The credential must ride the fragment (never sent to a server), not a query string.
        assert!(!login_link_url("https://d.hopme.sh", "t").contains("?token="));
    }

    #[test]
    fn magic_link_email_carries_the_link_in_both_bodies() {
        let m = magic_link_email("a@x.co", "https://d.hopme.sh/auth/verify#token=t1", 15);
        assert_eq!(m.to, "a@x.co");
        assert!(m.subject.contains("sign-in"));
        for body in [&m.html, &m.text] {
            assert!(body.contains("https://d.hopme.sh/auth/verify#token=t1"));
            assert!(body.contains("15 minutes"));
            assert!(body.contains("ignore this email"));
        }
        // The copy must not hint at account existence either way.
        for banned in ["welcome", "Welcome", "new account", "already have"] {
            assert!(
                !m.html.contains(banned) && !m.text.contains(banned),
                "{banned}"
            );
        }
    }
}
