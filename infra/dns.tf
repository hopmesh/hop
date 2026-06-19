# Public DNS zone for hopme.sh. Delegate the registrar's nameservers to the
# `name_servers` output below; once propagated, records (relay.hopme.sh, etc.) are
# managed here in Terraform.
resource "google_dns_managed_zone" "hopme" {
  name        = var.dns_zone_name     # "hopme-sh"
  dns_name    = var.dns_zone_dns_name # "hopme.sh."
  description = "Hop public DNS zone (hopme.sh)"
  visibility  = "public"

  depends_on = [google_project_service.this]
}

# relay.hopme.sh is added once we pick its entry point (global LB anycast IP or a
# Cloud Run domain mapping). Held until the zone is delegated and propagating.
