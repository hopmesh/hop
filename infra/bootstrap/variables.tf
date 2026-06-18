variable "project_id" {
  description = "GCP project Spacelift will manage."
  type        = string
  default     = "hop-mesh"
}

variable "spacelift_hostname" {
  description = "Spacelift account hostname — the OIDC audience, and (with https://) the issuer."
  type        = string
  default     = "hopmesh.app.us.spacelift.io"
}

variable "spacelift_space_id" {
  description = "Spacelift space whose runs may impersonate the SA (scopes attribute.space)."
  type        = string
  default     = "root"
}

variable "pool_id" {
  description = "Workload Identity Pool id."
  type        = string
  default     = "spacelift"
}

variable "provider_id" {
  description = "Workload Identity Pool OIDC provider id."
  type        = string
  default     = "spacelift-oidc"
}

variable "sa_account_id" {
  description = "Account id for the Spacelift automation service account."
  type        = string
  default     = "spacelift"
}

variable "sa_roles" {
  description = "Project roles granted to the Spacelift SA (broad: it manages the whole infra/ module)."
  type        = list(string)
  default     = ["roles/owner"]
}
