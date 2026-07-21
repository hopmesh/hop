variable "project_id" {
  description = "GCP project that hosts Hop production resources."
  type        = string
  default     = "hop-mesh"
}

variable "region" {
  description = "Control-plane region for Artifact Registry."
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

variable "github_repository" {
  description = "Canonical private GitHub repository in owner/name form. Scopes the WIF provider condition, the bootstrap-apply and runtime-deploy OIDC subjects, and billing-catalog impersonation."
  type        = string
  default     = "hopmesh/monorepo"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must use owner/name form."
  }
}

variable "runtime_state_bucket" {
  description = "Pre-existing versioned GCS bucket used by the runtime OpenTofu backend."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.runtime_state_bucket))
    error_message = "runtime_state_bucket must be a valid 3-63 character GCS bucket name."
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
