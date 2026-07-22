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

variable "relay_image" {
  description = "Immutable hop-relayd image reference produced by the trusted build, including an exact sha256 digest."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$", var.relay_image))
    error_message = "relay_image must be an immutable Artifact Registry reference ending in @sha256:<64 lowercase hex>."
  }
}

variable "example_image" {
  description = "Immutable hop-example image reference produced by the trusted build, including an exact sha256 digest."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$", var.example_image))
    error_message = "example_image must be an immutable Artifact Registry reference ending in @sha256:<64 lowercase hex>."
  }
}

variable "accountd_image" {
  description = "Immutable hop-accountd image reference built by runtime-deploy.yml, including an exact sha256 digest."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$", var.accountd_image))
    error_message = "accountd_image must be an immutable Artifact Registry reference ending in @sha256:<64 lowercase hex>."
  }
}

variable "console_image" {
  description = "Immutable hop-console image reference built by runtime-deploy.yml, including an exact sha256 digest."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$", var.console_image))
    error_message = "console_image must be an immutable Artifact Registry reference ending in @sha256:<64 lowercase hex>."
  }
}

# The Cloud SQL instance backing hop-accountd is bootstrap-owned (infra/bootstrap/console.tf), so the
# runtime root cannot reference the resource. Its connection name is deterministic from the project,
# region, and instance name, so pin it here; the accountd template mounts the Auth proxy socket at
# /cloudsql/<connection name>. The password never appears in this root at all: bootstrap generates it
# and composes the whole DSN into the console-db-url secret that accountd reads as DATABASE_URL.
variable "console_db_connection_name" {
  description = "Cloud SQL connection name (project:region:instance) for the bootstrap-owned hop_console Postgres."
  type        = string
  default     = "hop-mesh:us-central1:hop-console-db"
}

# hop-accountd's GitHub OAuth client id. NOT a secret: an OAuth client id is public by construction
# (it rides in the authorize redirect URL every browser sees), so it lives in code where it is
# reviewable rather than in Secret Manager. The matching client secret is a real secret and stays in
# the bootstrap-owned hop-github-oauth-client-secret container.
variable "github_client_id" {
  description = "Public GitHub OAuth client id for console sign-in (GITHUB_CLIENT_ID)."
  type        = string
  default     = "Ov23lidjG8DrCaoi8hT3"
}

# The envelope-from address for console transactional mail. Public by construction (it is printed in
# every message header), so it is plain config. The Resend API key remains a secret.
variable "resend_from" {
  description = "From address for console transactional email (RESEND_FROM)."
  type        = string
  default     = "noreply@account.hopme.sh"
}

variable "deployment_source_sha" {
  description = "Exact source revision (the merged main commit) that GitHub Actions is deploying after CI went green."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.deployment_source_sha))
    error_message = "deployment_source_sha must be exactly 40 lowercase hexadecimal characters."
  }
}

variable "deployment_environment" {
  description = "Deployment environment name (normally production), passed by the runtime-deploy workflow."
  type        = string

  validation {
    condition     = length(trimspace(var.deployment_environment)) > 0
    error_message = "deployment_environment must not be empty."
  }
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
    Currently false in the trusted bootstrap trigger configuration (P2P-only test phase); update the
    bootstrap variable and re-apply that separately to re-enable.
  EOT
  type        = bool
  default     = false
}

variable "domain" {
  description = "DNS name clients connect to (anycast across all regions)."
  type        = string
  default     = "relay.hopme.sh"
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
    Who may reach the Cloud Run services. Production uses only internal and load-balancer
    ingress; the default run.app URI is disabled on each service.
  EOT
  type        = string
  default     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
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

# F-23: the relay identity secret version each region mounts. A mutable alias can silently re-key the
# fleet on a cold start, so the trusted deployment must pass a positive numeric version.
variable "relay_identity_version" {
  description = "Pinned numeric Secret Manager version of the relay identity to mount."
  type        = string

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.relay_identity_version))
    error_message = "relay_identity_version must be a positive numeric Secret Manager version."
  }
}

variable "example_identity_version" {
  description = "Pinned Secret Manager version for the public example identity."
  type        = string

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.example_identity_version))
    error_message = "example_identity_version must be a positive numeric Secret Manager version."
  }
}
