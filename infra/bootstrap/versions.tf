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
    # Generates the credentials bootstrap seeds into Secret Manager (the hop-api-token bearer and the
    # hop_console Postgres password), so no operator ever invents or types them. These values live in
    # the bootstrap state, which is administrator-only, the same trust level as the state that already
    # holds this project's IAM authority.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "gcs" {
    bucket = "hop-mesh-tfstate"
    prefix = "bootstrap"
  }
}
