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
  description = "Canonical GitHub repository whose main-branch workflows may deploy Hop."
  type        = string
  default     = "hopmesh/hop"

  validation {
    condition     = var.github_repository == "hopmesh/hop"
    error_message = "github_repository is fixed to hopmesh/hop."
  }
}

variable "runtime_state_bucket" {
  description = "Versioned GCS bucket used by every Hop OpenTofu state root."
  type        = string
  default     = "hop-mesh-tfstate"

  validation {
    condition     = var.runtime_state_bucket == "hop-mesh-tfstate"
    error_message = "runtime_state_bucket is fixed to hop-mesh-tfstate."
  }
}

variable "runtime_state_prefix" {
  description = "GCS backend prefix for runtime state."
  type        = string
  default     = "relay-fleet"

  validation {
    condition     = var.runtime_state_prefix == "relay-fleet"
    error_message = "runtime_state_prefix is fixed to relay-fleet."
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

# HISTORICAL, and kept because it cost nine days of silently broken deploys.
#
# This file used to define two exact immutable OIDC subjects, and hop-deploy, bootstrap-apply and
# billing-catalog-apply bound to them with `principal://.../subject/<subject>`. GitHub's immutable sub is
# `repo:<org>@<org_id>/<repo>@<repo_id>:ref:<ref>` rather than the name-based `repo:<org>/<repo>:ref:<ref>`,
# and a comment here recorded that shape as verified by decoding a real Actions OIDC token.
#
# It still broke. Whatever GitHub presented from 2026-08-07 onward did not equal that string, every
# impersonation was refused with "Permission 'iam.serviceAccounts.getAccessToken' denied", and nothing
# surfaced it: the deploy is fire-and-forget and the only workflow that would have caught it, the
# bootstrap plan, runs solely on manual dispatch. Runtime deploy was dead for nine days.
#
# The root cause is that the sub claim is not ours to control. It is shaped by a REPOSITORY-level GitHub
# setting (Settings > Actions > OIDC subject claim, `use_default` / `use_immutable_subject` /
# `include_claim_keys`) that can be changed with an API call by anyone with admin, from outside this
# codebase, with no signal here. Pinning infrastructure trust to it makes a repository toggle able to
# revoke every deploy identity silently.
#
# So the bindings now match on `attribute.ref` instead, which is mapped from `assertion.ref` by the
# provider in billing.tf and is not affected by sub-claim customization. The org and repository ids are
# gone with the subjects that used them; the repository is still pinned, by the provider's
# attribute_condition. See the note on the binding in runtime_deploy.tf for the differential test that
# proved which half was wrong.
