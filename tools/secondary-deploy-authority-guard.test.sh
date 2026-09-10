#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import pathlib
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
expect("billing cannot read Stripe GitHub secret", "billing-catalog.yml", "token: ${{ secrets.HOP_SYNC_TOKEN }}", "token: ${{ secrets.STRIPE_API_KEY }}")
expect("billing PR validation cannot read a secret", "billing-catalog.yml", "name: Billing deployment authority validation", "name: Billing deployment authority validation\n    env:\n      TOKEN: ${{ secrets.HOP_SYNC_TOKEN }}")
expect("billing checkout cannot use main", "billing-catalog.yml", "ref: ${{ steps.pin.outputs.commit }}", "ref: main")
expect("billing apply must use saved plan", "billing-catalog.yml", "tofu apply -input=false -auto-approve -no-color tfplan", "tofu apply -input=false -auto-approve -no-color")
expect("price publication must follow apply", "billing-catalog.yml", "if: steps.apply.outputs.applied == 'true'", "if: always()")
expect("billing cannot tolerate failure", "billing-catalog.yml", "name: Apply the saved private billing plan", "name: Apply the saved private billing plan\n        continue-on-error: true")
expect("drift cannot use opaque tfvars", "infra-drift.yml", "Materialize reviewed non-secret bootstrap inputs", "Materialize BOOTSTRAP_TFVARS inputs")
expect("drift cannot apply", "infra-drift.yml", "tofu plan -input=false", "tofu apply -input=false")
expect("drift cannot run on PR", "infra-drift.yml", "github.event_name != 'pull_request'", "github.event_name == 'pull_request'")
expect("drift cannot use self-hosted", "infra-drift.yml", "runs-on: ubuntu-latest", "runs-on: [self-hosted, macOS]", first=True)
expect("drift must keep detailed exit code", "infra-drift.yml", "-detailed-exitcode -lock=false", "-lock=false")

expect("bootstrap cannot use opaque tfvars", "bootstrap-apply.yml", "Materialize reviewed non-secret bootstrap inputs", "Materialize BOOTSTRAP_TFVARS inputs")
expect("bootstrap cannot target another repository", "bootstrap-apply.yml", "github_repository        = \"hopmesh/hop\"", "github_repository        = \"hopmesh/legacy\"")
expect("bootstrap apply must use saved plan", "bootstrap-apply.yml", "tofu apply -input=false -auto-approve -no-color tfplan", "tofu apply -input=false -auto-approve -no-color")
expect("bootstrap rollback phrase fixed", "bootstrap-apply.yml", "inputs.confirm == 'rollback hop authority to platform'", "inputs.confirm == 'rollback anywhere'")
expect("bootstrap plan rejects prior addresses", "bootstrap-apply.yml", 'previous = item.get("previous_address")', 'previous = None')
expect("bootstrap plan delete allowlist fixed", "bootstrap-apply.yml", 'address == "google_storage_bucket_iam_member.deploy_billing_state_reader"', 'address.startswith("google_storage_bucket_iam_member.")')
expect("bootstrap proof checks token creator", "bootstrap-apply.yml", '"roles/iam.serviceAccountTokenCreator"', '"roles/iam.viewer"')
expect("bootstrap cannot use self-hosted", "bootstrap-apply.yml", "runs-on: ubuntu-latest", "runs-on: [self-hosted, macOS]", first=True)
expect("bootstrap requires release environment", "bootstrap-apply.yml", "environment: release", "environment: component-sync")
expect("billing requires release environment", "billing-catalog.yml", "environment: release", "environment: component-sync")
print(f"secondary deployment authority guard tests passed: {passed}")
PY
