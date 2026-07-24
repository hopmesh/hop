# Resend sending authentication for the account subdomain (account.hopme.sh), published into the
# hopme.sh apex zone. The Google Workspace records in mail_dns.tf live at the apex and are untouched
# by these; delegating sending to a subdomain keeps Resend's SPF/DKIM reputation separate from the
# apex mail Workspace handles.
#
# The VALUES come from the resend_domain resource in the billing/SaaS root (infra/billing/resend.tf),
# read through the billing remote state this root already consumes (console.tf) for the Stripe price
# ids, so nothing here is hardcoded once that root has registered the domain. Until it has, the
# fallbacks below keep the last published values so a merge never drops the records; the fallback
# DKIM points at a not-yet-registered domain (harmless), and the billing apply plus the next runtime
# apply switch every value to the freshly issued one. The record NAMES are built from the known Resend
# layout (DKIM at resend._domainkey.<domain>, return-path + SPF at send.<domain>), not the provider's
# name field.

locals {
  resend_records = try(data.terraform_remote_state.billing.outputs.resend_records, [])
  resend_have    = length(local.resend_records) > 0

  resend_dkim_fallback = "p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCugB5Z6hW034HvwYb5HCBqU4ebdB2WFdCppjaxvp3uEjj19oKBxOODzJm1cNDyElB4YfunsZeHCgZhp1vP9hfd45+A2aeGsc1GyPEOZ+X6ZYO5ykSzRgzFnONRpG2RrmM+qqCeive84KhwlKIlQV8YQqFwhmAWF7UIR2VOnwLcGwIDAQAB"

  resend_dkim_value = local.resend_have ? try(one([for r in local.resend_records : r.value if r.type == "TXT" && startswith(r.value, "p=")]), local.resend_dkim_fallback) : local.resend_dkim_fallback
  resend_spf_value  = local.resend_have ? try(one([for r in local.resend_records : r.value if r.type == "TXT" && startswith(r.value, "v=spf1")]), "v=spf1 include:amazonses.com ~all") : "v=spf1 include:amazonses.com ~all"
  resend_mx         = local.resend_have ? try(one([for r in local.resend_records : r if r.type == "MX"]), null) : null
  resend_mx_rrdata  = local.resend_mx != null ? format("%s %s.", local.resend_mx.priority, trimsuffix(local.resend_mx.value, ".")) : "10 feedback-smtp.us-east-1.amazonses.com."

  # Cloud DNS requires a TXT string over 255 chars split into multiple quoted chunks; a fresh DKIM key
  # can exceed 255, so chunk defensively (a short key yields a single chunk).
  resend_dkim_rrdata = join(" ", [for c in regexall(".{1,255}", local.resend_dkim_value) : "\"${c}\""])
}

# DKIM public key for the Resend selector. Published by design (a DKIM public key lives in DNS).
resource "google_dns_record_set" "resend_dkim" {
  name         = "resend._domainkey.account.${var.dns_zone_dns_name}" # resend._domainkey.account.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = [local.resend_dkim_rrdata]
}

# Return path (bounce and complaint feedback) for Resend's SES sending, on the send. subdomain.
resource "google_dns_record_set" "resend_spf_mx" {
  name         = "send.account.${var.dns_zone_dns_name}" # send.account.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "MX"
  ttl          = 3600
  rrdatas      = [local.resend_mx_rrdata]
}

# SPF authorizing SES (Resend's sender) for the send. subdomain.
resource "google_dns_record_set" "resend_spf_txt" {
  name         = "send.account.${var.dns_zone_dns_name}" # send.account.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = ["\"${local.resend_spf_value}\""]
}
