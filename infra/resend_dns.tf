# Resend sending authentication for the account subdomain (account.hopme.sh).
#
# hop-accountd sends transactional mail (magic-link sign-in, team invites, billing notices) as
# noreply@account.hopme.sh through Resend. Resend verifies control of the SENDING SUBDOMAIN, so every
# record below sits under account.hopme.sh and is additive: the Google Workspace records in mail_dns.tf
# live at the hopme.sh APEX (apex TXT, apex MX, _dmarc) and are untouched by these. Delegating sending
# to a subdomain is deliberate; it keeps Resend's SPF and DKIM reputation separate from the apex mail
# that Workspace handles.
#
# Applied by the normal runtime flow (push to main), so verification is: merge, let the apply run, then
# click verify in the Resend dashboard. Nothing here is a secret; a DKIM public key is published in DNS
# by design, and the SPF and MX values are Resend's documented AWS SES endpoints.

# DKIM public key for the Resend selector. 218 characters, so it fits in a single quoted TXT string
# (Cloud DNS requires strings over 255 characters to be split into multiple quoted chunks).
resource "google_dns_record_set" "resend_dkim" {
  name         = "resend._domainkey.account.${var.dns_zone_dns_name}" # resend._domainkey.account.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = ["\"p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCugB5Z6hW034HvwYb5HCBqU4ebdB2WFdCppjaxvp3uEjj19oKBxOODzJm1cNDyElB4YfunsZeHCgZhp1vP9hfd45+A2aeGsc1GyPEOZ+X6ZYO5ykSzRgzFnONRpG2RrmM+qqCeive84KhwlKIlQV8YQqFwhmAWF7UIR2VOnwLcGwIDAQAB\""]
}

# Return path (bounce and complaint feedback) for Resend's SES sending, on the send. subdomain.
resource "google_dns_record_set" "resend_spf_mx" {
  name         = "send.account.${var.dns_zone_dns_name}" # send.account.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "MX"
  ttl          = 3600
  rrdatas      = ["10 feedback-smtp.us-east-1.amazonses.com."]
}

# SPF authorizing SES (Resend's sender) for the send. subdomain. Cloud DNS groups TXT by name, so if
# another TXT string is ever needed at send.account.hopme.sh it belongs in this same record set.
resource "google_dns_record_set" "resend_spf_txt" {
  name         = "send.account.${var.dns_zone_dns_name}" # send.account.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = ["\"v=spf1 include:amazonses.com ~all\""]
}
