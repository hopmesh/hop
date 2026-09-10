#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import pathlib
import shutil
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


def omit_accountd_and_manifest(repo):
    remove_resource(repo, "infra/console.tf", "google_cloud_run_v2_service", "accountd")
    replace(repo, "infra/runtime-resource-manifest.txt", "google_cloud_run_v2_service.accountd\n", "")
expect("resource and manifest joint deletion rejected", omit_accountd_and_manifest)

expect("private source label required", lambda r: replace(r, "infra/example.tf", '"hop-private-source-sha" = var.private_source_sha', '"hop-private-source-sha" = "bad"'))
expect("singleton count zero rejected", lambda r: replace(r, "infra/example.tf", 'name     = "hop-example"', 'name     = "hop-example"\n  count    = 0'))
expect("relay cardinality pinned", lambda r: replace(r, "infra/cloud_run.tf", "for_each = local.regions", "for_each = {}"))
expect("removed address cannot destroy", make_removed_destroy)
expect("billing price version cannot be latest", lambda r: replace(r, "infra/console.tf", "version = var.billing_price_ids_version", 'version = "latest"'))
expect("billing price secret id pinned", lambda r: replace(r, "infra/console.tf", 'secret  = "hop-billing-price-ids"', 'secret  = "stripe-webhook-secret"'))
expect("runtime data source omission rejected", lambda r: remove_data(r, "infra/console.tf", "google_secret_manager_secret_version", "billing_price_ids"))
expect("provider condition hop only", lambda r: replace(r, "infra/bootstrap/billing.tf", 'attribute_condition = "assertion.repository == \\"hopmesh/hop\\""', 'attribute_condition = "assertion.repository == \\"hopmesh/platform\\""\n  # attribute_condition = "assertion.repository == \\"hopmesh/hop\\""'))
expect("shared WIF member main ref", lambda r: replace(r, "infra/bootstrap/ci_apply.tf", "attribute.ref/refs/heads/main", "attribute.repository/hopmesh/hop"))
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


def restore_billing_state_reader(repo):
    append(repo, "infra/bootstrap/console.tf", '''
resource "google_storage_bucket_iam_member" "deploy_billing_state_reader" {
  bucket = var.runtime_state_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.deploy.email}"
}
''')
expect("hop-deploy cannot read private billing state", restore_billing_state_reader)
expect("billing state prefix cannot widen", lambda r: replace(r, "infra/bootstrap/billing.tf", "/objects/billing/", "/objects/"))
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

print(f"infra authority guard tests passed: {passed}")
PY
