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

  # State lives in GCS (migrated off Spacelift). The bucket is created out-of-band
  # (chicken-and-egg with this module, so it must pre-exist) and is versioned for
  # rollback safety. GCS has native state locking — no DynamoDB-style lock table.
  backend "gcs" {
    bucket = "hop-mesh-tfstate"
    prefix = "relay-fleet"
  }
}
