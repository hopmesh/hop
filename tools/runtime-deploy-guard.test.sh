#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import importlib.util
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("guard", root / "tools/runtime-deploy-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
source = (root / ".github/workflows/runtime-deploy.yml").read_text()
passed = 0


def expect(label, old=None, new=None, first=False, last=False):
    global passed
    with tempfile.TemporaryDirectory() as directory:
        repo = pathlib.Path(directory)
        target = repo / ".github/workflows/runtime-deploy.yml"
        target.parent.mkdir(parents=True)
        text = source
        if old is not None:
            count = text.count(old)
            if count < 1 or (not first and not last and count != 1):
                raise AssertionError(f"{label}: bad mutation target count {count}")
            if last:
                before, separator, after = text.rpartition(old)
                text = before + new + after if separator else text
            else:
                text = text.replace(old, new, 1)
        target.write_text(text)
        errors = guard.check(repo)
        if old is None:
            if errors:
                raise AssertionError(f"clean workflow failed: {errors}")
        elif not errors:
            raise AssertionError(f"guard accepted hostile mutation: {label}")
        passed += 1
        print(f"ok   [{label}]")


expect("clean runtime workflow")
expect("wrong upstream repository rejected", "head_repository.full_name == 'hopmesh/hop'", "head_repository.full_name == 'hopmesh/legacy'")
expect("configuration cannot skip deploy job", "github.repository == 'hopmesh/hop'", "github.repository == 'hopmesh/hop' && vars.GCP_PROJECT_ID != ''")
expect("guard cannot be no-op comment", "run: python3 tools/runtime-deploy-guard.py", "run: true # python3 tools/runtime-deploy-guard.py")
expect("guard cannot tolerate failure", "run: python3 tools/runtime-deploy-guard.py", "run: python3 tools/runtime-deploy-guard.py || true")
expect("validation cannot access private token", "name: Validate OpenTofu roots without cloud credentials", "name: Validate OpenTofu roots without cloud credentials\n        env:\n          PRIVATE_SOURCE_KEY: ${{ secrets.HOP_SYNC_APP_PRIVATE_KEY }}")
expect("private credential cannot be job scoped", "RUNTIME_WIF_PROVIDER: ${{ vars.GCP_RUNTIME_WIF_PROVIDER }}", "PRIVATE_SOURCE_KEY: ${{ secrets.HOP_SYNC_APP_PRIVATE_KEY }}\n      RUNTIME_WIF_PROVIDER: ${{ vars.GCP_RUNTIME_WIF_PROVIDER }}")
expect("private checkout cannot use main", "ref: ${{ steps.pin.outputs.commit }}", "ref: main")
expect("private checkout cannot tolerate failure", "name: Check out pinned private source after public builds", "name: Check out pinned private source after public builds\n        continue-on-error: true")
expect("public images built before commercial names", "build_push hop-relayd services/hop-relayd/Dockerfile", "build_push hop-accountd services/hop-accountd/Dockerfile")
expect("public build requires no-cache", "docker build --no-cache --pull", "docker build --pull", first=True)
expect("private build requires accountd", 'accountd="$(build_push hop-accountd services/hop-accountd/Dockerfile /tmp/accountd-push.log)"', 'accountd="$(build_push missing services/missing/Dockerfile /tmp/accountd-push.log)"')
expect("plan policy rejects delete", 'allowed = {(), ("no-op",), ("read",), ("create",), ("update",)}', 'allowed = {(), ("no-op",), ("read",), ("create",), ("update",), ("delete",)}')
expect("apply consumes saved plan", "tofu apply -input=false -auto-approve -no-color tfplan", "tofu apply -input=false -auto-approve -no-color")
expect("readback requires private source label", 'labels.get("hop-private-source-sha")', 'labels.get("other-label")')
expect("public workflow rejects self-hosted", "runs-on: ubuntu-latest", "runs-on: [self-hosted, macOS]", first=True)
expect("pull request target prohibited", "pull_request:", "pull_request_target:")

expect("runtime deploy requires component-sync environment", "environment: component-sync", "environment: release")
expect("private source token remains read-only", "permission-contents: read", "permission-contents: write")
expect("private checkout uses minted App token", "token: ${{ steps.private-source-token.outputs.token }}", "token: ${{ github.token }}")
expect("private build output remains withheld", 'docker push "$tagged" >"$log" 2>&1', 'docker push "$tagged" | tee "$log"')
expect("price version lookup uses gcloud", "gcloud secrets versions list hop-billing-price-ids", "curl https://secretmanager.googleapis.com")

expect("runtime apply refuses superseded main immediately", 'test "$tip" = "$DEPLOY_SHA"', 'test "$tip" != ""', last=True)
expect("private staging output remains withheld", 'private-stage.log" 2>&1', 'private-stage.log"')
expect("runtime readback spans every region", "locations/-/services", "locations/us-central1/services")
# Execute the inline parser against gcloud's real JSON array shape and a stale REST envelope.
workflow = guard.load(root / ".github/workflows/runtime-deploy.yml")
deploy_steps = guard.steps(workflow["jobs"]["deploy"])
price_run = guard.named(deploy_steps, "Resolve the highest enabled billing price id version")["run"]
match = re.search(r"(?ms)<<'PY'\n(.*?)\n\s*PY", price_run)
assert match, "price version parser heredoc not found"
parser = match.group(1)
with tempfile.TemporaryDirectory() as directory:
    fixture = pathlib.Path(directory) / "versions.json"
    fixture.write_text(json.dumps([
        {"name": "projects/hop-mesh/secrets/hop-billing-price-ids/versions/2"},
        {"name": "projects/hop-mesh/secrets/hop-billing-price-ids/versions/7"},
    ]))
    result = subprocess.run([sys.executable, "-", str(fixture)], input=parser, text=True, capture_output=True)
    assert result.returncode == 0 and result.stdout.strip() == "7", result
    passed += 1
    print("ok   [gcloud price version array parsed]")
    fixture.write_text(json.dumps({"versions": []}))
    result = subprocess.run([sys.executable, "-", str(fixture)], input=parser, text=True, capture_output=True)
    assert result.returncode != 0 and "not a JSON array" in result.stderr, result
    passed += 1
    print("ok   [stale REST price envelope rejected]")
print(f"runtime deploy guard tests passed: {passed}")
PY
