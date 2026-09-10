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
spec = importlib.util.spec_from_file_location("guard", root / "tools/runtime-deploy-guard.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
source = (root / ".github/workflows/runtime-deploy.yml").read_text()
passed = 0


def expect(label, old=None, new=None, first=False):
    global passed
    with tempfile.TemporaryDirectory() as directory:
        repo = pathlib.Path(directory)
        target = repo / ".github/workflows/runtime-deploy.yml"
        target.parent.mkdir(parents=True)
        text = source
        if old is not None:
            count = text.count(old)
            if count < 1 or (not first and count != 1):
                raise AssertionError(f"{label}: bad mutation target count {count}")
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
expect("validation cannot access private token", "name: Validate OpenTofu roots without cloud credentials", "name: Validate OpenTofu roots without cloud credentials\n        env:\n          PRIVATE_SOURCE_TOKEN: ${{ secrets.HOP_SYNC_TOKEN }}")
expect("private token cannot be job scoped", "RUNTIME_WIF_PROVIDER: ${{ vars.GCP_RUNTIME_WIF_PROVIDER }}", "PRIVATE_SOURCE_TOKEN: ${{ secrets.HOP_SYNC_TOKEN }}\n      RUNTIME_WIF_PROVIDER: ${{ vars.GCP_RUNTIME_WIF_PROVIDER }}")
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

expect("runtime deploy requires release environment", "environment: release", "environment: component-sync")
print(f"runtime deploy guard tests passed: {passed}")
PY
