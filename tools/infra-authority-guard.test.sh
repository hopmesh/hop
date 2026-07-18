#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$root" <<'PY'
import importlib.util
import pathlib
import shutil
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("guard", root / "tools" / "infra-authority-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def copy_fixture(destination):
    (destination / "infra" / "bootstrap").mkdir(parents=True)
    (destination / "tools").mkdir(parents=True)
    for path in (root / "infra").glob("*.tf"):
        shutil.copy2(path, destination / "infra" / path.name)
    for name in ("iam.tf", "triggers.tf"):
        shutil.copy2(root / "infra" / "bootstrap" / name, destination / "infra" / "bootstrap" / name)
    for name in ("require-ci-verdict.py", "deploy-provenance.py"):
        shutil.copy2(root / "tools" / name, destination / "tools" / name)


def expect_bad(label, mutate):
    with tempfile.TemporaryDirectory() as directory:
        fixture = pathlib.Path(directory)
        copy_fixture(fixture)
        mutate(fixture)
        errors = guard.check(fixture)
        if not errors:
            raise AssertionError(f"guard accepted negative fixture: {label}")
        print(f"ok [{label}] rejected: {errors[0]}")


with tempfile.TemporaryDirectory() as directory:
    fixture = pathlib.Path(directory)
    copy_fixture(fixture)
    errors = guard.check(fixture)
    if errors:
        raise AssertionError(f"clean fixture failed: {errors}")
    print("ok [clean_authority_boundary]")


def append_runtime(fixture, text):
    path = fixture / "infra" / "evil.tf"
    path.write_text(text, encoding="utf-8")


def replace(fixture, relative, old, new):
    path = fixture / relative
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise AssertionError(f"fixture marker missing: {old}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


expect_bad("runtime_project_iam", lambda f: append_runtime(f, '  resource "google_project_iam_member" "evil" {}\n'))
expect_bad("runtime_secret_iam", lambda f: append_runtime(f, 'resource "google_secret_manager_secret_iam_member" "evil" {}\n'))
expect_bad("runtime_service_account_iam", lambda f: append_runtime(f, 'resource "google_service_account_iam_member" "evil" {}\n'))
expect_bad("runtime_workload_identity_pool", lambda f: append_runtime(f, 'resource "google_iam_workload_identity_pool" "evil" {}\n'))
expect_bad("deploy_editor", lambda f: replace(f, pathlib.Path("infra/bootstrap/iam.tf"), '"roles/run.developer",', '"roles/editor",'))
expect_bad("build_artifact_admin", lambda f: replace(f, pathlib.Path("infra/bootstrap/iam.tf"), '"roles/logging.logWriter",', '"roles/artifactregistry.admin",'))
expect_bad("secret_set_policy", lambda f: replace(f, pathlib.Path("infra/bootstrap/iam.tf"), '"secretmanager.secrets.update",', '"secretmanager.secrets.setIamPolicy",'))
expect_bad("relay_seed_to_builder", lambda f: replace(
    f,
    pathlib.Path("infra/bootstrap/iam.tf"),
    'secret_id = google_secret_manager_secret.relay_identity.secret_id\n  role      = "roles/secretmanager.secretAccessor"\n  member    = "serviceAccount:${google_service_account.relay.email}"',
    'secret_id = google_secret_manager_secret.relay_identity.secret_id\n  role      = "roles/secretmanager.secretAccessor"\n  member    = "serviceAccount:${google_service_account.build.email}"',
))
expect_bad("example_reuses_relay", lambda f: replace(f, pathlib.Path("infra/example.tf"), "service_account = local.example_service_account", "service_account = local.relay_service_account"))
expect_bad("example_identity_version_unpinned", lambda f: replace(f, pathlib.Path("infra/example.tf"), "version = var.example_identity_version", 'version = "latest"'))
expect_bad("revision_loaded_trigger", lambda f: replace(f, pathlib.Path("infra/bootstrap/triggers.tf"), 'service_account = google_service_account.build.id', 'filename = "infra/cloudbuild.trigger.yaml"\n  service_account = google_service_account.build.id'))
expect_bad("short_sha", lambda f: replace(f, pathlib.Path("infra/bootstrap/triggers.tf"), '$COMMIT_SHA', '$SHORT_SHA'))
expect_bad("runtime_backend_retargeted", lambda f: replace(f, pathlib.Path("infra/versions.tf"), 'backend "gcs"', 'backend "local"'))
expect_bad("untrusted_backend_init", lambda f: replace(f, pathlib.Path("infra/bootstrap/triggers.tf"), "tofu init -input=false -backend-config=/workspace/runtime-backend.tfbackend", "tofu init -input=false"))
expect_bad("bootstrap_state_writable", lambda f: replace(f, pathlib.Path("infra/bootstrap/iam.tf"), "objects/${var.runtime_state_prefix}/", "objects/bootstrap/"))
expect_bad("lease_prefix_writable", lambda f: replace(f, pathlib.Path("infra/bootstrap/iam.tf"), "objects/${local.lease_object}'", "objects/leases/'"))
expect_bad("provider_retargeted", lambda f: replace(f, pathlib.Path("infra/versions.tf"), "hashicorp/google", "attacker/google"))
expect_bad("provider_custom_endpoint", lambda f: replace(f, pathlib.Path("infra/providers.tf"), "project = var.project_id", 'project = var.project_id\n  storage_custom_endpoint = "https://attacker.example"'))
expect_bad("backend_custom_endpoint", lambda f: replace(f, pathlib.Path("infra/versions.tf"), 'prefix = "relay-fleet"', 'prefix = "relay-fleet"\n    storage_custom_endpoint = "https://attacker.example"'))
expect_bad("unsigned_runtime_image", lambda f: replace(f, pathlib.Path("infra/cloud_run.tf"), "image = var.relay_image", 'image = "us-central1-docker.pkg.dev/attacker/repo/image@sha256:' + "9" * 64 + '"'))
expect_bad("extra_cloud_run_executable", lambda f: append_runtime(f, 'resource "google_cloud_run_v2_job" "evil" {}\n'))
expect_bad("tofu_precedence_bypass", lambda f: (f / "infra" / "evil.tofu").write_text('resource "google_project_iam_member" "evil" {}\n', encoding="utf-8"))
expect_bad("override_merge_bypass", lambda f: (f / "infra" / "evil_override.tf").write_text('locals { relay_service_account = "attacker@example.com" }\n', encoding="utf-8"))
expect_bad("identity_local_retargeted", lambda f: replace(f, pathlib.Path("infra/data.tf"), 'hop-relay@${var.project_id}.iam.gserviceaccount.com', "attacker@example.com"))
expect_bad("ephemeral_provider_resource", lambda f: append_runtime(f, 'ephemeral "google_service_account_access_token" "evil" {}\n'))
expect_bad("state_encryption_override", lambda f: append_runtime(f, "terraform { encryption {} }\n"))
expect_bad("automatic_variable_override", lambda f: (f / "infra" / "evil.auto.tfvars").write_text("relays_enabled = true\n", encoding="utf-8"))
expect_bad("json_terraform_config", lambda f: (f / "infra" / "evil.tf.json").write_text('{"resource": {}}\n', encoding="utf-8"))
expect_bad("source_comparison_token_removed", lambda f: replace(
    f,
    pathlib.Path("infra/bootstrap/triggers.tf"),
    'id         = "verify-provenance"\n      wait_for   = ["require-ci"]\n      script     = local.provenance_script\n      secret_env = ["GH_TOKEN"]',
    'id         = "verify-provenance"\n      wait_for   = ["require-ci"]\n      script     = local.provenance_script',
))
expect_bad("repository_token_probe_removed", lambda f: replace(f, pathlib.Path("infra/bootstrap/triggers.tf"), "BUILD_REPOSITORY_RESOURCE=", "REMOVED_REPOSITORY_RESOURCE=",))
print("infra authority guard tests passed")
PY
