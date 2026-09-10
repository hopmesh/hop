# Resend sending authentication for account.hopme.sh, published into the public hopme.sh DNS zone.
# These values were read from live Cloud DNS during the authority cutover on 2026-09-09. They are
# public DNS data by construction. Keeping them here removes runtime deploy's need to read the private
# billing OpenTofu state, and prevents a later billing apply from silently changing production DNS.
locals {
  resend_dkim_value = "p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCugB5Z6hW034HvwYb5HCBqU4ebdB2WFdCppjaxvp3uEjj19oKBxOODzJm1cNDyElB4YfunsZeHCgZhp1vP9hfd45+A2aeGsc1GyPEOZ+X6ZYO5ykSzRgzFnONRpG2RrmM+qqCeive84KhwlKIlQV8YQqFwhmAWF7UIR2VOnwLcGwIDAQAB"
  resend_spf_value  = "v=spf1 include:amazonses.com ~all"
  resend_mx_rrdata  = "10 feedback-smtp.us-east-1.amazonses.com."

  # Cloud DNS quoted TXT segments must stay at or below 255 bytes.
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
