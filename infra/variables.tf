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

variable "spacelift_commit_sha" {
  description = "Injected by Spacelift (TF_VAR_spacelift_commit_sha). Used to derive the deploy image tag so it matches the commit Cloud Build built."
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
    in-memory per process, so a second instance is a second, disconnected node.
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

variable "manage_dns" {
  description = "If true, create/manage a Cloud DNS zone for the domain. Leave false while hopme.sh DNS lives elsewhere — then add the A record by hand to the LB IP."
  type        = bool
  default     = false
}

variable "dns_zone_name" {
  description = "Cloud DNS managed-zone resource name (only used when manage_dns = true)."
  type        = string
  default     = "hopme-sh"
}

variable "dns_zone_dns_name" {
  description = "The zone apex with trailing dot (only used when manage_dns = true), e.g. hopme.sh."
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
