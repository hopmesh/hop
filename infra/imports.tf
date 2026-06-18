# TEMPORARY: adopt already-created resources into Spacelift-managed state.
# Remove after the import run succeeds.

import {
  to = google_artifact_registry_repository.hop
  id = "projects/hop-mesh/locations/us-central1/repositories/hop"
}

import {
  to = google_cloud_run_v2_service.relay["us-central1"]
  id = "projects/hop-mesh/locations/us-central1/services/hop-relay-us-central1"
}

import {
  to = google_cloud_run_v2_service_iam_member.public["us-central1"]
  id = "projects/hop-mesh/locations/us-central1/services/hop-relay-us-central1/roles/run.invoker/allUsers"
}

import {
  to = google_firestore_database.relay
  id = "projects/hop-mesh/databases/(default)"
}

import {
  to = google_firestore_field.bundle_ttl
  id = "projects/hop-mesh/databases/(default)/collectionGroups/bundles/fields/expireAt"
}

import {
  to = google_project_iam_member.relay_firestore
  id = "hop-mesh/roles/datastore.user/serviceAccount:hop-relay@hop-mesh.iam.gserviceaccount.com"
}

import {
  to = google_project_iam_member.relay_logs
  id = "hop-mesh/roles/logging.logWriter/serviceAccount:hop-relay@hop-mesh.iam.gserviceaccount.com"
}

import {
  to = google_project_service.this["artifactregistry.googleapis.com"]
  id = "hop-mesh/artifactregistry.googleapis.com"
}

import {
  to = google_project_service.this["cloudbuild.googleapis.com"]
  id = "hop-mesh/cloudbuild.googleapis.com"
}

import {
  to = google_project_service.this["compute.googleapis.com"]
  id = "hop-mesh/compute.googleapis.com"
}

import {
  to = google_project_service.this["firestore.googleapis.com"]
  id = "hop-mesh/firestore.googleapis.com"
}

import {
  to = google_project_service.this["run.googleapis.com"]
  id = "hop-mesh/run.googleapis.com"
}

import {
  to = google_project_service.this["secretmanager.googleapis.com"]
  id = "hop-mesh/secretmanager.googleapis.com"
}

import {
  to = google_secret_manager_secret.relay_identity
  id = "projects/hop-mesh/secrets/hop-relay-identity"
}

import {
  to = google_secret_manager_secret_iam_member.relay_identity
  id = "projects/hop-mesh/secrets/hop-relay-identity/roles/secretmanager.secretAccessor/serviceAccount:hop-relay@hop-mesh.iam.gserviceaccount.com"
}

import {
  to = google_service_account.relay
  id = "projects/hop-mesh/serviceAccounts/hop-relay@hop-mesh.iam.gserviceaccount.com"
}
