terraform {
  # Floor matches the version that writes this module's state and the version every runner is
  # pinned to (CI setup-opentofu + the bootstrap inline deploy image are both 1.12.3, whose
  # comment already notes the runner "must be >= the version that wrote the state"). Enforcing that
  # here means an older tofu can't fmt/validate/plan/apply against 1.12-written state and hit a
  # confusing state-version error; it fails fast with a clear "requires >= 1.12" instead.
  required_version = ">= 1.12"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.7.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # State lives in GCS (migrated off Spacelift). The bucket is created out-of-band
  # (chicken-and-egg with this module, so it must pre-exist) and is versioned for
  # rollback safety. GCS has native state locking, no DynamoDB-style lock table.
  backend "gcs" {
    bucket = "hop-mesh-tfstate"
    prefix = "relay-fleet"
  }
}
