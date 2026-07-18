locals {
  docker_builder_image = "gcr.io/cloud-builders/docker@sha256:4a33059c95a600582497fac50780c1c4f68388338fb54002a95b99af85b8f651"
  gcloud_builder_image = "gcr.io/cloud-builders/gcloud@sha256:f0fb55d6de1530ad854762fbaecf4d430ebad070cd2dc190e5061369267abf3b"
  tofu_builder_image   = "ghcr.io/opentofu/opentofu:1.12.3@sha256:a0766d12f07b43e66f2ed40d7a8babe97d581d20339c68ad0ab561737af9a5b3"
  source_trigger_name  = "hop-source-build"
  deploy_trigger_name  = "hop-runtime-deploy"
  contract_object      = "bootstrap/contract-v1.json"
  lease_object         = "leases/global.json"
  kms_key_version      = "${google_kms_crypto_key.provenance.id}/cryptoKeyVersions/1"
  ci_gate_script       = file("${path.module}/../../tools/require-ci-verdict.py")
  provenance_script    = file("${path.module}/../../tools/deploy-provenance.py")
  expected_gate_b64    = base64encode(jsonencode(local.github_expected))
}

resource "google_cloudbuildv2_repository" "hop" {
  name              = "monorepo"
  location          = var.region
  parent_connection = "projects/${var.project_id}/locations/${var.region}/connections/${var.build_connection_name}"
  remote_uri        = "https://github.com/${var.github_repository}.git"

  depends_on = [google_project_service_identity.cloudbuild]
}

# This is the only source-connected trigger. Its build definition is stored inline
# in the Cloud Build control plane. Candidate source can change Dockerfiles, but it
# cannot change these steps until an administrator separately applies bootstrap.
resource "google_cloudbuild_trigger" "source" {
  name        = local.source_trigger_name
  description = "Low-privilege source build with trusted CI and provenance handoff"
  location    = var.region

  repository_event_config {
    repository = google_cloudbuildv2_repository.hop.id
    push {
      branch = "^main$"
    }
  }

  service_account = google_service_account.build.id
  substitutions = {
    _TRUSTED_CONFIG_VERSION = "v2"
    _TRUSTED_REPOSITORY     = var.github_repository
    _TRUSTED_REPOSITORY_ID  = tostring(var.github_repository_id)
    _TRUSTED_CI_SHA256      = var.github_ci_workflow_sha256
  }

  build {
    step {
      name     = local.gcloud_builder_image
      id       = "authority-preflight"
      wait_for = ["-"]
      script   = local.provenance_script
      env = [
        "TRUSTED_PROVENANCE_MODE=authority-preflight",
        "BUILD_PROJECT_ID=${var.project_id}",
        "AUTHORITY_PROFILE=build",
        "EXPECTED_IDENTITY=${local.build_identity}",
        "CONTROL_BUCKET=${google_storage_bucket.deploy_control.name}",
        "RUNTIME_STATE_BUCKET=${var.runtime_state_bucket}",
        "BUILD_CONNECTION_RESOURCE=${google_cloudbuildv2_repository.hop.parent_connection}",
        "BUILD_REPOSITORY_RESOURCE=${google_cloudbuildv2_repository.hop.id}",
      ]
    }

    step {
      name     = local.docker_builder_image
      id       = "build-relayd"
      wait_for = ["authority-preflight"]
      args = [
        "build",
        "-f",
        "services/hop-relayd/Dockerfile",
        "-t",
        "${local.relay_image_repository}:$COMMIT_SHA",
        ".",
      ]
    }

    step {
      name     = local.docker_builder_image
      id       = "build-example"
      wait_for = ["authority-preflight"]
      args = [
        "build",
        "-f",
        "services/hop-endpoint/Dockerfile",
        "-t",
        "${local.example_image_repository}:$COMMIT_SHA",
        ".",
      ]
    }

    step {
      name       = local.gcloud_builder_image
      id         = "require-ci"
      wait_for   = ["authority-preflight"]
      script     = local.ci_gate_script
      secret_env = ["GH_TOKEN"]
      env = [
        "TRUSTED_GATE_MODE=gate",
        "EXPECTED_WORKFLOWS_B64=${local.expected_gate_b64}",
        "SOURCE_SHA=$COMMIT_SHA",
        "GATE_DEADLINE_SECONDS=1500",
        "GATE_POLL_SECONDS=20",
      ]
    }

    step {
      name     = local.docker_builder_image
      id       = "push-relayd"
      wait_for = ["build-relayd"]
      args     = ["push", "${local.relay_image_repository}:$COMMIT_SHA"]
    }

    step {
      name     = local.docker_builder_image
      id       = "push-example"
      wait_for = ["build-example"]
      args     = ["push", "${local.example_image_repository}:$COMMIT_SHA"]
    }

    step {
      name     = local.gcloud_builder_image
      id       = "signed-handoff"
      wait_for = ["push-relayd", "push-example", "require-ci"]
      script   = local.provenance_script
      env = [
        "TRUSTED_PROVENANCE_MODE=source-handoff",
        "SOURCE_SHA=$COMMIT_SHA",
        "SOURCE_BUILD_ID=$BUILD_ID",
        "BUILD_PROJECT_ID=${var.project_id}",
        "TRUSTED_REPOSITORY=${var.github_repository}",
        "TRUSTED_REPOSITORY_ID=${var.github_repository_id}",
        "BUILDER_IDENTITY=${local.build_identity}",
        "SOURCE_TRIGGER_NAME=${local.source_trigger_name}",
        "DEPLOYMENT_ENVIRONMENT=${var.deployment_environment}",
        "KMS_KEY_VERSION=${local.kms_key_version}",
        "RELAY_IMAGE_REPOSITORY=${local.relay_image_repository}",
        "EXAMPLE_IMAGE_REPOSITORY=${local.example_image_repository}",
        "PROVENANCE_BUCKET=${google_storage_bucket.deploy_control.name}",
        "DEPLOY_REQUEST_TOPIC=${google_pubsub_topic.deploy_requests.name}",
        "RUNTIME_SOURCE_DIR=/workspace/infra",
      ]
    }

    images = [
      "${local.relay_image_repository}:$COMMIT_SHA",
      "${local.example_image_repository}:$COMMIT_SHA",
    ]

    available_secrets {
      secret_manager {
        version_name = "${google_secret_manager_secret.ci_readtoken.id}/versions/${var.ci_token_secret_version}"
        env          = "GH_TOKEN"
      }
    }

    options {
      machine_type            = "E2_HIGHCPU_8"
      logging                 = "CLOUD_LOGGING_ONLY"
      requested_verify_option = "VERIFIED"
      source_provenance_hash  = ["SHA256"]
      dynamic_substitutions   = true
      substitution_option     = "MUST_MATCH"
    }

    timeout = "3600s"
  }

  depends_on = [
    google_artifact_registry_repository_iam_member.build_writer,
    google_iam_deny_policy.relay_seed,
    google_kms_crypto_key_iam_member.build_signer,
    google_project_iam_member.build,
    google_pubsub_topic_iam_member.build_handoff,
    google_secret_manager_secret_iam_member.build_ci_token,
    google_service_account_iam_member.cloudbuild_uses_build,
    google_storage_bucket_iam_member.build_provenance_creator,
  ]
}

# The contract is immutable to both build identities. It binds the expected source
# trigger id, identities, repository, environment, signing key, state location, and
# lease settings into one bootstrap-owned object checked before every deployment.
resource "google_storage_bucket_object" "bootstrap_contract" {
  name         = local.contract_object
  bucket       = google_storage_bucket.deploy_control.name
  content_type = "application/json"
  content = jsonencode({
    schema                 = "hop.bootstrap.v2"
    project_id             = var.project_id
    repository             = var.github_repository
    repository_id          = var.github_repository_id
    actions_app_id         = var.github_actions_app_id
    ci_workflow_sha256     = var.github_ci_workflow_sha256
    source_trigger_id      = google_cloudbuild_trigger.source.trigger_id
    source_trigger_name    = local.source_trigger_name
    builder_identity       = local.build_identity
    deploy_identity        = local.deploy_identity
    deployment_environment = var.deployment_environment
    kms_key_version        = local.kms_key_version
    provenance_bucket      = google_storage_bucket.deploy_control.name
    lease_object           = local.lease_object
    lease_ttl_seconds      = var.lease_ttl_seconds
    runtime_state_bucket   = var.runtime_state_bucket
    runtime_state_prefix   = var.runtime_state_prefix
    image_repositories = {
      relay   = local.relay_image_repository
      example = local.example_image_repository
    }
  })

  lifecycle {
    prevent_destroy = true
  }
}

# Pub/Sub is only a wake-up signal. The payload is untrusted. The inline deploy
# definition re-authenticates the source build, GitHub verdict, signed manifest,
# current main SHA, and global lease before extracting or applying candidate code.
resource "google_cloudbuild_trigger" "deploy" {
  name        = local.deploy_trigger_name
  description = "Trusted digest-only runtime deployment"
  location    = var.region

  pubsub_config {
    topic = google_pubsub_topic.deploy_requests.id
  }

  substitutions = {
    _SOURCE_BUILD_ID = "$(body.message.data.build_id)"
    _SOURCE_SHA      = "$(body.message.data.source_sha)"
  }
  filter = "_SOURCE_BUILD_ID.matches('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') && _SOURCE_SHA.matches('^[0-9a-f]{40}$')"

  service_account = google_service_account.deploy.id

  approval_config {
    approval_required = true
  }

  build {
    step {
      name     = local.gcloud_builder_image
      id       = "authority-preflight"
      wait_for = ["-"]
      script   = local.provenance_script
      env = [
        "TRUSTED_PROVENANCE_MODE=authority-preflight",
        "BUILD_PROJECT_ID=${var.project_id}",
        "AUTHORITY_PROFILE=deploy",
        "EXPECTED_IDENTITY=${local.deploy_identity}",
        "BUILD_CONNECTION_RESOURCE=${google_cloudbuildv2_repository.hop.parent_connection}",
        "BUILD_REPOSITORY_RESOURCE=${google_cloudbuildv2_repository.hop.id}",
      ]
    }

    step {
      name       = local.gcloud_builder_image
      id         = "require-ci"
      wait_for   = ["authority-preflight"]
      script     = local.ci_gate_script
      secret_env = ["GH_TOKEN"]
      env = [
        "TRUSTED_GATE_MODE=gate",
        "EXPECTED_WORKFLOWS_B64=${local.expected_gate_b64}",
        "SOURCE_SHA=$${_SOURCE_SHA}",
        "GATE_DEADLINE_SECONDS=1500",
        "GATE_POLL_SECONDS=20",
      ]
    }

    step {
      name       = local.gcloud_builder_image
      id         = "verify-provenance"
      wait_for   = ["require-ci"]
      script     = local.provenance_script
      secret_env = ["GH_TOKEN"]
      env = [
        "TRUSTED_PROVENANCE_MODE=deploy-verify",
        "SOURCE_SHA=$${_SOURCE_SHA}",
        "SOURCE_BUILD_ID=$${_SOURCE_BUILD_ID}",
        "DEPLOY_BUILD_ID=$BUILD_ID",
        "BUILD_PROJECT_ID=${var.project_id}",
        "BUILD_LOCATION=${var.region}",
        "PROVENANCE_BUCKET=${google_storage_bucket.deploy_control.name}",
        "BOOTSTRAP_CONTRACT_OBJECT=${local.contract_object}",
        "DEPLOY_IDENTITY=${local.deploy_identity}",
        "DEPLOYMENT_ENVIRONMENT=${var.deployment_environment}",
        "RUNTIME_DESTINATION=/workspace/runtime",
        "DEPLOY_CONTEXT_FILE=/workspace/deploy-context.json",
        "DEPLOY_BACKEND_CONFIG_FILE=/workspace/runtime-backend.tfbackend",
      ]
    }

    step {
      name     = local.tofu_builder_image
      id       = "init-runtime"
      wait_for = ["verify-provenance"]
      script   = <<-EOT
        #!/bin/sh
        set -eu
        cd /workspace/runtime
        tofu init -input=false -backend-config=/workspace/runtime-backend.tfbackend
      EOT
    }

    step {
      name     = local.gcloud_builder_image
      id       = "acquire-deploy-lease"
      wait_for = ["init-runtime"]
      script   = local.provenance_script
      env = [
        "TRUSTED_PROVENANCE_MODE=lease-acquire",
        "DEPLOY_CONTEXT_FILE=/workspace/deploy-context.json",
        "LEASE_FILE=/workspace/deploy-lease.json",
        "LEASE_WAIT_SECONDS=1800",
      ]
    }

    step {
      name       = local.gcloud_builder_image
      id         = "main-after-lease"
      wait_for   = ["acquire-deploy-lease"]
      script     = local.ci_gate_script
      secret_env = ["GH_TOKEN"]
      env = [
        "TRUSTED_GATE_MODE=canonical",
        "EXPECTED_WORKFLOWS_B64=${local.expected_gate_b64}",
        "SOURCE_SHA=$${_SOURCE_SHA}",
        "GATE_RESULT_FILE=/workspace/main-after-lease.rc",
      ]
    }

    step {
      name     = local.gcloud_builder_image
      id       = "assert-lease-after-main"
      wait_for = ["main-after-lease"]
      script   = local.provenance_script
      env = [
        "TRUSTED_PROVENANCE_MODE=lease-assert",
        "DEPLOY_CONTEXT_FILE=/workspace/deploy-context.json",
        "LEASE_FILE=/workspace/deploy-lease.json",
        "GATE_RESULT_FILE=/workspace/main-after-lease.rc",
      ]
    }

    step {
      name       = local.gcloud_builder_image
      id         = "main-before-apply"
      wait_for   = ["assert-lease-after-main"]
      script     = local.ci_gate_script
      secret_env = ["GH_TOKEN"]
      env = [
        "TRUSTED_GATE_MODE=canonical",
        "EXPECTED_WORKFLOWS_B64=${local.expected_gate_b64}",
        "SOURCE_SHA=$${_SOURCE_SHA}",
        "GATE_RESULT_FILE=/workspace/main-before-apply.rc",
      ]
    }

    step {
      name     = local.gcloud_builder_image
      id       = "renew-deploy-lease"
      wait_for = ["main-before-apply"]
      script   = local.provenance_script
      env = [
        "TRUSTED_PROVENANCE_MODE=lease-assert",
        "DEPLOY_CONTEXT_FILE=/workspace/deploy-context.json",
        "LEASE_FILE=/workspace/deploy-lease.json",
        "GATE_RESULT_FILE=/workspace/main-before-apply.rc",
      ]
    }

    step {
      name          = local.tofu_builder_image
      id            = "apply-runtime"
      wait_for      = ["renew-deploy-lease"]
      allow_failure = true
      env = [
        "TF_VAR_project_id=${var.project_id}",
        "TF_VAR_cloud_run_ingress=${var.cloud_run_ingress}",
        "TF_VAR_max_instances_per_region=${var.max_instances_per_region}",
        "TF_VAR_region_allowlist=${jsonencode(var.region_allowlist)}",
        "TF_VAR_relays_enabled=${var.relays_enabled}",
        "TF_VAR_relay_identity_version=${var.relay_identity_version}",
        "TF_VAR_example_identity_version=${var.example_identity_version}",
      ]
      script = <<-EOT
        #!/bin/sh
        set +e
        cd /workspace/runtime || exit 97
        tofu apply -input=false -auto-approve
        rc=$$?
        printf '%s\n' "$$rc" > /workspace/apply.rc
        exit "$$rc"
      EOT
    }

    step {
      name     = local.gcloud_builder_image
      id       = "release-deploy-lease"
      wait_for = ["apply-runtime"]
      script   = local.provenance_script
      env = [
        "TRUSTED_PROVENANCE_MODE=lease-release",
        "DEPLOY_CONTEXT_FILE=/workspace/deploy-context.json",
        "LEASE_FILE=/workspace/deploy-lease.json",
      ]
    }

    step {
      name     = local.gcloud_builder_image
      id       = "deployment-result"
      wait_for = ["release-deploy-lease"]
      env = [
        "RELAYS_ENABLED=${var.relays_enabled}",
        "RELAY_DOMAIN=${var.relay_domain}",
      ]
      script = <<-EOT
        #!/usr/bin/env bash
        set -euo pipefail
        apply_rc="$$(cat /workspace/apply.rc 2>/dev/null || printf '98')"
        if [ "$$apply_rc" != "0" ]; then
          echo "runtime apply failed with rc=$$apply_rc" >&2
          exit "$$apply_rc"
        fi
        if [ "$$RELAYS_ENABLED" != "true" ]; then
          echo "relays disabled; runtime apply succeeded and smoke test is not applicable"
          exit 0
        fi
        url="https://$$RELAY_DOMAIN/healthz"
        deadline=$$(( $$(date +%s) + 300 ))
        while :; do
          code=$$(curl -sS -o /tmp/healthz.body -w '%%{http_code}' --max-time 15 "$$url" 2>/dev/null || printf '000')
          body=$$(cat /tmp/healthz.body 2>/dev/null || true)
          if [ "$$code" = "200" ]; then
            echo "relay readiness smoke passed: $$url ($$body)"
            exit 0
          fi
          if [ "$$(date +%s)" -ge "$$deadline" ]; then
            echo "relay readiness smoke failed: $$url returned $$code ($$body)" >&2
            exit 1
          fi
          sleep 10
        done
      EOT
    }

    available_secrets {
      secret_manager {
        version_name = "${google_secret_manager_secret.ci_readtoken.id}/versions/${var.ci_token_secret_version}"
        env          = "GH_TOKEN"
      }
    }

    options {
      machine_type          = "E2_HIGHCPU_8"
      logging               = "CLOUD_LOGGING_ONLY"
      dynamic_substitutions = true
      substitution_option   = "MUST_MATCH"
    }

    timeout = "3600s"
  }

  depends_on = [
    google_artifact_registry_repository_iam_member.deploy_reader,
    google_iam_deny_policy.relay_seed,
    google_kms_crypto_key_iam_member.deploy_public_key,
    google_project_iam_member.deploy,
    google_project_iam_member.deploy_approver,
    google_secret_manager_secret_iam_member.deploy_ci_token,
    google_service_account_iam_member.cloudbuild_uses_deploy,
    google_service_account_iam_member.deploy_uses_example,
    google_service_account_iam_member.deploy_uses_relay,
    google_storage_bucket_iam_member.deploy_lease,
    google_storage_bucket_iam_member.deploy_provenance_viewer,
    google_storage_bucket_iam_member.deploy_state,
    google_storage_bucket_object.bootstrap_contract,
  ]
}
