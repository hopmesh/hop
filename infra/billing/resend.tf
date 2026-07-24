# The console sending domain, managed IN Resend. This is the piece that was missing: the domain was
# registered by hand in the dashboard and Terraform only published a COPIED snapshot of its DNS records,
# which nothing kept in sync. Managing it here returns the records Resend actually expects, which the
# runtime root publishes into the hopme.sh zone (infra/resend_dns.tf reads them from this root's state,
# the billing state it already consumes for the Stripe price ids).
#
# The domain predates Terraform, so billing-catalog.yml imports it once before the apply (a create
# would fail "already registered"); after adoption this resource manages it normally.
#
# Defaults (opportunistic TLS, tracking off) match a plain dashboard-created domain. The Resend API
# key never enters state; only the returned public records (output below) do.
resource "resend_domain" "sending" {
  name   = var.resend_sending_domain
  region = var.resend_region
}
