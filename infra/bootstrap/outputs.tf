output "service_account_email" {
  value = google_service_account.spacelift.email
}

output "workload_identity_pool" {
  value = google_iam_workload_identity_pool.spacelift.name
}

output "provider_resource" {
  value = google_iam_workload_identity_pool_provider.spacelift.name
}

output "credential_config_file" {
  description = "Federation config (no secrets, gitignored). Mount into the stack via `spacectl stack environment mount`; point GOOGLE_APPLICATION_CREDENTIALS at the mount."
  value       = local_file.credential_config.filename
}

output "spacelift_setup" {
  description = "Values to configure on the Spacelift stack."
  value = {
    GOOGLE_APPLICATION_CREDENTIALS = "/mnt/workspace/spacelift-gcp-credentials.json"
    mounted_file                   = "spacelift-gcp-credentials.json"
    oidc_token_path                = "/mnt/workspace/spacelift.oidc"
    space                          = var.spacelift_space_id
  }
}
