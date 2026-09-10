#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("guard", root / "tools/infra-authority-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
passed = 0


def fixture(base):
    target = base / "repo"
    shutil.copytree(root / "infra", target / "infra", ignore=shutil.ignore_patterns(".terraform"))
    (target / "tools").mkdir(parents=True)
    for name in ("private-source-pin.py", "private-source-pin.test.sh"):
        shutil.copy2(root / "tools" / name, target / "tools" / name)
    return target


def expect(label, mutate=None):
    global passed
    with tempfile.TemporaryDirectory() as directory:
        repo = fixture(pathlib.Path(directory))
        if mutate:
            mutate(repo)
        errors = guard.check(repo)
        if mutate is None:
            if errors:
                raise AssertionError(f"clean fixture failed: {errors}")
        elif not errors:
            raise AssertionError(f"guard accepted hostile case: {label}")
        passed += 1
        print(f"ok   [{label}]")


def replace(repo, relative, old, new):
    path = repo / relative
    text = path.read_text()
    if text.count(old) != 1:
        raise AssertionError(f"{relative}: expected one occurrence of {old!r}, got {text.count(old)}")
    path.write_text(text.replace(old, new))

def replace_first(repo, relative, old, new):
    path = repo / relative
    text = path.read_text()
    if old not in text:
        raise AssertionError(f"{relative}: occurrence not found: {old!r}")
    path.write_text(text.replace(old, new, 1))


def append(repo, relative, text):
    path = repo / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(text)


def make_removed_destroy(repo):
    path = repo / "infra/removed_adminplane.tf"
    text = path.read_text()
    block = guard.repeated_blocks(text, "removed")[0]
    bad = block.replace("destroy = false", "destroy = true", 1)
    if bad == block:
        raise AssertionError("removed lifecycle not found")
    path.write_text(text.replace(block, bad, 1))

def remove_resource(repo, relative, kind, name):
    path = repo / relative
    text = path.read_text()
    block = guard.resource_block(text, kind, name)
    if not block:
        raise AssertionError(f"resource not found: {kind}.{name}")
    path.write_text(text.replace(block, "", 1))



def remove_data(repo, relative, kind, name):
    path = repo / relative
    text = path.read_text()
    block = guard.balanced_block(text, f'data "{kind}" "{name}"')
    if not block:
        raise AssertionError(f"data source not found: {kind}.{name}")
    path.write_text(text.replace(block, "", 1))

def make_price_secret_destroyable(repo):
    path = repo / "infra/bootstrap/billing.tf"
    text = path.read_text()
    block = guard.resource_block(text, "google_secret_manager_secret", "billing_price_ids")
    if not block:
        raise AssertionError("billing price id secret not found")
    bad = block.replace("prevent_destroy = true", "prevent_destroy = false", 1)
    if bad == block:
        raise AssertionError("price secret lifecycle not found")
    path.write_text(text.replace(block, bad, 1))
expect("clean authority boundary")
expect("runtime backend prefix pinned", lambda r: replace(r, "infra/versions.tf", 'prefix = "relay-fleet"', 'prefix = "other"'))
expect("bootstrap backend prefix pinned", lambda r: replace(r, "infra/bootstrap/versions.tf", 'prefix = "bootstrap"', 'prefix = "other"'))
expect("bootstrap backend rejects extra credential", lambda r: replace(r, "infra/bootstrap/versions.tf", 'prefix = "bootstrap"', 'prefix = "bootstrap"\n    credentials = "bad"'))
expect("accountd omission rejected", lambda r: remove_resource(r, "infra/console.tf", "google_cloud_run_v2_service", "accountd"))


def rename_resource_and_manifest(repo):
    replace(repo, "infra/mail_dns.tf", 'resource "google_dns_record_set" "dkim"', 'resource "google_dns_record_set" "dkim_renamed"')
    replace(repo, "infra/runtime-resource-manifest.txt", "google_dns_record_set.dkim\n", "google_dns_record_set.dkim_renamed\n")
expect("joint resource and manifest rename rejected by pinned digest", rename_resource_and_manifest)

def rename_removed_and_manifest(repo):
    replace(repo, "infra/removed_adminplane.tf", "from = google_cloudbuild_trigger.image", "from = google_cloudbuild_trigger.renamed")
    replace(repo, "infra/runtime-removed-manifest.txt", "google_cloudbuild_trigger.image\n", "google_cloudbuild_trigger.renamed\n")
expect("joint removed address and manifest rename rejected by pinned digest", rename_removed_and_manifest)

expect("private source label required", lambda r: replace(r, "infra/example.tf", '"hop-private-source-sha" = var.private_source_sha', '"hop-private-source-sha" = "bad"'))

def comment_spoof_deploy_roles(repo):
    import re
    path = repo / "infra/bootstrap/iam.tf"
    text = path.read_text()
    match = re.search(r"^\s*deploy_project_roles\s*=\s*toset\(\[(.*?)\]\)", text, re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError("deploy role set not found")
    safe = match.group(0)
    commented = "\n".join("# " + line for line in safe.splitlines())
    bad = safe.replace('"roles/bigquery.dataEditor"', '"roles/owner"', 1)
    path.write_text(text.replace(safe, commented + "\n" + bad, 1))
expect("commented safe roles cannot hide active owner grant", comment_spoof_deploy_roles)
expect("singleton count zero rejected", lambda r: replace(r, "infra/example.tf", 'name     = "hop-example"', 'name     = "hop-example"\n  count    = 0'))
expect("provider condition must use closed phase map", lambda r: replace(r, "infra/bootstrap/billing.tf", "attribute_condition = local.github_repository_conditions[var.github_authority_phase]", 'attribute_condition = "assertion.repository == \\"hopmesh/hop\\""'))
def provider_wildcard(repo):
    replace(repo, "infra/bootstrap/billing.tf", 'hop     = "assertion.repository == \\\"${local.github_hop_repository}\\\""', 'hop     = "assertion.repository.startsWith(\\\"hopmesh/\\\")"')
expect("provider wildcard rejected", provider_wildcard)
expect("removed address cannot destroy", make_removed_destroy)
expect("billing price version cannot be latest", lambda r: replace(r, "infra/console.tf", "version = var.billing_price_ids_version", 'version = "latest"'))
expect("billing price secret id pinned", lambda r: replace(r, "infra/console.tf", 'secret  = "hop-billing-price-ids"', 'secret  = "other-secret"'))
expect("runtime data source omission rejected", lambda r: remove_data(r, "infra/console.tf", "google_secret_manager_secret_version", "billing_price_ids"))
expect("hop phase cannot admit platform", lambda r: replace(r, "infra/bootstrap/billing.tf", 'hop     = "assertion.repository == \\\"${local.github_hop_repository}\\\""', 'hop     = "assertion.repository == \\\"${local.github_platform_repository}\\\""'))
expect("runtime WIF member names exact workflow", lambda r: replace(r, "infra/bootstrap/billing.tf", 'runtime   = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_hop_repository}/.github/workflows/runtime-deploy.yml@refs/heads/main"', 'runtime   = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.workflow/${local.github_hop_repository}/.github/workflows/other.yml@refs/heads/main"'))
expect("github repository fixed", lambda r: replace(r, "infra/bootstrap/variables.tf", 'default     = "hopmesh/hop"', 'default     = "hopmesh/platform"'))
expect("runtime state bucket fixed", lambda r: replace(r, "infra/bootstrap/variables.tf", 'default     = "hop-mesh-tfstate"', 'default     = "other-bucket"'))


def retarget_accessor_with_comment(repo):
    replace(repo, "infra/bootstrap/billing.tf", "secret_id = google_secret_manager_secret.billing_price_ids.secret_id\n  role      = \"roles/secretmanager.secretAccessor\"", "# secret_id = google_secret_manager_secret.billing_price_ids.secret_id\n  secret_id = google_secret_manager_secret.stripe_webhook_secret.secret_id\n  role      = \"roles/secretmanager.secretAccessor\"")
expect("price accessor comment spoof rejected", retarget_accessor_with_comment)

expect("price secret container pinned", lambda r: replace(r, "infra/bootstrap/billing.tf", 'secret_id = "hop-billing-price-ids"', 'secret_id = "other"'))
expect("price secret cannot be destroyed", make_price_secret_destroyable)
expect("price writer role cannot broaden", lambda r: replace(r, "infra/bootstrap/billing.tf", 'role      = "roles/secretmanager.secretVersionAdder"', 'role      = "roles/secretmanager.secretVersionManager"'))


def extra_deploy_secret(repo):
    append(repo, "infra/bootstrap/billing.tf", '''
resource "google_secret_manager_secret_iam_member" "extra_deploy_secret" {
  secret_id = google_secret_manager_secret.stripe_webhook_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.deploy.email}"
}
''')
expect("no additional hop-deploy secret grant", extra_deploy_secret)


def extra_price_writer(repo):
    append(repo, "infra/bootstrap/billing.tf", '''
resource "google_secret_manager_secret_iam_member" "extra_price_writer" {
  secret_id = google_secret_manager_secret.stripe_webhook_secret.secret_id
  role      = "roles/secretmanager.secretVersionAdder"
  member    = "serviceAccount:${google_service_account.billing_catalog_apply.email}"
}
''')
expect("price VersionAdder grant exclusive", extra_price_writer)


expect("terminal hop phase removes private billing state read", lambda r: replace(r, "infra/bootstrap/billing.tf", 'count  = var.github_authority_phase == "handoff" ? 1 : 0', "count  = 1"))

def widen_billing_state(repo):
    path = repo / "infra/bootstrap/billing.tf"
    text = path.read_text()
    block = guard.resource_block(text, "google_storage_bucket_iam_member", "billing_catalog_state")
    bad = block.replace('/objects/billing/', '/objects/')
    path.write_text(text.replace(block, bad, 1))
expect("billing state prefix cannot widen", widen_billing_state)
expect("bootstrap terraform.tfvars rejected", lambda r: (r / "infra/bootstrap/terraform.tfvars").write_text('github_repository = "hopmesh/hop"\n'))
expect("block comment spoof rejected", lambda r: append(r, "infra/bootstrap/billing.tf", "\n/* expected assignment = good */\n"))


def quoted_heredoc_marker(repo):
    replace(repo, "infra/example.tf", "resource \"google_cloud_run_v2_service\" \"example\"", 'locals { marker = "<<EOF" }\nresource "google_cloud_run_v2_service" "renamed"')
expect("quoted heredoc marker cannot hide missing resource", quoted_heredoc_marker)

expect("private accountd source rejected", lambda r: (r / "services/hop-accountd/src").mkdir(parents=True) or (r / "services/hop-accountd/src/main.rs").write_text("private"))
expect("fine-grained GitHub token rejected", lambda r: append(r, "infra/README.md", "github_pat_abcdefghijklmnopqrstuvwxyz123456\n"))
expect("Stripe webhook secret rejected", lambda r: append(r, "infra/README.md", "whsec_abcdefghijklmnopqrstuvwxyz\n"))
expect("private pricing literal rejected", lambda r: append(r, "infra/README.md", "base_fee_cents = 200\n"))
expect("currency literal rejected", lambda r: append(r, "infra/README.md", "price is $2.00\n"))


def infra_symlink(repo):
    target = repo / "infra/linked-secret.tf"
    target.symlink_to("/etc/hosts")
expect("public infra symlink rejected", infra_symlink)


def infra_binary(repo):
    (repo / "infra/binary.tf").write_bytes(b"\xff\xfe")
expect("public infra binary rejected", infra_binary)


def bootstrap_removed_destroy(repo):
    path = repo / "infra/bootstrap/iam.tf"
    text = path.read_text()
    block = guard.repeated_blocks(text, "removed")[0]
    bad = block.replace("destroy = false", "destroy = true", 1)
    path.write_text(text.replace(block, bad, 1))
expect("bootstrap removed address cannot destroy", bootstrap_removed_destroy)

def secret_iam_binding(repo):
    append(repo, "infra/bootstrap/billing.tf", '''
resource "google_secret_manager_secret_iam_binding" "evil_price_manager" {
  secret_id = google_secret_manager_secret.billing_price_ids.secret_id
  role      = "roles/secretmanager.secretVersionManager"
  members   = ["serviceAccount:${google_service_account.deploy.email}"]
}
''')
expect("authoritative secret IAM binding rejected", secret_iam_binding)

def extra_wif_binding(repo):
    append(repo, "infra/bootstrap/billing.tf", '''
resource "google_service_account_iam_member" "evil_pr_wif" {
  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.ref/refs/pull/8/merge"
}
''')
expect("additional WIF binding rejected", extra_wif_binding)

expect("custom WIF JWKS rejected", lambda r: replace(r, "infra/bootstrap/billing.tf", 'display_name                       = "GitHub OIDC"', 'display_name                       = "GitHub OIDC"\n  jwks_json = "{}"'))
expect("custom WIF audience rejected", lambda r: replace(r, "infra/bootstrap/billing.tf", 'display_name                       = "GitHub OIDC"', 'display_name                       = "GitHub OIDC"\n  allowed_audiences = ["evil"]'))
expect("disabled WIF provider rejected", lambda r: replace(r, "infra/bootstrap/billing.tf", 'display_name                       = "GitHub OIDC"', 'display_name                       = "GitHub OIDC"\n  disabled = true'))
expect("non-GitHub issuer rejected", lambda r: replace(r, "infra/bootstrap/billing.tf", 'issuer_uri        = "https://token.actions.githubusercontent.com"', 'issuer_uri        = "https://attacker.example"'))
expect("WIF attribute mapping pinned", lambda r: replace(r, "infra/bootstrap/billing.tf", '"attribute.ref"        = "assertion.ref"', '"attribute.ref"        = "assertion.actor"'))

def widen_deploy_state_with_comment(repo):
    path = repo / "infra/bootstrap/iam.tf"
    text = path.read_text()
    block = guard.resource_block(text, "google_storage_bucket_iam_member", "deploy_state")
    bad = block.replace('role   = "roles/storage.objectUser"', 'role   = "roles/storage.admin"')
    old = 'expression  = "resource.name == \'projects/_/buckets/${var.runtime_state_bucket}\' || resource.name.startsWith(\'projects/_/buckets/${var.runtime_state_bucket}/objects/${var.runtime_state_prefix}/\')"'
    bad = bad.replace(old, 'expression  = "resource.name.startsWith(\'projects/_/buckets/${var.runtime_state_bucket}\')"\n  # objects/${var.runtime_state_prefix}/')
    path.write_text(text.replace(block, bad, 1))
expect("deploy state role and prefix comment spoof rejected", widen_deploy_state_with_comment)

def nested_label_spoof(repo):
    path = repo / "infra/example.tf"
    text = path.read_text()
    block = guard.resource_block(text, "google_cloud_run_v2_service", "example")
    labels = guard.top_level_block(block.split("template", 1)[0], "labels =")
    bad = block.replace(labels, "", 1)
    nested = '''ignore_changes = [scaling]
    precondition {
      condition = true
      error_message = jsonencode({ labels = {
        "hop-source-sha" = var.deployment_source_sha
        "hop-private-source-sha" = var.private_source_sha
      } })
    }'''
    bad = bad.replace("ignore_changes = [scaling]", nested, 1)
    path.write_text(text.replace(block, bad, 1))
expect("nested labels cannot spoof service provenance", nested_label_spoof)


def runtime_backend_heredoc_spoof(repo):
    path = repo / "infra/versions.tf"
    text = path.read_text()
    block = guard.balanced_block(text, 'backend "gcs"')
    if not block:
        raise AssertionError("runtime backend not found")
    decoy = "locals {\n  backend_decoy = <<EOF\n" + block + "\nEOF\n}\n"
    path.write_text(text.replace(block, decoy, 1))
    append(repo, "infra/evil-backend.tf", '''
terraform {
  backend "gcs" {
    bucket      = "attacker-bucket"
    prefix      = "attacker-prefix"
    credentials = "attacker"
  }
}
''')
expect("heredoc cannot spoof canonical runtime backend", runtime_backend_heredoc_spoof)

def seed_member_comment_spoof(repo):
    path = repo / "infra/bootstrap/iam.tf"
    text = path.read_text()
    safe = '  member    = "serviceAccount:${google_service_account.relay.email}"'
    bad = f'# {safe}\n  member    = "serviceAccount:attacker@example.com"'
    path.write_text(text.replace(safe, bad, 1))
expect("commented relay identity cannot spoof seed accessor", seed_member_comment_spoof)

expect("WIF workflow claim mapping pinned", lambda r: replace(r, "infra/bootstrap/billing.tf", '"attribute.workflow"   = "assertion.workflow_ref"', '"attribute.workflow"   = "assertion.actor"'))

def mutate_block(repo, relative, kind, name, old, new):
    path = repo / relative
    text = path.read_text()
    block = guard.resource_block(text, kind, name)
    bad = block.replace(old, new, 1)
    path.write_text(text.replace(block, bad, 1))

expect("catalog Stripe reader cannot broaden", lambda r: mutate_block(r, "infra/bootstrap/billing.tf", "google_secret_manager_secret_iam_member", "billing_catalog_stripe_api_key_reader", 'role      = "roles/secretmanager.secretAccessor"', 'role      = "roles/secretmanager.admin"'))
expect("drift role excludes BigQuery table data", lambda r: mutate_block(r, "infra/bootstrap/ci_apply.tf", "google_project_iam_custom_role", "infra_drift", '"bigquery.tables.get",', '"bigquery.tables.get",\n    "bigquery.tables.getData",'))
expect("platform rollback WIF remains phase-bound", lambda r: mutate_block(r, "infra/bootstrap/runtime_deploy.tf", "google_service_account_iam_member", "deploy_runtime_wif_platform_rollback", 'count              = var.github_authority_phase == "handoff" ? 1 : 0', "count              = 1"))
expect("runtime WIF replacement creates before destroy", lambda r: mutate_block(r, "infra/bootstrap/runtime_deploy.tf", "google_service_account_iam_member", "deploy_runtime_wif", "create_before_destroy = true", "create_before_destroy = false"))
expect("runtime WIF waits for workflow mapping", lambda r: mutate_block(r, "infra/bootstrap/runtime_deploy.tf", "google_service_account_iam_member", "deploy_runtime_wif", "depends_on = [google_iam_workload_identity_pool_provider.github]", "depends_on = []"))
expect("planned legacy IAM cleanup script pinned", lambda r: append(r, "infra/bootstrap/remove_legacy_state_bindings.py", "\n# hostile drift\n"))
expect("planned legacy IAM cleanup command pinned", lambda r: mutate_block(r, "infra/bootstrap/ci_apply.tf", "terraform_data", "remove_legacy_iam_bindings", 'command = "python3 ${path.module}/remove_legacy_state_bindings.py"', 'command = "true"'))
expect("rollback billing reader cannot widen", lambda r: mutate_block(r, "infra/bootstrap/billing.tf", "google_storage_bucket_iam_member", "deploy_billing_state_reader", '/objects/billing/', '/objects/'))
expect("price ids must match private source", lambda r: replace(r, "infra/console.tf", "local.billing_prices.private_source_sha == var.private_source_sha", "true"))
expect("drift inputs include private source provenance", lambda r: replace(r, "infra/outputs.tf", "private_source_sha        = var.private_source_sha", "other_source_sha          = var.private_source_sha"))


# Exercise the pinned terraform_data cleanup without touching live IAM.
cleanup_spec = importlib.util.spec_from_file_location("legacy_cleanup", root / "infra/bootstrap/remove_legacy_state_bindings.py")
legacy_cleanup = importlib.util.module_from_spec(cleanup_spec)
cleanup_spec.loader.exec_module(legacy_cleanup)
bootstrap_expression = f'resource.name == "projects/_/buckets/{legacy_cleanup.BUCKET}" || resource.name.startsWith("projects/_/buckets/{legacy_cleanup.BUCKET}/objects/bootstrap/")'
billing_expression = f'resource.name == "projects/_/buckets/{legacy_cleanup.BUCKET}" || resource.name.startsWith("projects/_/buckets/{legacy_cleanup.BUCKET}/objects/billing/")'
initial_bucket = {"bindings": [
    {"role": legacy_cleanup.STORAGE_ROLE, "members": [f"serviceAccount:{legacy_cleanup.BOOTSTRAP_SA}"], "condition": {"title": "bootstrap-state-prefix-only", "expression": bootstrap_expression}},
    {"role": legacy_cleanup.STORAGE_ROLE, "members": [f"serviceAccount:{legacy_cleanup.BILLING_SA}"], "condition": {"title": "billing-state-prefix-only", "expression": billing_expression}},
]}
initial_project = {"bindings": [
    {"role": legacy_cleanup.SECRET_ADMIN_ROLE, "members": [legacy_cleanup.CLOUDBUILD_MEMBER]},
]}
calls = []
bucket_reads = 0
project_reads = 0

def fake_cleanup_run(*args):
    global bucket_reads, project_reads
    calls.append(args)
    if args[:4] == ("gcloud", "storage", "buckets", "get-iam-policy"):
        value = initial_bucket if bucket_reads == 0 else {"bindings": []}
        bucket_reads += 1
        return subprocess.CompletedProcess(args, 0, json.dumps(value), "")
    if args[:3] == ("gcloud", "projects", "get-iam-policy"):
        value = initial_project if project_reads == 0 else {"bindings": []}
        project_reads += 1
        return subprocess.CompletedProcess(args, 0, json.dumps(value), "")
    return subprocess.CompletedProcess(args, 0, "", "")

original_cleanup_run = legacy_cleanup.run
original_environment = os.environ.copy()
try:
    legacy_cleanup.run = fake_cleanup_run
    os.environ.update({
        "PROJECT_ID": legacy_cleanup.PROJECT,
        "STATE_BUCKET": legacy_cleanup.BUCKET,
        "BOOTSTRAP_SERVICE_ACCOUNT": legacy_cleanup.BOOTSTRAP_SA,
        "BILLING_SERVICE_ACCOUNT": legacy_cleanup.BILLING_SA,
    })
    legacy_cleanup.main()
finally:
    legacy_cleanup.run = original_cleanup_run
    os.environ.clear()
    os.environ.update(original_environment)
removals = [call for call in calls if "remove-iam-policy-binding" in call]
assert len(removals) == 3, removals
assert sum("--condition" in call for call in removals) == 2, removals
assert sum(call[:3] == ("gcloud", "projects", "remove-iam-policy-binding") for call in removals) == 1, removals
passed += 1
print("ok   [planned legacy IAM cleanup removes exact three bindings]")
print(f"infra authority guard tests passed: {passed}")
PY
