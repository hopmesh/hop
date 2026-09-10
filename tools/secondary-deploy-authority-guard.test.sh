#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import json
import pathlib
import re
import subprocess
import tempfile
import sys

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("guard", root / "tools/secondary-deploy-authority-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
sources = {name: (root / ".github/workflows" / name).read_text() for name in ("billing-catalog.yml", "infra-drift.yml", "bootstrap-apply.yml")}
passed = 0


def expect(label, file=None, old=None, new=None, first=False):
    global passed
    with tempfile.TemporaryDirectory() as directory:
        repo = pathlib.Path(directory)
        workflows = repo / ".github/workflows"
        workflows.mkdir(parents=True)
        for name, text in sources.items():
            (workflows / name).write_text(text)
        if file:
            path = workflows / file
            text = path.read_text()
            count = text.count(old)
            if count < 1 or (not first and count != 1):
                raise AssertionError(f"{label}: mutation target count {count}")
            path.write_text(text.replace(old, new, 1))
        errors = guard.check(repo)
        if file is None:
            if errors:
                raise AssertionError(f"clean workflows failed: {errors}")
        elif not errors:
            raise AssertionError(f"guard accepted hostile case: {label}")
        passed += 1
        print(f"ok   [{label}]")


expect("clean secondary workflows")
expect("billing cannot run on schedule", "billing-catalog.yml", "  workflow_dispatch:", "  schedule:\n    - cron: '* * * * *'\n  workflow_dispatch:")
expect("billing cannot read Stripe GitHub secret", "billing-catalog.yml", "token: ${{ steps.private-source-token.outputs.token }}", "token: ${{ secrets.STRIPE_API_KEY }}")
expect("billing PR validation cannot read a secret", "billing-catalog.yml", "name: Billing deployment authority validation", "name: Billing deployment authority validation\n    env:\n      TOKEN: ${{ secrets.HOP_SYNC_APP_PRIVATE_KEY }}")
expect("billing checkout cannot use main", "billing-catalog.yml", "ref: ${{ steps.pin.outputs.commit }}", "ref: main")
expect("billing token must stay read-only", "billing-catalog.yml", "permission-contents: read", "permission-contents: write")
expect("billing apply must use saved plan", "billing-catalog.yml", "tofu apply -input=false -auto-approve -no-color tfplan", "tofu apply -input=false -auto-approve -no-color")
expect("price publication must follow apply", "billing-catalog.yml", "if: steps.apply.outputs.applied == 'true'", "if: always()")
expect("published prices require private source SHA", "billing-catalog.yml", 'payload["private_source_sha"] = sys.argv[3]', 'payload["other"] = sys.argv[3]')
expect("billing cannot tolerate failure", "billing-catalog.yml", "name: Apply the saved private billing plan", "name: Apply the saved private billing plan\n        continue-on-error: true")
expect("billing requires component-sync environment", "billing-catalog.yml", "environment: component-sync", "environment: release")
expect("billing apply refuses superseded main", "billing-catalog.yml", "test \"$tip\" = \"$EXPECTED_SHA\"", "test \"$tip\" != \"\"")
expect("billing plan output remains withheld", "billing-catalog.yml", 'billing-plan.log" 2>&1', 'billing-plan.log"')

expect("drift cannot use bootstrap authority", "infra-drift.yml", "DRIFT_SERVICE_ACCOUNT: ${{ vars.GCP_DRIFT_SERVICE_ACCOUNT }}", "BOOTSTRAP_SERVICE_ACCOUNT: ${{ vars.GCP_BOOTSTRAP_SERVICE_ACCOUNT }}")
expect("drift cannot apply", "infra-drift.yml", "tofu plan -input=false", "tofu apply -input=false")
expect("drift cannot run on PR", "infra-drift.yml", "github.event_name != 'pull_request'", "github.event_name == 'pull_request'")
expect("drift cannot use self-hosted", "infra-drift.yml", "runs-on: ubuntu-latest", "runs-on: [self-hosted, macOS]", first=True)
expect("drift must keep detailed exit code", "infra-drift.yml", "-detailed-exitcode -lock=false", "-lock=false")
expect("drift requires release environment", "infra-drift.yml", "environment: release", "environment: component-sync")
expect("drift cannot invoke gcloud mutations", "infra-drift.yml", 'echo "runtime infrastructure matches applied configuration"', 'gcloud projects add-iam-policy-binding "$PROJECT_ID"')
expect("drift restores applied inputs", "infra-drift.yml", "tofu output -json drift_inputs", "tofu output -json other")
expect("drift failure output remains withheld", "infra-drift.yml", "detailed output withheld", 'cat "$RUNNER_TEMP/runtime-drift.log"')

expect("bootstrap cannot use opaque tfvars", "bootstrap-apply.yml", "Materialize reviewed non-secret bootstrap inputs", "Materialize BOOTSTRAP_TFVARS inputs")
expect("bootstrap cannot target another repository", "bootstrap-apply.yml", "github_repository        = \"hopmesh/hop\"", "github_repository        = \"hopmesh/legacy\"")
expect("bootstrap checkout pins dispatch SHA", "bootstrap-apply.yml", "ref: ${{ github.sha }}", "ref: main")
expect("bootstrap apply must use saved plan", "bootstrap-apply.yml", "tofu apply -input=false -auto-approve -no-color tfplan", "tofu apply -input=false -auto-approve -no-color")
expect("bootstrap rollback phrase fixed", "bootstrap-apply.yml", "inputs.confirm == 'rollback hop authority to platform'", "inputs.confirm == 'rollback anywhere'")
expect("bootstrap ancestor review phrase fixed", "bootstrap-apply.yml", "inputs.ancestor_review == 'owner verified no inherited non-owner auth or secret grants'", "inputs.ancestor_review != ''")
expect("bootstrap plan rejects prior addresses", "bootstrap-apply.yml", 'previous = item.get("previous_address")', 'previous = None')
expect("bootstrap rollback actions phase-specific", "bootstrap-apply.yml", 'if operation == "rollback":\n                  if address == "google_iam_workload_identity_pool_provider.github"', 'if operation in {"rollback", "apply"}:\n                  if address == "google_iam_workload_identity_pool_provider.github"')
expect("bootstrap replacement address set exact", "bootstrap-apply.yml", "normal_replacements = {", 'normal_replacements = {\n              "google_service_account.infra_drift",')
expect("bootstrap removed state accepts exact forget only", "bootstrap-apply.yml", 'address == "google_service_account.build"', 'address.startswith("google_service_account.")')
expect("bootstrap proof checks complete service account policies", "bootstrap-apply.yml", 'raise SystemExit(f"{label} complete service-account IAM policy drifted")', "pass")
expect("bootstrap proof checks workflow mapping", "bootstrap-apply.yml", '"attribute.workflow": "assertion.workflow_ref"', '"attribute.workflow": "assertion.actor"')
expect("bootstrap proof checks IAM conditions", "bootstrap-apply.yml", 'binding.get("condition") not in (None, {})', "False", first=True)
expect("bootstrap proof checks rollback storage", "bootstrap-apply.yml", "gcloud storage buckets get-iam-policy", "echo skip storage readback")
expect("bootstrap proof checks project IAM", "bootstrap-apply.yml", "gcloud projects get-iam-policy", "echo skip project IAM")
expect("bootstrap proof checks secret IAM", "bootstrap-apply.yml", "gcloud secrets get-iam-policy", "echo skip secret IAM")
expect("bootstrap apply refuses superseded main", "bootstrap-apply.yml", "test \"$tip\" = \"$EXPECTED_SHA\"", "test \"$tip\" != \"\"")
expect("bootstrap cannot use self-hosted", "bootstrap-apply.yml", "runs-on: ubuntu-latest", "runs-on: [self-hosted, macOS]", first=True)
expect("bootstrap requires release environment", "bootstrap-apply.yml", "environment: release", "environment: component-sync")

# Execute the embedded phase gate against the observed terminal plan shape and rollback boundaries.
bootstrap_doc = guard.load(root / ".github/workflows/bootstrap-apply.yml")
policy_run = guard.step_by_name(bootstrap_doc["jobs"]["bootstrap"], "Refuse unrelated bootstrap actions")[1]["run"]
match = re.search(r"(?ms)<<'PY'\n(.*?)\n\s*PY", policy_run)
assert match, "bootstrap plan policy heredoc not found"
policy_script = match.group(1)

def phase_plan(label, operation, changes, accepted):
    global passed
    with tempfile.TemporaryDirectory() as directory:
        fixture = pathlib.Path(directory) / "plan.json"
        fixture.write_text(json.dumps({"resource_changes": changes}))
        result = subprocess.run([sys.executable, "-", str(fixture), operation], input=policy_script, text=True, capture_output=True)
        assert (result.returncode == 0) == accepted, f"{label}: {result.stderr}"
    passed += 1
    print(f"ok   [{label}]")

phase_plan("observed terminal cutover plan accepted", "apply", [
    {"address": "google_iam_workload_identity_pool_provider.github", "change": {"actions": ["update"]}},
    {"address": "google_project_iam_custom_role.infra_drift", "change": {"actions": ["create"]}},
    {"address": "google_service_account_iam_member.billing_catalog_wif_main", "change": {"actions": ["create", "delete"]}},
    {"address": "google_storage_bucket_iam_member.deploy_billing_state_reader[0]", "previous_address": "google_storage_bucket_iam_member.deploy_billing_state_reader", "change": {"actions": ["delete"]}},
], True)
phase_plan("tainted planned cleanup retry accepted", "apply", [
    {"address": "terraform_data.remove_legacy_iam_bindings", "change": {"actions": ["delete", "create"]}},
], True)
phase_plan("exact rollback authority plan accepted", "rollback", [
    {"address": "google_iam_workload_identity_pool_provider.github", "change": {"actions": ["update"]}},
    {"address": "google_service_account_iam_member.deploy_runtime_wif_platform_rollback[0]", "change": {"actions": ["create"]}},
    {"address": "google_service_account_iam_member.bootstrap_apply_wif_platform_rollback[0]", "change": {"actions": ["create"]}},
    {"address": "google_service_account_iam_member.billing_catalog_wif_platform_rollback[0]", "change": {"actions": ["create"]}},
    {"address": "google_storage_bucket_iam_member.deploy_billing_state_reader[0]", "change": {"actions": ["create"]}},
], True)
phase_plan("rollback cannot mutate price infrastructure", "rollback", [
    {"address": "google_secret_manager_secret.billing_price_ids", "change": {"actions": ["create"]}},
], False)
print(f"secondary deployment authority guard tests passed: {passed}")
PY
