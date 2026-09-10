#!/usr/bin/env python3
"""Enforce billing and drift workflow authority during deploy cutover."""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path

import yaml

BILLING = ".github/workflows/billing-catalog.yml"
DRIFT = ".github/workflows/infra-drift.yml"
BOOTSTRAP = ".github/workflows/bootstrap-apply.yml"
BOOTSTRAP_PROOF_SHA256 = "2a7f92e401affe606000b88c1ec23a353ff1ad611c75ad3f2dcfb7088d1c7474"


def load(path: Path) -> dict:
    try:
        value = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    except (OSError, yaml.YAMLError) as error:
        raise ValueError(f"{path.name} is not valid YAML: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{path.name} must be a mapping")
    return value


def job_steps(job: dict) -> list[dict]:
    value = job.get("steps", [])
    return value if isinstance(value, list) else []


def step_by_name(job: dict, name: str) -> tuple[int, dict]:
    found = [(index, step) for index, step in enumerate(job_steps(job)) if step.get("name") == name]
    if len(found) != 1:
        raise ValueError(f"expected one {name!r} step, got {len(found)}")
    return found[0]


def common_errors(path: Path, doc: dict) -> list[str]:
    errors: list[str] = []
    text = path.read_text(encoding="utf-8")
    if "self-hosted" in text:
        errors.append(f"{path.name} may not use a self-hosted runner")
    if "BOOTSTRAP_TFVARS" in text:
        errors.append(f"{path.name} may not depend on BOOTSTRAP_TFVARS")
    if "secrets.STRIPE_API_KEY" in text or "secrets.RESEND_API_KEY" in text:
        errors.append(f"{path.name} may not read commercial GitHub secrets")
    for name, job in doc.get("jobs", {}).items():
        if job.get("continue-on-error", "false") not in (None, "false"):
            errors.append(f"{path.name} job {name} tolerates failure")
        for step in job_steps(job):
            if step.get("continue-on-error", "false") not in (None, "false"):
                errors.append(f"{path.name} step {step.get('name', step.get('id'))} tolerates failure")
    return errors


def check_billing(root: Path) -> list[str]:
    path = root / BILLING
    try:
        doc = load(path)
    except ValueError as error:
        return [str(error)]
    errors = common_errors(path, doc)
    triggers = doc.get("on", {})
    if not isinstance(triggers, dict) or set(triggers) != {"pull_request", "workflow_dispatch"}:
        errors.append("billing workflow must be PR-static and manual-dispatch only")
    if doc.get("permissions") != {"contents": "read", "id-token": "write"}:
        errors.append("billing workflow permissions drifted")
    if doc.get("concurrency", {}).get("cancel-in-progress") != "false":
        errors.append("billing workflow must serialize through price-id publication")
    jobs = doc.get("jobs", {})
    if set(jobs) != {"validate", "catalog"}:
        errors.append(f"billing jobs drifted: {sorted(jobs)}")
        return errors
    validate_text = yaml.safe_dump(jobs["validate"], sort_keys=False)
    if "secrets." in validate_text:
        errors.append("billing PR validation references a secret")
    catalog = jobs["catalog"]
    if catalog.get("environment") != "component-sync":
        errors.append("billing deploy must use the protected component-sync environment")
    condition = catalog.get("if", "")
    for required in (
        "github.event_name == 'workflow_dispatch'",
        "github.repository == 'hopmesh/hop'",
        "github.ref == 'refs/heads/main'",
        "inputs.confirm == 'deploy billing from hop main'",
    ):
        if required not in condition:
            errors.append(f"billing eligibility missing: {required}")
    if "vars." in condition or "secrets." in condition:
        errors.append("missing billing configuration must fail inside the job")
    workflow_text = path.read_text(encoding="utf-8")
    if "HOP_SYNC_TOKEN" in workflow_text:
        errors.append("billing workflow retains the broad organization PAT")
    if "secretmanager.googleapis.com" in workflow_text or "curl " in workflow_text:
        errors.append("billing workflow downloads or writes API JSON through curl")
    try:
        public_index, public = step_by_name(catalog, "Check out canonical hop main")
        pin_index, pin = step_by_name(catalog, "Validate and read private source pin")
        token_index, token = step_by_name(catalog, "Create read-only private source token")
        checkout_index, checkout = step_by_name(catalog, "Check out exact private billing source")
        verify_index, _ = step_by_name(catalog, "Verify exact private checkout")
        credentials_index, credentials = step_by_name(catalog, "Load vendor credentials from Secret Manager without logging")
        plan_index, plan = step_by_name(catalog, "Create saved private billing plan")
        policy_index, _ = step_by_name(catalog, "Refuse billing deletion or replacement")
        stale_index, stale = step_by_name(catalog, "Refuse a superseded billing apply")
        apply_index, apply = step_by_name(catalog, "Apply the saved private billing plan")
        publish_index, publish = step_by_name(catalog, "Publish one validated billing price id version")
        order = [public_index, pin_index, token_index, checkout_index, verify_index, credentials_index, plan_index, policy_index, stale_index, apply_index, publish_index]
        if order != sorted(order):
            errors.append("billing workflow order drifted")
        if public.get("with", {}).get("ref") != "${{ github.sha }}" or catalog.get("env", {}).get("EXPECTED_SHA") != "${{ github.sha }}":
            errors.append("billing workflow does not pin the reviewed dispatch SHA")
        pin_text = pin.get("run", "")
        for required in ('git rev-parse HEAD)" = "$EXPECTED_SHA', '"$EXPECTED_SHA" = "$(git ls-remote origin refs/heads/main'):
            if required not in pin_text:
                errors.append(f"billing initial main check missing: {required}")
        if token.get("uses") != "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1" or token.get("with") != {
            "app-id": "${{ secrets.HOP_SYNC_APP_ID }}", "private-key": "${{ secrets.HOP_SYNC_APP_PRIVATE_KEY }}",
            "owner": "hopmesh", "repositories": "platform", "permission-contents": "read",
        }:
            errors.append("billing private source token is not immutable repository-scoped read-only")
        expected_checkout = {
            "repository": "${{ steps.pin.outputs.repository }}", "ref": "${{ steps.pin.outputs.commit }}",
            "token": "${{ steps.private-source-token.outputs.token }}", "path": "private",
            "fetch-depth": "1", "persist-credentials": "false",
        }
        if checkout.get("with") != expected_checkout:
            errors.append("billing private checkout is not exact and credential-minimal")
        credentials_text = credentials.get("run", "")
        if credentials_text.count("gcloud secrets versions access latest") != 1 or "detailed" in credentials_text or "curl " in credentials_text:
            errors.append("billing vendor credential loader drifted")
        plan_text = plan.get("run", "")
        if "-out=tfplan" not in plan_text or "tofu show -json tfplan" not in plan_text or 'billing-plan.log" 2>&1' not in plan_text or "detailed output withheld" not in plan_text:
            errors.append("billing workflow does not privately inspect one saved plan")
        stale_text = stale.get("run", "")
        if stale.get("if") != "env.OPERATION == 'apply'" or 'git rev-parse HEAD)" = "$EXPECTED_SHA' not in stale_text or '"$tip" = "$EXPECTED_SHA"' not in stale_text:
            errors.append("billing apply is not rejected when hop main is superseded")
        apply_text = apply.get("run", "")
        if "tofu apply" not in apply_text or "tfplan" not in apply_text or "billing-apply.log" not in apply_text or "detailed output withheld" not in apply_text:
            errors.append("billing apply does not privately consume the saved plan")
        if apply.get("if") != "env.OPERATION == 'apply'":
            errors.append("billing apply condition drifted")
        publish_text = publish.get("run", "")
        if publish.get("if") != "steps.apply.outputs.applied == 'true'" or "gcloud secrets versions add hop-billing-price-ids" not in publish_text or 'payload["private_source_sha"]' not in publish_text:
            errors.append("billing price id version is not coupled to successful apply and private source")
    except ValueError as error:
        errors.append(str(error))
    return errors


def check_drift(root: Path) -> list[str]:
    path = root / DRIFT
    try:
        doc = load(path)
    except ValueError as error:
        return [str(error)]
    errors = common_errors(path, doc)
    triggers = doc.get("on", {})
    if not isinstance(triggers, dict) or set(triggers) != {"pull_request", "schedule", "workflow_dispatch"}:
        errors.append("drift workflow trigger set drifted")
    if doc.get("permissions") != {"contents": "read", "id-token": "write"}:
        errors.append("drift workflow permissions drifted")
    jobs = doc.get("jobs", {})
    if set(jobs) != {"validate", "runtime"}:
        errors.append(f"drift jobs drifted: {sorted(jobs)}")
        return errors
    runtime = jobs["runtime"]
    if runtime.get("environment") != "release":
        errors.append("drift must use the protected release environment")
    drift_env = runtime.get("env", {})
    if drift_env.get("DRIFT_WIF_PROVIDER") != "${{ vars.GCP_DRIFT_WIF_PROVIDER }}" or drift_env.get("DRIFT_SERVICE_ACCOUNT") != "${{ vars.GCP_DRIFT_SERVICE_ACCOUNT }}":
        errors.append("drift job does not use the dedicated repository variables")
    condition = runtime.get("if", "")
    for required in (
        "github.event_name != 'pull_request'",
        "github.repository == 'hopmesh/hop'",
        "github.ref == 'refs/heads/main'",
    ):
        if required not in condition:
            errors.append(f"drift eligibility missing: {required}")
    text = path.read_text(encoding="utf-8")
    for forbidden in (
        "tofu apply", "terraform apply", "BOOTSTRAP_WIF_PROVIDER", "BOOTSTRAP_SERVICE_ACCOUNT",
        "infra/bootstrap", "gcloud ", "curl ", "kubectl ", "gh api", "gh workflow",
    ):
        if forbidden in text:
            errors.append(f"drift workflow contains forbidden mutation or admin surface: {forbidden}")
    runtime_text = yaml.safe_dump(runtime, sort_keys=False)
    if "secrets." in runtime_text:
        errors.append("drift runtime job may not read GitHub secrets")
    try:
        auth_index, auth = step_by_name(runtime, "Authenticate read-only drift identity")
        restore_index, restore = step_by_name(runtime, "Restore non-secret applied runtime inputs")
        plan_index, plan = step_by_name(runtime, "Fail on runtime drift without disclosing private build detail")
        if [auth_index, restore_index, plan_index] != sorted([auth_index, restore_index, plan_index]):
            errors.append("drift auth, state input, and plan order drifted")
        auth_with = auth.get("with", {})
        if auth_with.get("workload_identity_provider") != "${{ env.DRIFT_WIF_PROVIDER }}" or auth_with.get("service_account") != "${{ env.DRIFT_SERVICE_ACCOUNT }}":
            errors.append("drift does not authenticate the dedicated read-only identity")
        restore_text = restore.get("run", "")
        if "tofu output -json drift_inputs" not in restore_text or "TF_VAR_" not in restore_text:
            errors.append("drift does not restore the applied non-secret runtime inputs")
        plan_text = plan.get("run", "")
        normalized = plan_text.replace('>"', '>').replace('"', '')
        for required in ("-detailed-exitcode -lock=false -out=drift.tfplan", ">$RUNNER_TEMP/runtime-drift.log", "tofu show -json drift.tfplan", "runtime infrastructure drift detected", "detailed output withheld"):
            if required not in normalized:
                errors.append(f"drift plan proof missing: {required}")
    except ValueError as error:
        errors.append(str(error))
    return errors



def check_bootstrap(root: Path) -> list[str]:
    path = root / BOOTSTRAP
    try:
        doc = load(path)
    except ValueError as error:
        return [str(error)]
    errors = common_errors(path, doc)
    triggers = doc.get("on", {})
    if not isinstance(triggers, dict) or set(triggers) != {"pull_request", "workflow_dispatch"}:
        errors.append("bootstrap workflow must be PR-static and manual-dispatch only")
    if doc.get("permissions") != {"contents": "read", "id-token": "write"}:
        errors.append("bootstrap workflow permissions drifted")
    if doc.get("concurrency", {}).get("cancel-in-progress") != "false":
        errors.append("bootstrap workflow must serialize authority changes")
    jobs = doc.get("jobs", {})
    if set(jobs) != {"validate", "bootstrap"}:
        errors.append(f"bootstrap jobs drifted: {sorted(jobs)}")
        return errors
    validate_text = yaml.safe_dump(jobs["validate"], sort_keys=False)
    if "secrets." in validate_text:
        errors.append("bootstrap PR validation references a secret")
    job = jobs["bootstrap"]
    if job.get("environment") != "release":
        errors.append("bootstrap apply must use the protected release environment")
    condition = job.get("if", "")
    for required in (
        "github.event_name == 'workflow_dispatch'",
        "github.repository == 'hopmesh/hop'",
        "github.ref == 'refs/heads/main'",
        "inputs.ancestor_review == 'owner verified no inherited non-owner auth or secret grants'",
        "inputs.confirm == 'bootstrap hopmesh/hop main'",
        "inputs.confirm == 'rollback hop authority to platform'",
    ):
        if required not in condition:
            errors.append(f"bootstrap eligibility missing: {required}")
    text = path.read_text(encoding="utf-8")
    for forbidden in ("BOOTSTRAP_TFVARS", "secrets.HOP_SYNC_TOKEN"):
        if forbidden in text:
            errors.append(f"bootstrap workflow contains forbidden authority input: {forbidden}")
    checkout_steps = [step for step in job_steps(job) if step.get("uses", "").startswith("actions/checkout@")]
    if len(checkout_steps) != 1 or checkout_steps[0].get("with", {}).get("ref") != "${{ github.sha }}" or job.get("env", {}).get("EXPECTED_SHA") != "${{ github.sha }}":
        errors.append("bootstrap workflow does not pin the reviewed dispatch SHA")
    try:
        initial_index, initial = step_by_name(job, "Require canonical main and every non-secret input")
        _, materialize = step_by_name(job, "Materialize reviewed non-secret bootstrap inputs")
        plan_index, plan = step_by_name(job, "Create and inspect one saved bootstrap plan")
        policy_index, policy = step_by_name(job, "Refuse unrelated bootstrap actions")
        stale_index, stale = step_by_name(job, "Refuse a superseded bootstrap apply")
        apply_index, apply = step_by_name(job, "Apply the saved bootstrap plan")
        proof_index, proof = step_by_name(job, "Prove final or rollback authority state")
        order = [initial_index, plan_index, policy_index, stale_index, apply_index, proof_index]
        if order != sorted(order):
            errors.append("bootstrap source, plan, policy, supersession, apply, and proof order drifted")
        initial_text = initial.get("run", "")
        for required in ('git rev-parse HEAD)" = "$EXPECTED_SHA', '"$EXPECTED_SHA" = "$(git ls-remote origin refs/heads/main'):
            if required not in initial_text:
                errors.append(f"bootstrap initial main check missing: {required}")
        materialize_text = materialize.get("run", "")
        if 'phase=hop' not in materialize_text or 'if [ "$OPERATION" = rollback ]; then phase=handoff; fi' not in materialize_text:
            errors.append("bootstrap workflow does not map operations to the closed authority phases")
        if materialize_text.count('github_repository        = "hopmesh/hop"') != 1:
            errors.append("bootstrap workflow does not pin the canonical repository input")
        if "-out=tfplan" not in plan.get("run", "") or "tofu show -json tfplan" not in plan.get("run", ""):
            errors.append("bootstrap workflow does not inspect one saved plan")
        policy_text = policy.get("run", "")
        for required in (
            'previous = item.get("previous_address")',
            'previous == "google_storage_bucket_iam_member.deploy_billing_state_reader" and actions == ("delete",)',
            'normal_mutable = {',
            'normal_replacements = {',
            'rollback_creates = {',
            'if operation == "rollback":',
            'address in rollback_creates and actions == ("create",)',
            'actions == ("delete",) and address in normal_deletes',
            'actions == ("create", "delete") and address in normal_replacements',
            'actions == ("forget",) and address == "google_service_account.build"',
            'raise SystemExit(f"bootstrap plan contains unapproved actions: {bad}")',
        ):
            if policy_text.count(required) != 1:
                errors.append(f"bootstrap plan policy missing exact guard: {required}")
        def embedded_set(name):
            match = re.search(rf"(?ms)^\s*{re.escape(name)}\s*=\s*\{{(.*?)^\s*\}}", policy_text)
            return set(re.findall(r'"([^"]+)"', match.group(1))) if match else None
        expected_sets = {
            "normal_mutable": {
                "google_iam_workload_identity_pool_provider.github",
                "google_service_account_iam_member.deploy_runtime_wif",
                "google_service_account_iam_member.bootstrap_apply_wif",
                "google_service_account_iam_member.billing_catalog_wif_main",
                "google_service_account.infra_drift",
                "google_project_iam_custom_role.infra_drift",
                "terraform_data.remove_legacy_iam_bindings",
                "google_service_account_iam_member.infra_drift_wif",
                "google_project_iam_member.infra_drift_viewer",
                "google_storage_bucket_iam_member.infra_drift_state_reader",
                "google_secret_manager_secret_iam_member.infra_drift_price_ids_accessor",
                "google_secret_manager_secret_iam_member.infra_drift_price_ids_viewer",
                "google_secret_manager_secret.billing_price_ids",
                "google_secret_manager_secret_iam_member.billing_catalog_price_ids_writer",
                "google_secret_manager_secret_iam_member.billing_catalog_stripe_api_key_reader",
                "google_secret_manager_secret_iam_member.billing_catalog_resend_api_key_reader",
                "google_secret_manager_secret_iam_member.deploy_billing_price_ids_accessor",
                "google_secret_manager_secret_iam_member.deploy_billing_price_ids_viewer",
            },
            "normal_replacements": {
                "google_service_account_iam_member.deploy_runtime_wif",
                "google_service_account_iam_member.bootstrap_apply_wif",
                "google_service_account_iam_member.billing_catalog_wif_main",
            },
            "rollback_creates": {
                "google_service_account_iam_member.deploy_runtime_wif_platform_rollback[0]",
                "google_service_account_iam_member.bootstrap_apply_wif_platform_rollback[0]",
                "google_service_account_iam_member.billing_catalog_wif_platform_rollback[0]",
                "google_storage_bucket_iam_member.deploy_billing_state_reader[0]",
            },
        }
        for name, expected in expected_sets.items():
            if embedded_set(name) != expected:
                errors.append(f"bootstrap plan {name} address set drifted")
        stale_text = stale.get("run", "")
        if stale.get("if") != "env.OPERATION == 'apply' || env.OPERATION == 'rollback'" or 'git rev-parse HEAD)" = "$EXPECTED_SHA' not in stale_text or '"$tip" = "$EXPECTED_SHA"' not in stale_text:
            errors.append("bootstrap apply is not rejected when hop main is superseded")
        if "tofu apply" not in apply.get("run", "") or "tfplan" not in apply.get("run", ""):
            errors.append("bootstrap apply does not consume the saved plan")
        if apply.get("if") != "env.OPERATION == 'apply' || env.OPERATION == 'rollback'":
            errors.append("bootstrap apply operation gate drifted")
        proof_text = proof.get("run", "")
        if hashlib.sha256(proof_text.encode()).hexdigest() != BOOTSTRAP_PROOF_SHA256:
            errors.append("bootstrap whole-policy proof source drifted")
        required_counts = {
            '"attribute.workflow": "assertion.workflow_ref"': 1,
            'binding.get("condition") not in (None, {})': 3,
            'workflow("hopmesh/hop", "runtime-deploy.yml")': 1,
            'workflow("hopmesh/platform", "handoff-deploy-authority.yml")': 1,
            "gcloud projects get-iam-policy": 1,
            "gcloud iam roles list": 1,
            "gcloud iam service-accounts list": 1,
            "gcloud secrets get-iam-policy": 1,
            "gcloud storage buckets get-iam-policy": 1,
            'raise SystemExit("project IAM contains a federated principal")': 1,
            'raise SystemExit("project IAM grants a custom role with secret version data access")': 1,
            'raise SystemExit("project IAM binds an organization-defined custom role")': 1,
            'raise SystemExit("project IAM binds an unresolved project custom role")': 1,
            "expected_sa_policies = {": 1,
            'raise SystemExit(f"{label} complete service-account IAM policy drifted")': 1,
            "expected_project_policy = {": 1,
            'raise SystemExit("complete project IAM policy drifted")': 1,
            'raise SystemExit("retired Cloud Build deploy identity is not disabled")': 1,
            "expected_secrets = {": 1,
            "expected_bucket_policy = {": 1,
            'raise SystemExit("complete state bucket IAM policy drifted")': 1,
            '"jwksJson" in oidc': 1,
        }
        for required, expected_count in required_counts.items():
            if proof_text.count(required) != expected_count:
                errors.append(f"bootstrap live authority proof missing exact check: {required}")
    except ValueError as error:
        errors.append(str(error))
    return errors
def check(root: Path) -> list[str]:
    errors = check_billing(root) + check_drift(root) + check_bootstrap(root)
    for retired in ("resend-domain.yml", "canary-selfhosted-docker.yml"):
        if (root / ".github/workflows" / retired).exists():
            errors.append(f"retired duplicate workflow returned: {retired}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("."))
    args = parser.parse_args()
    errors = check(args.root.resolve())
    for error in errors:
        print(f"ERROR: {error}")
    if errors:
        return 1
    print("secondary deployment authority guard passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
