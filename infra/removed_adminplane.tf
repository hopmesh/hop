# removed_adminplane.tf -- forget the admin-plane, do not destroy it.
#
# History: the runtime root (infra/*.tf) and the admin plane once lived in one OpenTofu
# state (gs://hop-mesh-tfstate/relay-fleet, serial 302). The admin-plane resources
# (service accounts, IAM bindings, secrets, the Artifact Registry repo, Firestore, the
# custom role, API enablement, the Cloud Build trigger + repo link, the state-bucket IAM
# grant) were RELOCATED into the bootstrap root (infra/bootstrap/**), which is applied by
# manual dispatch of bootstrap-apply.yml. Per infra/CLAUDE.md the runtime root must never
# contain project IAM, service-account IAM, secret IAM, custom roles, triggers, API
# enablement, or bootstrap resources, so those resources are declared NOWHERE in this root.
#
# The runtime state still TRACKS those ~41 admin-plane instances. Without these blocks the
# first runtime apply would read them as "in state, not in config" and DESTROY live
# resources: the hop-relay and hop-cloudbuild/build service accounts, the Artifact Registry
# repo (holding live container builds), the hop-relay-identity and hop-ci-readtoken secrets,
# the Firestore database and its TTL policy fields, the build_secrets custom role, ten
# enabled Google APIs, fourteen project IAM members, the state-bucket IAM member, and the
# Cloud Build trigger + cloudbuildv2 repository link.
#
# Each block below FORGETS the resource from runtime state (lifecycle destroy = false):
# state stops tracking it here, the live resource is untouched, and bootstrap remains its
# sole owner. OpenTofu removed{} `from` takes a whole-resource address (instance index keys
# are rejected by the language), so a for_each/count resource is forgotten with one block
# that drops all of its instances; the exact instance addresses are listed in comments.
#
# NOTE on google_cloud_run_v2_service_iam_member.example_public: it is deliberately NOT
# forgotten here. See the runtime apply note at the bottom of this file.

# --- Service accounts ---------------------------------------------------------------

removed {
  from = google_service_account.relay
  lifecycle {
    destroy = false
  }
}

# instance in state: google_service_account.build[0]
removed {
  from = google_service_account.build
  lifecycle {
    destroy = false
  }
}

# --- Project IAM members (14 instances total) ---------------------------------------

# google_project_iam_member.build has 12 instances in state:
#   google_project_iam_member.build["projects/hop-mesh/roles/hopCloudBuildSecrets"]
#   google_project_iam_member.build["roles/artifactregistry.writer"]
#   google_project_iam_member.build["roles/cloudbuild.builds.builder"]
#   google_project_iam_member.build["roles/cloudbuild.connectionAdmin"]
#   google_project_iam_member.build["roles/editor"]
#   google_project_iam_member.build["roles/iam.serviceAccountAdmin"]
#   google_project_iam_member.build["roles/iam.serviceAccountUser"]
#   google_project_iam_member.build["roles/logging.admin"]
#   google_project_iam_member.build["roles/logging.logWriter"]
#   google_project_iam_member.build["roles/resourcemanager.projectIamAdmin"]
#   google_project_iam_member.build["roles/run.admin"]
#   google_project_iam_member.build["roles/storage.admin"]
removed {
  from = google_project_iam_member.build
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_project_iam_member.relay_firestore
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_project_iam_member.relay_logs
  lifecycle {
    destroy = false
  }
}

# --- Custom role --------------------------------------------------------------------

# instance in state: google_project_iam_custom_role.build_secrets[0]
removed {
  from = google_project_iam_custom_role.build_secrets
  lifecycle {
    destroy = false
  }
}

# --- Secrets + secret IAM -----------------------------------------------------------

removed {
  from = google_secret_manager_secret.relay_identity
  lifecycle {
    destroy = false
  }
}

# instance in state: google_secret_manager_secret.ci_readtoken[0]
removed {
  from = google_secret_manager_secret.ci_readtoken
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_secret_manager_secret_iam_member.relay_identity
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_secret_manager_secret_iam_member.example_identity
  lifecycle {
    destroy = false
  }
}

# instance in state: google_secret_manager_secret_iam_member.build_ci_readtoken[0]
removed {
  from = google_secret_manager_secret_iam_member.build_ci_readtoken
  lifecycle {
    destroy = false
  }
}

# --- State-bucket IAM ---------------------------------------------------------------

# instance in state: google_storage_bucket_iam_member.build_state[0]
removed {
  from = google_storage_bucket_iam_member.build_state
  lifecycle {
    destroy = false
  }
}

# --- Artifact Registry --------------------------------------------------------------

removed {
  from = google_artifact_registry_repository.hop
  lifecycle {
    destroy = false
  }
}

# --- Firestore database + TTL policy fields -----------------------------------------

removed {
  from = google_firestore_database.relay
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_firestore_field.bundle_ttl
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_firestore_field.presence_ttl
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_firestore_field.registry_ttl
  lifecycle {
    destroy = false
  }
}

# --- API enablement (10 instances) --------------------------------------------------

# google_project_service.this has 10 instances in state:
#   google_project_service.this["artifactregistry.googleapis.com"]
#   google_project_service.this["certificatemanager.googleapis.com"]
#   google_project_service.this["cloudbuild.googleapis.com"]
#   google_project_service.this["compute.googleapis.com"]
#   google_project_service.this["dns.googleapis.com"]
#   google_project_service.this["firestore.googleapis.com"]
#   google_project_service.this["logging.googleapis.com"]
#   google_project_service.this["monitoring.googleapis.com"]
#   google_project_service.this["run.googleapis.com"]
#   google_project_service.this["secretmanager.googleapis.com"]
removed {
  from = google_project_service.this
  lifecycle {
    destroy = false
  }
}

# --- Cloud Build trigger + cloudbuildv2 repository link ------------------------------

# instance in state: google_cloudbuild_trigger.image[0]
removed {
  from = google_cloudbuild_trigger.image
  lifecycle {
    destroy = false
  }
}

# instance in state: google_cloudbuildv2_repository.hop[0]
removed {
  from = google_cloudbuildv2_repository.hop
  lifecycle {
    destroy = false
  }
}

# --- Runtime apply note: google_cloud_run_v2_service_iam_member.example_public -------
#
# This is the allUsers run.invoker grant on the hop-example service. It is in runtime state
# and declared nowhere, but it is intentionally EXCLUDED from the removed{} set above.
#
# The example service (infra/example.tf) is INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER with
# invoker_iam_disabled = true, so the allUsers binding is already inert (invoker IAM is not
# consulted). Forgetting it with destroy = false would leave a live, unmanaged public grant
# with no owning root. Instead we let the runtime apply reconcile it: in state, not in
# config, not forgotten, so OpenTofu plans to DELETE the binding, which cleanly removes the
# stray allUsers grant. That is the safe outcome, no stray public grant is left unmanaged.
