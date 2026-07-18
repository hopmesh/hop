terraform {
  required_version = ">= 1.12"

  # Keep provider state schemas aligned with runtime because administrator migrations move
  # control-plane resource bindings from the runtime state into this state.
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.7.0"
    }
  }

  backend "gcs" {
    bucket = "hop-mesh-tfstate"
    prefix = "bootstrap"
  }
}
