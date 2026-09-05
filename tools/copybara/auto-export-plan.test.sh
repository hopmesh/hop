#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$root" <<'PY'
import http.server
import importlib.util
import io
import json
import os
import sys
import threading
from contextlib import redirect_stdout
from pathlib import Path

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("plan", root / "tools/copybara/auto-export-plan.py")
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)
components = json.loads((root / "tools/copybara/components.json").read_text())
config = (root / "tools/copybara/copy.bara.sky").read_text()
paths = plan.origin_paths(config, components)

# The trigger set must be a SUPERSET of the export set: every path that travels out in a component's
# export must also be able to fire that export. This is the guard, run against the real config.
assert plan.check_trigger_coverage(components, paths)


def changed(files):
    return sorted(plan.changed_components(files, components, paths))


# changed_components: prefix ownership, including the nested core/hop vs core/hop-core boundary.
# Retargeted by the 2026-08 mirror retirement. The nested core/hop vs core/hop-core boundary and the
# Elixir vendor fan-out are gone with those mirrors, so the cases that pinned them would now assert
# against components that do not exist. What still needs pinning is the same property: a change under a
# prefix exports exactly that component, and a change under no prefix exports nothing.
cases = [
    (["sdk/go/hop.go", "README.md"], ["hop-sdk-go"]),
    (["sdk/crystal/src/hop.cr"], ["hop-sdk-crystal"]),
    (["sdk/apple/Package.swift"], ["hop-sdk-apple"]),
    # A retired prefix must now own nothing rather than silently matching a live component.
    (["core/hop-core/src/lib.rs", "services/hop-relayd/main.rs"], []),
    (["docs/x.md", ".github/workflows/ci.yml", "tools/copybara/dispatch.py"], []),
]
for files, expect in cases:
    got = changed(files)
    assert got == sorted(expect), f"changed_components({files}) = {got}, expected {sorted(expect)}"

# The shared export inputs. Every one of these travels into mirrors that own none of its path, so a
# prefix-only trigger exported NOTHING when they changed: a native signing-key rotation left all four
# native mirrors verifying release bundles against the superseded key until an unrelated commit landed
# under one of their prefixes. These four cases fail against prefix-only detection.
native = ["hop-sdk-apple", "hop-sdk-go"]
assert changed(["tools/native-artifacts-public.pem"]) == sorted(native), "key rotation exports nothing"
assert changed(["tools/native-artifacts.py"]) == sorted(native), "native verifier change exports nothing"
assert changed(["sdk/hop.h"]) == sorted(
    ["hop-sdk-go"]
), "C ABI header change does not reach the mirror that carries it"
assert changed(["tools/release-provenance.py"]) == sorted(components), (
    "the release provenance verifier does not reach all mirrors"
)
assert changed(["tools/release-artifact.py"]) == sorted(components), "release artifact helper misses mirrors"
assert changed(["tools/package-export-smoke.py"]) == sorted(components), "export contract helper misses mirrors"
assert changed(["tools/copybara/components.json"]) == sorted(components), "component map misses mirrors"

# A shared path added to origin_files that the matcher cannot fire on must FAIL the guard, not pass
# silently. Both mutations below model that: an unsupported pattern shape, and a component whose
# origin path the matcher is blind to.
mutated = config.replace(
    '    origin_paths = [\n        prefix + "/**",',
    '    origin_paths = [\n        prefix + "/**",\n        "tools/*.py",',
    1,
)
assert mutated != config, "the origin_paths block anchor moved; this self-test is no longer testing it"
try:
    plan.check_trigger_coverage(components, plan.origin_paths(mutated, components))
except SystemExit as error:
    assert "unsupported origin_files pattern" in str(error), f"wrong rejection: {error}"
else:
    raise AssertionError("guard accepted an origin_files pattern shape the trigger cannot match")

# The historical rule (fire only on the component's own subtree prefix) must FAIL the guard. This is
# the regression: under it, the shared export inputs above travelled out but could not fire an export.
subtree_only = {name: [entry["prefix"] + "/**"] for name, entry in components.items()}
try:
    plan.check_trigger_coverage(components, paths, trigger=subtree_only)
except SystemExit as error:
    assert "would NOT export" in str(error), f"wrong rejection: {error}"
else:
    raise AssertionError("guard accepted a subtree-prefix trigger that misses the shared export inputs")

# preflight rejects anything that is not a push to canonical protected main. Every rejection below is a
# local check that fires before preflight's single API call.
#
# The happy path is asserted FIRST, and that assertion is the point. Without it this block was a check
# that could not fail: when the canonical repository moved from hopmesh/monorepo to hopmesh/hop, `base`
# stopped matching EXPECTED, so every tweak below was still "rejected" but no longer for the reason it
# names, and the suite stayed green while testing nothing. Asserting acceptance pins `base` to a
# genuinely accepted env, which is what makes each rejection attributable to its own tweak.
#
# _api is stubbed so acceptance is checkable offline. It is the only network call preflight makes, and
# it is reached only after every local check has passed, so stubbing it does not weaken the cases here.
calls = []


def _stub_api(path, token):
    calls.append(path)
    return {"object": {"sha": "0" * 40}}


plan._api = _stub_api

base = {
    "REPOSITORY": "hopmesh/hop",
    "EVENT_REPOSITORY": "hopmesh/hop",
    "EVENT_NAME": "push",
    "REF": "refs/heads/main",
    "DEFAULT_BRANCH": "main",
    "REF_PROTECTED": "true",
    "SHA": "0" * 40,
    "GH_TOKEN": "x",
}
try:
    plan.preflight(base)
except SystemExit as error:
    raise AssertionError(f"preflight rejected the canonical push it must accept: {error}")
assert calls, "preflight never reached its API call, so acceptance was not actually proven"

for tweak in (
    {"EVENT_NAME": "workflow_dispatch"},
    {"REF": "refs/heads/dev"},
    {"REF_PROTECTED": "false"},
    {"REPOSITORY": "fork/hop"},
    {"EVENT_REPOSITORY": "fork/hop"},
    {"DEFAULT_BRANCH": "dev"},
    {"SHA": "nothex"},
):
    env = dict(base, **tweak)
    try:
        plan.preflight(env)
    except SystemExit:
        continue
    raise AssertionError(f"preflight accepted a non-canonical push: {tweak}")

# mirror_exists and filter_existing_mirrors: drop 404 destination repos, keep non-404 errors,
# emit notice for skipped components, and preserve any=false semantics when all are dropped.
class _FixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/repos/hopmesh/hop-sdk-go":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"id": 1, "name": "hop-sdk-go"}')
        elif self.path == "/repos/hopmesh/hop-bearers-apple":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'{"message": "Not Found"}')
        elif self.path == "/repos/hopmesh/hop-rate-limited":
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b'{"message": "API rate limit exceeded"}')
        elif self.path == "/repos/hopmesh/hop-server-error":
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'{"message": "Internal Server Error"}')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


fixture_server = http.server.HTTPServer(("127.0.0.1", 0), _FixtureHandler)
server_thread = threading.Thread(target=fixture_server.serve_forever)
server_thread.daemon = True
server_thread.start()

prev_api_url = os.environ.get("GITHUB_API_URL")
try:
    os.environ["GITHUB_API_URL"] = f"http://127.0.0.1:{fixture_server.server_port}"

    # 1. mirror_exists unit behavior
    assert plan.mirror_exists("hop-sdk-go", token="test-tok") is True
    assert plan.mirror_exists("hop-bearers-apple", token="test-tok") is False
    # Non-404 errors (403 rate limit, 500 server error) must return None (not False)
    assert plan.mirror_exists("hop-rate-limited", token="test-tok") is None
    assert plan.mirror_exists("hop-server-error", token="test-tok") is None
    # Unauthenticated request succeeds when endpoint returns 200
    assert plan.mirror_exists("hop-sdk-go", token=None) is True

    # 2. filter_existing_mirrors drops 404, keeps 200 and non-404 errors, emits notice
    stdout_buf = io.StringIO()
    components_to_check = [
        "hop-sdk-go",
        "hop-bearers-apple",
        "hop-rate-limited",
        "hop-server-error",
    ]
    with redirect_stdout(stdout_buf):
        kept = plan.filter_existing_mirrors(components_to_check, token="test-tok")

    assert kept == ["hop-sdk-go", "hop-rate-limited", "hop-server-error"], (
        f"filter_existing_mirrors kept wrong set: {kept}"
    )
    expected_notice = (
        "::notice::auto-export: skipping hop-bearers-apple: repository "
        "hopmesh/hop-bearers-apple does not exist (create it per tools/copybara/bootstrap-mirrors.sh)\n"
    )
    assert stdout_buf.getvalue() == expected_notice, (
        f"unexpected notice output: {stdout_buf.getvalue()!r}"
    )

    # 3. All components 404: drops all, returns empty list (which yields any=false)
    stdout_buf = io.StringIO()
    with redirect_stdout(stdout_buf):
        all_dropped = plan.filter_existing_mirrors(["hop-bearers-apple"], token="test-tok")
    assert all_dropped == [], f"expected empty list, got: {all_dropped}"
    assert stdout_buf.getvalue() == expected_notice

    # 4. Function override pattern
    old_mirror_exists = plan.mirror_exists
    try:
        plan.mirror_exists = lambda c, t=None: False if c == "absent" else (None if c == "flaky" else True)
        stdout_buf = io.StringIO()
        with redirect_stdout(stdout_buf):
            res = plan.filter_existing_mirrors(["present", "absent", "flaky"])
        assert res == ["present", "flaky"]
        assert (
            "::notice::auto-export: skipping absent: repository hopmesh/absent does not exist"
            in stdout_buf.getvalue()
        )
    finally:
        plan.mirror_exists = old_mirror_exists
finally:
    fixture_server.shutdown()
    fixture_server.server_close()
    if prev_api_url is not None:
        os.environ["GITHUB_API_URL"] = prev_api_url
    else:
        os.environ.pop("GITHUB_API_URL", None)
print("auto-export plan tests passed")
PY
