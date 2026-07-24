# The console sending domain, registered IN Resend. This is the piece that was missing: nothing
# previously created the domain on Resend's side, so the dashboard showed no domain to verify and mail
# from noreply@account.hopme.sh had no verified sender. Registering it here returns the DNS records
# Resend expects, which the runtime root publishes into the hopme.sh zone (infra/resend_dns.tf reads
# them from this root's state, the billing state it already consumes for the Stripe price ids).
#
# Defaults (opportunistic TLS, tracking off) match a plain dashboard-created domain. The Resend API
# key never enters state; only the returned public records (output below) do.
resource "resend_domain" "sending" {
  name   = var.resend_sending_domain
  region = var.resend_region
}
