variable "project_id" {
  description = "GCP project that hosts Hop production resources."
  type        = string
  default     = "hop-mesh"
}

variable "region" {
  description = "Control-plane region for Cloud Build, Artifact Registry, and KMS."
  type        = string
  default     = "us-central1"
}

variable "firestore_location" {
  description = "Firestore location. Use a multi-region such as nam5 or eur3 for the durable store."
  type        = string
  default     = "nam5"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]+$", var.firestore_location))
    error_message = "firestore_location must be a valid lowercase Google Cloud location."
  }
}

variable "build_connection_name" {
  description = "Existing Cloud Build v2 GitHub App connection name."
  type        = string

  validation {
    condition     = length(trimspace(var.build_connection_name)) > 0
    error_message = "build_connection_name is required."
  }
}

variable "github_repository" {
  description = "Canonical private GitHub repository in owner/name form."
  type        = string
  default     = "hopmesh/hop"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must use owner/name form."
  }
}

variable "github_repository_id" {
  description = "Immutable numeric GitHub repository id from GET /repos/{owner}/{repo}."
  type        = number

  validation {
    condition     = var.github_repository_id > 0
    error_message = "github_repository_id is required and must be positive."
  }
}

variable "github_actions_app_id" {
  description = "Numeric App id for the GitHub Actions App that owns the trusted check suite."
  type        = number

  validation {
    condition     = var.github_actions_app_id > 0
    error_message = "github_actions_app_id is required and must be positive."
  }
}

variable "github_ci_workflow_id" {
  description = "Immutable numeric workflow id for .github/workflows/ci.yml."
  type        = number

  validation {
    condition     = var.github_ci_workflow_id > 0
    error_message = "github_ci_workflow_id is required and must be positive."
  }
}

variable "github_ci_workflow_sha256" {
  description = "Bootstrap-owned SHA-256 of the exact trusted .github/workflows/ci.yml bytes."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.github_ci_workflow_sha256))
    error_message = "github_ci_workflow_sha256 must be exactly 64 lowercase hexadecimal characters."
  }
}

variable "github_required_checks" {
  description = "Exact complete job set expected from the current attempt of the trusted CI workflow."
  type        = list(string)
  default = [
    "Detect changed areas",
    "Rust (test · clippy · fmt)",
    "Kotlin SDK tests (BearerManager)",
    "Android bearers + driver (JVM unit tests)",
    "Apple bearers + driver + app (build-only)",
    "WASM sim (wasm32 build + swarm invariants)",
    "Web + sim (Astro build · scenario-check · link check)",
    "Contract purity + header drift + C smoke",
    "Terraform (fmt · validate · plan)",
    "Automation authority guards",
    "Docs token guard (banned copy)",
    "Node endpoint SDK (proofs)",
    "Python endpoint SDK (proofs)",
    "Go endpoint SDK (race)",
    "Ruby endpoint SDK (proofs)",
    "Crystal endpoint SDK (spec)",
    "Elixir endpoint SDK (mix test)",
    "CI gate",
  ]

  validation {
    condition = (
      length(var.github_required_checks) > 0 &&
      length(var.github_required_checks) == length(distinct(var.github_required_checks)) &&
      alltrue([for name in var.github_required_checks : name == trimspace(name) && name != ""])
    )
    error_message = "github_required_checks must be non-empty, trimmed, and duplicate-free."
  }
}

variable "ci_token_secret_version" {
  description = "Pinned numeric version of hop-ci-readtoken."
  type        = string

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.ci_token_secret_version))
    error_message = "ci_token_secret_version must be a positive numeric secret version."
  }
}

variable "relay_identity_version" {
  description = "Pinned numeric version of hop-relay-identity used by the runtime root."
  type        = string

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.relay_identity_version))
    error_message = "relay_identity_version must be a positive numeric secret version."
  }
}

variable "example_identity_version" {
  description = "Pinned numeric version of hop-example-identity used by the runtime root."
  type        = string

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.example_identity_version))
    error_message = "example_identity_version must be a positive numeric secret version."
  }
}

variable "deployment_environment" {
  description = "Externally governed deployment environment name, normally production."
  type        = string

  validation {
    condition     = length(trimspace(var.deployment_environment)) > 0
    error_message = "deployment_environment is required."
  }
}

variable "deploy_approver_group" {
  description = "Google group email granted Cloud Build Approver for trusted runtime deployments."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$", var.deploy_approver_group))
    error_message = "deploy_approver_group must be a valid group email address."
  }
}

variable "control_bucket_name" {
  description = "Globally unique GCS bucket for immutable provenance, bootstrap contract, and the deployment lease."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.control_bucket_name))
    error_message = "control_bucket_name must be a valid 3-63 character GCS bucket name."
  }
}

variable "runtime_state_bucket" {
  description = "Pre-existing versioned GCS bucket used by the runtime OpenTofu backend."
  type        = string

  validation {
    condition = (
      can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.runtime_state_bucket)) &&
      var.runtime_state_bucket != var.control_bucket_name
    )
    error_message = "runtime_state_bucket must be a valid GCS bucket distinct from the deployment control bucket."
  }
}

variable "runtime_state_prefix" {
  description = "GCS backend prefix for runtime state."
  type        = string
  default     = "relay-fleet"

  validation {
    condition = (
      can(regex("^[A-Za-z0-9][A-Za-z0-9._/-]*$", var.runtime_state_prefix)) &&
      length(var.runtime_state_prefix) <= 1024 &&
      !endswith(var.runtime_state_prefix, "/") &&
      !strcontains(var.runtime_state_prefix, "//") &&
      !contains(["bootstrap", "billing"], split("/", var.runtime_state_prefix)[0])
    )
    error_message = "runtime_state_prefix must be a non-reserved path without leading, trailing, or repeated slashes."
  }
}

variable "lease_ttl_seconds" {
  description = "Bound on an abandoned global deployment lease. Must exceed the deploy build timeout."
  type        = number
  default     = 7200

  validation {
    condition     = var.lease_ttl_seconds >= 3900 && var.lease_ttl_seconds <= 14400
    error_message = "lease_ttl_seconds must be between 3900 and 14400 so it exceeds the deploy timeout."
  }
}

variable "relays_enabled" {
  description = "Trusted control-plane switch for the relay fleet."
  type        = bool
  default     = false
}

variable "cloud_run_ingress" {
  description = "Runtime relay ingress setting."
  type        = string
  default     = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
}

variable "max_instances_per_region" {
  description = "Runtime per-region instance ceiling."
  type        = number
  default     = 1
}

variable "region_allowlist" {
  description = "Trusted runtime region allowlist. Empty uses every supported region."
  type        = list(string)
  default     = []
}

variable "relay_domain" {
  description = "Aggregate relay domain used by the post-deploy liveness check."
  type        = string
  default     = "relay.hopme.sh"
}
