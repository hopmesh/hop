terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Bootstrap state is local on purpose: this module GRANTS Spacelift its access,
  # so it can't run in Spacelift (chicken-and-egg). Apply it once, locally, as a
  # human (jason@waldrip.net). Commit the state or keep it — it holds no secrets.
}
