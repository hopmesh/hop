variable "project_id" {
  description = "GCP project that hosts the Hop relay fleet."
  type        = string
  default     = "hop-mesh"
}

variable "excluded_regions" {
  description = "Regions to skip when going all-regions (only used when region_allowlist is empty)."
  type        = set(string)
  # me-central2 returns 403 (not available to this project).
  default = ["me-central2"]
}

variable "build_connection_name" {
  description = "Cloud Build 2nd-gen GitHub connection name. Empty disables the GitOps build trigger."
  type        = string
  default     = ""
}

variable "deploy_image_sha" {
  description = "Commit short-sha to deploy. Passed by the Cloud Build apply step as -var deploy_image_sha=$SHORT_SHA so the relay + example images match the just-built commit. Empty falls back to :latest."
  type        = string
  default     = ""
}

variable "region_allowlist" {
  description = <<-EOT
    If non-empty, deploy ONLY to these regions (overrides the all-regions data source).
    Use this to pin a working curated set within the project's Cloud Run region quota;
    empty = all available regions minus excluded_regions (needs quota for ~43 regions).
  EOT
  type        = list(string)
  default     = []
}

variable "relays_enabled" {
  description = <<-EOT
    Master switch for the relay fleet. When false, local.regions is emptied so NO relay Cloud Run
    services (nor their per-region NEGs / backends / IAM) are deployed and any existing ones are
    torn down. The anycast LB, wildcard cert, DNS, Firestore, and the example endpoint stay up, so
    flipping this back to true (and re-applying) restores the fleet on the SAME IP/cert/DNS.
    Currently false in cloudbuild.trigger.yaml (P2P-only test phase); flip that line to re-enable.
  EOT
  type        = bool
  default     = true
}

variable "domain" {
  description = "DNS name clients connect to (anycast across all regions)."
  type        = string
  default     = "relay.hopme.sh"
}

variable "relay_image" {
  description = <<-EOT
    Full container image reference for hop-relayd, e.g.
    us-central1-docker.pkg.dev/hop-mesh/hop/hop-relayd:latest. Build & push with
    `make -C infra image` (see infra/README.md). The container runs the relay's
    WebSocket bearer on $PORT so Cloud Run can front it.
  EOT
  type        = string
  default     = ""
}

variable "max_instances_per_region" {
  description = <<-EOT
    Upper bound on Cloud Run instances per region. Pin to 1 until the relay shares
    its directory/store across instances: presence and the bundle hot-path are
    in-memory per process, so a second instance is a second, disconnected node
    (split-brain). D-429: raising this is NOT the fix — it would be worse than the
    429s. The 429/wake-churn cause is already mitigated by the handoff-only default
    (mesh_fanout = 0) so regions don't full-mesh-dial each other; the real unlock for
    a higher ceiling is cross-instance directory/store sharing, a separate project.
  EOT
  type        = number
  default     = 1
}

variable "mesh_fanout" {
  description = <<-EOT
    Online-only relay-to-relay epidemic fan-out (DESIGN.md §28): each relay dials up to this
    many *currently-online* peer relays (never wakes a sleeping one). 0 = handoff-only (no
    relay-to-relay dialing) — the safe default. Raise to a small number (e.g. 2-3) to enable
    the partial-mesh epidemic; avoid large values (a full mesh re-creates the 429 load).
  EOT
  type        = number
  default     = 0
}

variable "example_region" {
  description = "Region for the example.hopme.sh hops:// demo endpoint (one region is enough)."
  type        = string
  default     = "us-central1"
}

variable "cloud_run_ingress" {
  description = <<-EOT
    Who may reach the Cloud Run services directly. "INGRESS_TRAFFIC_ALL" exposes the
    *.run.app URL (valid Google TLS, no custom DNS needed) — use this to test before
    DNS exists. Switch to "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" once the LB +
    relay.hopme.sh are the front door. Auth is the Noise handshake either way.
  EOT
  type        = string
  default     = "INGRESS_TRAFFIC_ALL"
}

variable "firestore_location" {
  description = "Firestore location. Use a multi-region (nam5, eur3) for the durable store."
  type        = string
  default     = "nam5"
}

variable "ws_request_timeout_seconds" {
  description = "Max lifetime of a single WebSocket connection before the client must reconnect (Cloud Run cap is 3600)."
  type        = number
  default     = 3600
}

# infra-r2-03: hopme.sh DNS is ALWAYS managed in this module (dns.tf creates the zone + records with
# no gate; pages_dns.tf, mail_dns.tf, and example.tf all reference the zone unconditionally). The old
# `manage_dns` toggle was a no-op - it never gated anything - so it was removed to stop implying DNS
# could stay external. Delegate hopme.sh to the `name_servers` output to hand DNS to this zone.
variable "dns_zone_name" {
  description = "Cloud DNS managed-zone resource name for hopme.sh (DNS is always managed here; see dns.tf)."
  type        = string
  default     = "hopme-sh"
}

variable "dns_zone_dns_name" {
  description = "The hopme.sh zone apex with trailing dot, e.g. hopme.sh. (DNS is always managed here; see dns.tf)."
  type        = string
  default     = "hopme.sh."
}

variable "pages_cname_target" {
  description = <<-EOT
    CNAME target for www.hopme.sh — the GitHub Pages host for the marketing site
    (web/), i.e. "<org>.github.io." with a trailing dot. The apex hopme.sh uses
    A/AAAA records to GitHub's Pages anycast IPs instead (see pages_dns.tf).
  EOT
  type        = string
  default     = "hopmesh.github.io."
}

variable "pages_challenge_txt" {
  description = <<-EOT
    GitHub Pages domain-verification token. GitHub (org Settings → Pages →
    "Add a domain", or Settings → Verified domains) asks you to publish a TXT
    record at _github-pages-challenge-hopmesh.hopme.sh with the token it shows;
    verifying the domain guards it against takeover. Set this (TF_VAR_pages_challenge_txt
    or a tfvars file) and the record in pages_dns.tf is created; leave empty to skip it.
    Not a credential — only proves DNS control, so it is safe to keep in version control.
  EOT
  type        = string
  default     = "a6ef60e39735942241ca277889d93d"
}

variable "google_dkim_txt" {
  description = <<-EOT
    Google Workspace DKIM value for google._domainkey.hopme.sh, generated in the Admin
    console (Apps → Google Workspace → Gmail → Authenticate email → Generate new record).
    The 2048-bit key exceeds the 255-char TXT limit, so supply it split into quoted
    chunks: '"v=DKIM1; k=rsa; p=<first 255 chars>" "<remainder>"'. Set via
    TF_VAR_google_dkim_txt or a tfvars file; leave empty to skip the record (see
    mail_dns.tf) until the key exists. Not a credential — it is a public DNS record.
  EOT
  type        = string
  default     = ""
}

# F-23: the relay identity secret VERSION each region mounts. "latest" silently re-keys the fleet on
# a rotation (Cloud Run resolves it at cold start); pin the numeric version that was seeded for prod.
variable "relay_identity_version" {
  description = "Secret Manager version of the relay identity to mount ('latest' for dev; a pinned number for prod). See cloud_run.tf / docs/audits/GAP-ANALYSIS.md F-23."
  type        = string
  default     = "latest"
}
