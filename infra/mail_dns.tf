# Google Workspace (Gmail) for hopme.sh — domain verification + mail authentication.
#
# These live in the same Cloud DNS zone as the site (pages_dns.tf) and relay (dns.tf).
# They are additive — they don't touch the existing site/relay records — so applying
# them through the normal Terraform/Spacelift flow is safe.
#
# Setup order for the Workspace tenant:
#   1. Apply the apex TXT below (SPF + Google's site-verification token), then verify
#      the domain in the Google Admin console.
#   2. The MX record routes inbound mail to Google.
#   3. Generate a DKIM key in Admin (Apps -> Google Workspace -> Gmail -> Authenticate
#      email -> Generate new record), set TF_VAR_google_dkim_txt, and apply.
#   4. DMARC starts in monitor mode (p=none); tighten to quarantine/reject once SPF and
#      DKIM are confirmed aligned in the aggregate reports.

# hopme.sh apex TXT — Cloud DNS groups TXT by name, so every apex TXT string lives in
# ONE record set: SPF authorizing Google to send as @hopme.sh, plus the Workspace
# site-verification token. (Add future apex TXT strings here too, not as a new resource.)
resource "google_dns_record_set" "apex_txt" {
  name         = var.dns_zone_dns_name # hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "TXT"
  ttl          = 3600
  rrdatas = [
    "\"v=spf1 include:_spf.google.com ~all\"",
    "\"google-site-verification=StO63FjYhPbbyT-7VmxkTEDPukGScfjBsXXYXCAwIUg\"",
  ]
}

# Inbound mail -> Google Workspace. Single-host MX is what Google provisions now; it
# replaces the legacy five ASPMX.L.GOOGLE.COM records.
resource "google_dns_record_set" "mx" {
  name         = var.dns_zone_dns_name # hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "MX"
  ttl          = 3600
  rrdatas      = ["1 smtp.google.com."]
}

# DMARC — monitor mode to start; aggregate reports to postmaster@hopme.sh.
resource "google_dns_record_set" "dmarc" {
  name         = "_dmarc.${var.dns_zone_dns_name}" # _dmarc.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = ["\"v=DMARC1; p=none; rua=mailto:postmaster@hopme.sh; fo=1\""]
}

# DKIM — created only once the Admin-console key is supplied. Google's 2048-bit key
# exceeds the 255-char TXT limit, so provide it split into quoted chunks, e.g.
#   TF_VAR_google_dkim_txt='"v=DKIM1; k=rsa; p=MIIBIjANBg...first255chars" "...remainder"'
resource "google_dns_record_set" "dkim" {
  count        = var.google_dkim_txt == "" ? 0 : 1
  name         = "google._domainkey.${var.dns_zone_dns_name}" # google._domainkey.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = [var.google_dkim_txt]
}
