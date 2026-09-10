#!/usr/bin/env python3
"""Enforce billing and drift workflow authority during deploy cutover."""

from __future__ import annotations

import argparse
from pathlib import Path

import yaml

BILLING = ".github/workflows/billing-catalog.yml"
DRIFT = ".github/workflows/infra-drift.yml"
BOOTSTRAP = ".github/workflows/bootstrap-apply.yml"


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
    try:
        token_index, token = step_by_name(catalog, "Require the private checkout token")
        checkout_index, checkout = step_by_name(catalog, "Check out exact private billing source")
        verify_index, _ = step_by_name(catalog, "Verify exact private checkout")
        plan_index, plan = step_by_name(catalog, "Create saved private billing plan")
        apply_index, apply = step_by_name(catalog, "Apply the saved private billing plan")
        publish_index, publish = step_by_name(catalog, "Publish one validated billing price id version")
        if [token_index, checkout_index, verify_index, plan_index, apply_index, publish_index] != sorted(
            [token_index, checkout_index, verify_index, plan_index, apply_index, publish_index]
        ):
            errors.append("billing workflow order drifted")
        if token.get("env") != {"PRIVATE_SOURCE_TOKEN": "${{ secrets.HOP_SYNC_TOKEN }}"}:
            errors.append("billing token scope drifted")
        expected_checkout = {
            "repository": "${{ steps.pin.outputs.repository }}",
            "ref": "${{ steps.pin.outputs.commit }}",
            "token": "${{ secrets.HOP_SYNC_TOKEN }}",
            "path": "private",
            "fetch-depth": "1",
            "persist-credentials": "false",
        }
        if checkout.get("with") != expected_checkout:
            errors.append("billing private checkout is not exact and credential-minimal")
        if "-out=tfplan" not in plan.get("run", "") or "tofu show -json tfplan" not in plan.get("run", ""):
            errors.append("billing workflow does not inspect one saved plan")
        if "tofu apply" not in apply.get("run", "") or "tfplan" not in apply.get("run", ""):
            errors.append("billing apply does not use the saved plan")
        if apply.get("if") != "env.OPERATION == 'apply'":
            errors.append("billing apply condition drifted")
        publish_text = publish.get("run", "")
        if publish.get("if") != "steps.apply.outputs.applied == 'true'" or "hop-billing-price-ids:addVersion" not in publish_text:
            errors.append("billing price id version is not coupled to a successful apply")
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
    if set(jobs) != {"validate", "bootstrap"}:
        errors.append(f"drift jobs drifted: {sorted(jobs)}")
        return errors
    bootstrap = jobs["bootstrap"]
    condition = bootstrap.get("if", "")
    for required in (
        "github.event_name != 'pull_request'",
        "github.repository == 'hopmesh/hop'",
        "github.ref == 'refs/heads/main'",
    ):
        if required not in condition:
            errors.append(f"drift eligibility missing: {required}")
    text = path.read_text(encoding="utf-8")
    if "tofu apply" in text:
        errors.append("drift workflow may not apply")
    if "-detailed-exitcode -lock=false" not in text:
        errors.append("drift workflow does not distinguish drift without locking state")
    if "bootstrap drift detected" not in text or "bootstrap drift check failed" not in text:
        errors.append("drift workflow does not distinguish drift from execution failure")
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
    condition = job.get("if", "")
    for required in (
        "github.event_name == 'workflow_dispatch'",
        "github.repository == 'hopmesh/hop'",
        "github.ref == 'refs/heads/main'",
        "inputs.confirm == 'bootstrap hopmesh/hop main'",
        "inputs.confirm == 'rollback hop authority to platform'",
    ):
        if required not in condition:
            errors.append(f"bootstrap eligibility missing: {required}")
    text = path.read_text(encoding="utf-8")
    for forbidden in ("BOOTSTRAP_TFVARS", "secrets.HOP_SYNC_TOKEN"):
        if forbidden in text:
            errors.append(f"bootstrap workflow contains forbidden authority input: {forbidden}")
    try:
        _, materialize = step_by_name(job, "Materialize reviewed non-secret bootstrap inputs")
        plan_index, plan = step_by_name(job, "Create and inspect one saved bootstrap plan")
        policy_index, policy = step_by_name(job, "Refuse unrelated bootstrap actions")
        apply_index, apply = step_by_name(job, "Apply the saved bootstrap plan")
        proof_index, proof = step_by_name(job, "Prove final or rollback authority state")
        if [plan_index, policy_index, apply_index, proof_index] != sorted([plan_index, policy_index, apply_index, proof_index]):
            errors.append("bootstrap plan, policy, apply, and proof order drifted")
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
            'actions == ("delete",) and address == "google_storage_bucket_iam_member.deploy_billing_state_reader" and operation != "rollback"',
            'raise SystemExit(f"bootstrap plan contains unapproved actions: {bad}")',
        ):
            if policy_text.count(required) != 1:
                errors.append(f"bootstrap plan policy missing exact guard: {required}")
        if "tofu apply" not in apply.get("run", "") or "tfplan" not in apply.get("run", ""):
            errors.append("bootstrap apply does not consume the saved plan")
        if apply.get("if") != "env.OPERATION == 'apply' || env.OPERATION == 'rollback'":
            errors.append("bootstrap apply operation gate drifted")
        proof_text = proof.get("run", "")
        for required in ("hopmesh/hop", "hopmesh/platform", "roles/iam.serviceAccountTokenCreator", "attributeCondition"):
            if required not in proof_text:
                errors.append(f"bootstrap live authority proof missing: {required}")
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
