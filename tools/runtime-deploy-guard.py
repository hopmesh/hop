#!/usr/bin/env python3
"""Enforce the privileged runtime deployment workflow contract."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

WORKFLOW = ".github/workflows/runtime-deploy.yml"
PUBLIC_BUILD = "Build and push public relay and example images first"
TOKEN_GATE = "Create read-only private source token after public builds"
PRIVATE_CHECKOUT = "Check out pinned private source after public builds"
STAGE = "Verify and stage pinned commercial source"
PRIVATE_BUILD = "Build and push pinned account and console images"
PLAN = "Create saved runtime plan"
POLICY = "Refuse runtime deletion or replacement"
STALE = "Refuse a superseded apply"
APPLY = "Apply the saved runtime plan"
READBACK = "Prove every live runtime came from these commits"


def load(path: Path) -> dict:
    try:
        value = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    except (OSError, yaml.YAMLError) as error:
        raise ValueError(f"runtime workflow is not valid YAML: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("runtime workflow must be a mapping")
    return value


def steps(job: dict) -> list[dict]:
    value = job.get("steps", [])
    return value if isinstance(value, list) else []


def named(items: list[dict], name: str) -> dict:
    found = [item for item in items if item.get("name") == name]
    if len(found) != 1:
        raise ValueError(f"expected one runtime step named {name!r}, got {len(found)}")
    return found[0]


def active_gating_run(step: dict, expected: str) -> bool:
    return (
        step.get("run") == expected
        and "if" not in step
        and step.get("continue-on-error", "false") in (None, "false")
    )


def check(root: Path) -> list[str]:
    errors: list[str] = []
    path = root / WORKFLOW
    try:
        doc = load(path)
    except ValueError as error:
        return [str(error)]
    triggers = doc.get("on", {})
    if not isinstance(triggers, dict) or set(triggers) != {"pull_request", "workflow_run", "workflow_dispatch"}:
        errors.append("runtime workflow triggers must be pull_request, workflow_run, and workflow_dispatch only")
    if "pull_request_target" in triggers:
        errors.append("runtime workflow may not use pull_request_target")
    permissions = doc.get("permissions", {})
    if permissions != {"contents": "read", "id-token": "write"}:
        errors.append(f"runtime workflow permissions drifted: {permissions}")
    jobs = doc.get("jobs", {})
    if set(jobs) != {"validate", "deploy"}:
        errors.append(f"runtime workflow jobs drifted: {sorted(jobs)}")
        return errors
    validate = jobs["validate"]
    deploy = jobs["deploy"]
    if validate.get("runs-on") != "ubuntu-latest" or deploy.get("runs-on") != "ubuntu-latest":
        errors.append("runtime jobs must use GitHub-hosted ubuntu-latest")
    if deploy.get("environment") != "component-sync":
        errors.append("runtime deploy must use the protected component-sync environment")
    validate_text = yaml.safe_dump(validate, sort_keys=False)
    if "secrets." in validate_text or "id-token" in validate_text:
        errors.append("credential-free validation job references a secret or token")
    validate_steps = steps(validate)
    try:
        guard = named(validate_steps, "Validate canonical runtime workflow")
        self_test = named(validate_steps, "Self-test canonical runtime workflow guard")
        if not active_gating_run(guard, "python3 tools/runtime-deploy-guard.py"):
            errors.append("runtime guard is not an unconditional gating validation step")
        if not active_gating_run(self_test, "bash tools/runtime-deploy-guard.test.sh"):
            errors.append("runtime guard self-test is not an unconditional gating validation step")
    except ValueError as error:
        errors.append(str(error))

    condition = deploy.get("if", "")
    for required in (
        "github.event.workflow_run.conclusion == 'success'",
        "github.event.workflow_run.event == 'push'",
        "github.event.workflow_run.head_branch == 'main'",
        "github.event.workflow_run.head_repository.full_name == 'hopmesh/hop'",
        "github.repository == 'hopmesh/hop'",
        "github.ref == 'refs/heads/main'",
        "inputs.confirm == 'deploy hopmesh/hop main'",
    ):
        if required not in condition:
            errors.append(f"runtime deploy eligibility missing: {required}")
    if "vars." in condition or "secrets." in condition:
        errors.append("missing deploy configuration must fail inside the job, not skip the job")
    if deploy.get("continue-on-error", "false") not in (None, "false"):
        errors.append("runtime deploy job may not tolerate failure")
    job_env = deploy.get("env", {})
    if any("HOP_SYNC" in str(value) for value in job_env.values()):
        errors.append("private source credential is exposed at job scope")

    deploy_steps = steps(deploy)
    names = [step.get("name") for step in deploy_steps]
    try:
        order = [names.index(name) for name in (
            PUBLIC_BUILD, TOKEN_GATE, PRIVATE_CHECKOUT, STAGE, PRIVATE_BUILD,
            PLAN, POLICY, STALE, APPLY, READBACK,
        )]
        if order != sorted(order):
            errors.append("runtime steps violate public-build-first and plan-before-apply order")
    except ValueError as error:
        errors.append(f"runtime required step missing: {error}")
        return errors

    public = named(deploy_steps, PUBLIC_BUILD).get("run", "")
    token_step = named(deploy_steps, TOKEN_GATE)
    private = named(deploy_steps, PRIVATE_BUILD).get("run", "")
    public_commands = (
        'relay="$(build_push hop-relayd services/hop-relayd/Dockerfile /tmp/relay-push.log)"',
        'example="$(build_push hop-example services/hop-endpoint/Dockerfile /tmp/example-push.log)"',
    )
    private_commands = (
        'accountd="$(build_push hop-accountd services/hop-accountd/Dockerfile /tmp/accountd-push.log)"',
        'console="$(build_push hop-console apps/web/console/Dockerfile /tmp/console-push.log)"',
    )
    if any(public.count(command) != 1 for command in public_commands) or public.count("docker build --no-cache --pull") != 1:
        errors.append("public image step does not build exactly relay and example without cache")
    if "hop-accountd" in public or "hop-console" in public:
        errors.append("public image step includes commercial image names")
    if any(private.count(command) != 1 for command in private_commands) or private.count("docker build --no-cache --pull") != 1:
        errors.append("private image step does not build exactly accountd and console without cache")
    for required in ('>"${log%.log}-build.log" 2>&1', 'docker push "$tagged" >"$log" 2>&1', "detailed output withheld"):
        if required not in private:
            errors.append(f"private image logs are not withheld: {required}")
    if "| tee" in private or "cat " in private:
        errors.append("private image step can emit captured commercial build output")
    if token_step.get("uses") != "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1":
        errors.append("private source token action is not immutable")
    expected_token = {
        "app-id": "${{ secrets.HOP_SYNC_APP_ID }}",
        "private-key": "${{ secrets.HOP_SYNC_APP_PRIVATE_KEY }}",
        "owner": "hopmesh",
        "repositories": "platform",
        "permission-contents": "read",
    }
    if token_step.get("with") != expected_token:
        errors.append("private source token is not repository-scoped read-only")

    for index, step in enumerate(deploy_steps):
        if "HOP_SYNC_APP" in yaml.safe_dump(step, sort_keys=False) and index != order[1]:
            errors.append("private source App credential is reachable outside its token-mint step")
        if step.get("continue-on-error", "false") not in (None, "false"):
            errors.append(f"runtime step tolerates failure: {step.get('name', step.get('id'))}")
    checkout = named(deploy_steps, PRIVATE_CHECKOUT).get("with", {})
    expected_checkout = {
        "repository": "${{ steps.pin.outputs.repository }}",
        "ref": "${{ steps.pin.outputs.commit }}",
        "token": "${{ steps.private-source-token.outputs.token }}",
        "path": "private",
        "fetch-depth": "1",
        "persist-credentials": "false",
    }
    if checkout != expected_checkout:
        errors.append(f"private source checkout contract drifted: {checkout}")
    stage = named(deploy_steps, STAGE).get("run", "")
    for required in ("verify-checkout", "stage-commercial-source.py", "--pin", "--dest-pin", "--check"):
        if required not in stage:
            errors.append(f"private source staging missing: {required}")
    for log_name in ("private-checkout.log", "private-stage.log", "private-stage-check.log"):
        if f'>$RUNNER_TEMP/{log_name}' not in stage.replace('>"', '>').replace('"', ''):
            errors.append(f"private source staging output is not captured: {log_name}")
    if stage.count("2>&1") != 3 or stage.count("detailed output withheld") != 3 or "cat " in stage:
        errors.append("private source staging can disclose private paths or status")
    plan = named(deploy_steps, PLAN).get("run", "")
    policy = named(deploy_steps, POLICY).get("run", "")
    stale = named(deploy_steps, STALE)
    apply = named(deploy_steps, APPLY)
    if "tofu plan" not in plan or "-out=tfplan" not in plan or "tofu show -json tfplan" not in plan:
        errors.append("runtime workflow does not create and inspect one saved plan")
    if 'allowed = {(), ("no-op",), ("read",), ("create",), ("update",)}' not in policy:
        errors.append("runtime plan policy does not reject deletion and replacement")
    stale_text = stale.get("run", "")
    if stale.get("if") != "env.DEPLOY_OPERATION == 'apply'" or stale.get("working-directory") != "public" or 'tip="$(git ls-remote origin refs/heads/main | cut -f1)"' not in stale_text or 'test "$tip" = "$DEPLOY_SHA"' not in stale_text:
        errors.append("runtime apply is not rejected when hop main is superseded")
    if "tofu apply" not in apply.get("run", "") or "tfplan" not in apply.get("run", ""):
        errors.append("runtime apply does not consume the saved plan")
    if apply.get("if") != "env.DEPLOY_OPERATION == 'apply'":
        errors.append("runtime apply condition drifted")
    readback = named(deploy_steps, READBACK).get("run", "")
    for required in (
        'labels.get("hop-source-sha") != hop_sha',
        'labels.get("hop-private-source-sha") != private_sha',
        'required = {"hop-example", "hop-accountd", "hop-console"}',
        "urllib.request.Request(",
        "locations/-/services",
    ):
        if readback.count(required) != 1:
            errors.append(f"runtime provenance readback missing exact check: {required}")
    price = named(deploy_steps, "Resolve the highest enabled billing price id version").get("run", "")
    if "gcloud secrets versions list hop-billing-price-ids" not in price or "curl " in price:
        errors.append("runtime billing price version lookup bypasses the non-executable gcloud path")
    workflow_text = path.read_text(encoding="utf-8")
    if "HOP_SYNC_TOKEN" in workflow_text:
        errors.append("runtime workflow retains the broad organization PAT")
    if "secretmanager.googleapis.com" in workflow_text:
        errors.append("runtime workflow downloads Secret Manager JSON through an executable fetch surface")
    if "curl " in readback or "gcloud run services list" in readback:
        errors.append("runtime live readback does not use the all-region structured API path")
    if "self-hosted" in workflow_text:
        errors.append("public runtime workflow may not use a self-hosted runner")
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
    print("runtime deploy authority guard passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
