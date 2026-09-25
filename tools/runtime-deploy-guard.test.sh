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
import os
import tempfile
import yaml

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
expect("canonical CI workflow path required", "github.event.workflow_run.path == '.github/workflows/ci.yml'", "github.event.workflow_run.path == '.github/workflows/fake-ci.yml'")
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


IMAGE_DIGESTS = {
    "hop-relayd": "sha256:" + ("1" * 64),
    "hop-example": "sha256:" + ("2" * 64),
    "hop-accountd": "sha256:" + ("3" * 64),
    "hop-console": "sha256:" + ("4" * 64),
}
DEPLOY_SHA = "ab" * 20
PUBLIC_STEP = "Build and push public relay and example images first"
PRIVATE_STEP = "Build and push pinned account and console images"
DOCKER_STUB = r"""#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
shift || true
case "$cmd" in
  build)
    tag=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-t" ]; then
        tag="$arg"
      fi
      prev="$arg"
    done
    if [ -z "$tag" ]; then
      echo "docker stub: build missing -t" >&2
      exit 1
    fi
    # Dockerfile path (-f) and context are ignored. Progress goes to stdout, as docker does.
    printf '%s\n' \
      "#1 [internal] load build definition from Dockerfile" \
      "#1 transferring dockerfile: 123B done" \
      "#2 [internal] load metadata for docker.io/library/debian:bookworm" \
      "Successfully tagged ${tag}"
    ;;
  push)
    ref="${1:-}"
    if [ -z "$ref" ]; then
      echo "docker stub: push missing ref" >&2
      exit 1
    fi
    name="${ref##*/}"
    name="${name%%:*}"
    case "$name" in
__DIGEST_ARMS__
      *) echo "docker stub: unknown image ${name}" >&2; exit 1 ;;
    esac
    if [ "${DOCKER_PUSH_FAIL:-}" = "1" ]; then
      printf '%s\n' \
        "The push refers to repository [${ref%:*}]" \
        "9e318e74be6d: Preparing" \
        "9e318e74be6d: Pushing" \
        "error: failed to push ${ref}"
      exit 1
    fi
    printf '%s\n' \
      "The push refers to repository [${ref%:*}]" \
      "9e318e74be6d: Preparing" \
      "9e318e74be6d: Pushed" \
      "${ref}: digest: ${digest} size: 1234"
    ;;
  *)
    echo "docker stub: unsupported command: ${cmd}" >&2
    exit 1
    ;;
esac
"""


def image_ref(name: str) -> str:
    return f"us-central1-docker.pkg.dev/hop-mesh/hop/{name}@{IMAGE_DIGESTS[name]}"


def step_run(workflow_path: pathlib.Path, name: str) -> str:
    loaded = yaml.load(workflow_path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    if not isinstance(loaded, dict):
        raise AssertionError(f"workflow is not a mapping: {workflow_path}")
    steps = loaded.get("jobs", {}).get("deploy", {}).get("steps", [])
    found = [step for step in steps if isinstance(step, dict) and step.get("name") == name]
    if len(found) != 1:
        raise AssertionError(f"expected one step named {name!r}, got {len(found)}")
    run = found[0].get("run")
    if not isinstance(run, str) or not run.strip():
        raise AssertionError(f"step {name!r} has no run script")
    return run


def assert_exact_output(label: str, actual: str, expected: list[str]) -> None:
    rendered = "\n".join(expected) + "\n"
    if actual == rendered:
        return
    note = ""
    if "Preparing" in actual or "9e318e74be6d:" in actual:
        note = "docker progress leaked into GITHUB_OUTPUT (multi-line output)\n"
    raise AssertionError(
        f"{label}: GITHUB_OUTPUT is not exactly the single-line image refs\n"
        f"{note}"
        f"--- expected ---\n{rendered}"
        f"--- actual ---\n{actual}"
        f"--- end ---"
    )


def execute_image_step(script: str, *, push_fail: bool) -> tuple[int, str, str, str, dict[str, str]]:
    arms = "\n".join(
        f'      {name}) digest="{digest}" ;;'
        for name, digest in IMAGE_DIGESTS.items()
    )
    with tempfile.TemporaryDirectory(prefix="runtime-deploy-image-") as directory_name:
        directory = pathlib.Path(directory_name)
        bin_dir = directory / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "docker"
        stub.write_text(DOCKER_STUB.replace("__DIGEST_ARMS__", arms))
        stub.chmod(0o755)
        logs = directory / "logs"
        logs.mkdir()
        output = directory / "github_output"
        output.write_text("")
        # The workflow hard-codes /tmp/*.log. Remap only the executed copy so parallel runs do not collide.
        isolated = script.replace("/tmp/", f"{logs}/")
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH', '')}"
        env["AR_REGION"] = "us-central1"
        env["PROJECT_ID"] = "hop-mesh"
        env["DEPLOY_SHA"] = DEPLOY_SHA
        env["GITHUB_OUTPUT"] = str(output)
        env.pop("DOCKER_PUSH_FAIL", None)
        if push_fail:
            env["DOCKER_PUSH_FAIL"] = "1"
        result = subprocess.run(
            ["bash", "-c", isolated],
            env=env,
            cwd=directory,
            capture_output=True,
            text=True,
        )
        captured = {
            path.name: path.read_text(encoding="utf-8", errors="replace")
            for path in logs.iterdir()
            if path.is_file()
        }
        return result.returncode, output.read_text(encoding="utf-8"), result.stdout, result.stderr, captured


probe = subprocess.run(["bash", "-c", "shopt -s inherit_errexit"], capture_output=True, text=True)
if probe.returncode != 0:
    raise AssertionError(f"bash on PATH cannot inherit_errexit: {probe.stderr}")
if len(DEPLOY_SHA) != 40 or any(char not in "0123456789abcdef" for char in DEPLOY_SHA):
    raise AssertionError(f"DEPLOY_SHA must be 40 hex chars, got {DEPLOY_SHA!r}")

workflow_path = root / ".github/workflows/runtime-deploy.yml"
public_run = step_run(workflow_path, PUBLIC_STEP)
private_run = step_run(workflow_path, PRIVATE_STEP)

code, output, _stdout, stderr, _logs = execute_image_step(public_run, push_fail=False)
if code != 0:
    raise AssertionError(f"public image step failed on a successful push\nstdout:\n{_stdout}\nstderr:\n{stderr}")
assert_exact_output(
    "public images",
    output,
    [f"relay={image_ref('hop-relayd')}", f"example={image_ref('hop-example')}"],
)
if "9e318e74be6d: Preparing" not in stderr or "9e318e74be6d: Pushed" not in stderr:
    raise AssertionError(f"public image progress was silenced; it must stay on stderr\nstderr:\n{stderr}")
passed += 1
print("ok   [public image refs are single-line and progress stays visible]")

code, output, _stdout, stderr, _logs = execute_image_step(private_run, push_fail=False)
if code != 0:
    raise AssertionError(f"private image step failed on a successful push\nstdout:\n{_stdout}\nstderr:\n{stderr}")
assert_exact_output(
    "private images",
    output,
    [f"accountd={image_ref('hop-accountd')}", f"console={image_ref('hop-console')}"],
)
if "Preparing" in stderr or "digest:" in stderr or "Successfully tagged" in stderr:
    raise AssertionError(f"private image step leaked build output\nstderr:\n{stderr}")
passed += 1
print("ok   [private image refs are single-line and output stays withheld]")

code, output, _stdout, stderr, logs = execute_image_step(public_run, push_fail=True)
push_ran = "9e318e74be6d: Preparing" in logs.get("relay-push.log", "") or "9e318e74be6d: Preparing" in stderr
if not push_ran:
    raise AssertionError(
        "public push-fail case did not run docker push; non-zero exit would not prove the failure path\n"
        f"stderr:\n{stderr}\nlogs:{sorted(logs)}"
    )
if code == 0 or "relay=" in output or "example=" in output:
    raise AssertionError(
        "public image step must exit non-zero and write no relay= or example= line when docker push fails\n"
        f"exit={code}\nGITHUB_OUTPUT:\n{output}\nstderr:\n{stderr}"
    )
passed += 1
print("ok   [public image step fails closed when docker push fails]")

print(f"runtime deploy guard tests passed: {passed}")
PY
