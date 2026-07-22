# Marketing site (the Astro app in web/) on GitHub Pages.
#
# Served at the apex hopme.sh; www.hopme.sh redirects to it (GitHub Pages issues the
# apex⇄www redirect automatically once both are configured). The relay fleet keeps the
# relay.hopme.sh subdomain (dns.tf); these records only touch the apex and www, so the
# two coexist in the same zone.
#
# GitHub Pages serves the custom domain from web/public/CNAME (= hopme.sh), published by
# the .github/workflows/pages.yml Actions deploy. The apex must use A/AAAA (apex can't be
# a CNAME); GitHub's published Pages anycast addresses are below.
# Ref: https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site

locals {
  # GitHub Pages apex A/AAAA targets (static, GitHub-published).
  github_pages_ipv4 = [
    "185.199.108.153",
    "185.199.109.153",
    "185.199.110.153",
    "185.199.111.153",
  ]
  github_pages_ipv6 = [
    "2606:50c0:8000::153",
    "2606:50c0:8001::153",
    "2606:50c0:8002::153",
    "2606:50c0:8003::153",
  ]
}

# hopme.sh → GitHub Pages (apex, dual-stack).
resource "google_dns_record_set" "apex_a" {
  name         = var.dns_zone_dns_name # hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "A"
  ttl          = 3600
  rrdatas      = local.github_pages_ipv4
}

resource "google_dns_record_set" "apex_aaaa" {
  name         = var.dns_zone_dns_name # hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "AAAA"
  ttl          = 3600
  rrdatas      = local.github_pages_ipv6
}

# www.hopme.sh → the org's Pages host; GitHub redirects www to the apex.
resource "google_dns_record_set" "www_cname" {
  name         = "www.${var.dns_zone_dns_name}" # www.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "CNAME"
  ttl          = 3600
  rrdatas      = [var.pages_cname_target]
}

# GitHub Pages domain verification (org "hopmesh"). Proves control of hopme.sh so the
# domain can't be claimed by another GitHub account. Covers the apex and its subdomains.
# Created only when var.pages_challenge_txt is set (the token comes from GitHub at
# verification time; keep it out of version control). Cloud DNS requires the TXT value
# wrapped in literal quotes.
resource "google_dns_record_set" "pages_challenge" {
  count        = var.pages_challenge_txt == "" ? 0 : 1
  name         = "_github-pages-challenge-hopmesh.${var.dns_zone_dns_name}" # _github-pages-challenge-hopmesh.hopme.sh.
  managed_zone = google_dns_managed_zone.hopme.name
  type         = "TXT"
  ttl          = 3600
  rrdatas      = ["\"${var.pages_challenge_txt}\""]
}
