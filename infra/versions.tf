terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # State is managed by Spacelift by default. To run locally instead, uncomment
  # and point at a GCS bucket you create out-of-band (chicken-and-egg with this
  # module, so it must pre-exist):
  #
  # backend "gcs" {
  #   bucket = "hop-mesh-tfstate"
  #   prefix = "relay-fleet"
  # }
}
