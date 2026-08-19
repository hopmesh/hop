#!/usr/bin/env bash
# Self-test the Apple pod trunk publisher.
#
# The publisher exists because `pod trunk push` cannot be trusted on its own, so this test's job is to
# prove the distrust is real: every check here must be able to FAIL, and each negative case asserts the
# specific message rather than just a nonzero exit, so a check that starts rejecting everything for the
# wrong reason still reddens.
#
# Nothing here touches the network or the real registry. A loopback HTTP server stands in for trunk and
# the CDN through the same TRUNK_SCHEME_AND_HOST override cocoapods-trunk itself reads, and a fake `pod`
# on PATH records its arguments, so the ORDER of the pushes and the flags they carry are observable.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
publisher="$here/trunk-publish.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; [ -n "${server_pid:-}" ] && kill "$server_pid" 2>/dev/null || true' EXIT

test -x "$publisher" || { echo "publisher is not executable: $publisher" >&2; exit 1; }

# ---- the stand-in registry -------------------------------------------------------------------------
# State lives in files so both the server and the fake pod can mutate it. published/<Pod> holds one
# version per line; cdn/<Pod> the same for the propagation surface, so a push that lands on trunk but
# has not reached the CDN is representable, which is the exact condition await_cdn exists for.
mkdir -p "$tmp/published" "$tmp/cdn" "$tmp/bin" "$tmp/pods"
cat >"$tmp/registry.py" <<'PY'
import http.server, os, pathlib, json, sys

ROOT = pathlib.Path(os.environ["FIXTURE_ROOT"])


def versions(kind, pod):
    path = ROOT / kind / pod
    if not path.exists():
        return []
    return [line for line in path.read_text().split() if line]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if (ROOT / "fail-registry").exists() and "/api/v1/pods/" in self.path:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'{"error":"registry is down"}')
            return
        if self.path.startswith("/api/v1/pods/"):
            pod = self.path.rsplit("/", 1)[1]
            live = versions("published", pod)
            if not live:
                self.send_response(404)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"error":"No pod found with the specified name."}')
                return
            body = json.dumps({"versions": [{"name": v} for v in live]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/Specs/"):
            parts = self.path.split("/")
            pod, version = parts[-3], parts[-2]
            if version in versions("cdn", pod):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")
            else:
                self.send_response(404)
                self.end_headers()
            return
        self.send_response(404)
        self.end_headers()


port = int(sys.argv[1])
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
FIXTURE_ROOT="$tmp" python3 "$tmp/registry.py" "$port" &
server_pid=$!
for _ in $(seq 1 50); do
  if python3 -c "import socket,sys; s=socket.socket(); sys.exit(s.connect_ex(('127.0.0.1',$port)))" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
python3 -c "import socket,sys; s=socket.socket(); sys.exit(s.connect_ex(('127.0.0.1',$port)))" \
  || { echo "fixture registry never came up on port $port" >&2; exit 1; }

export TRUNK_SCHEME_AND_HOST="http://127.0.0.1:$port"
export COCOAPODS_CDN_HOST="http://127.0.0.1:$port"

# ---- the stand-in CLI ------------------------------------------------------------------------------
# Appends its argv to calls.log, then either records the push or fails the way the real CLI fails.
cat >"$tmp/bin/pod" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FIXTURE_ROOT/calls.log"
spec="${3%.podspec}"
version="$(cat "$FIXTURE_ROOT/version")"
if [ -f "$FIXTURE_ROOT/lint-fails" ]; then
  echo "[!] The spec did not pass validation, due to 1 error."
  exit 1
fi
if grep -qx "$version" "$FIXTURE_ROOT/published/$spec" 2>/dev/null; then
  echo "[!] Unable to accept duplicate entry for: $spec ($version)"
  exit 1
fi
# The real race the publisher tolerates: another actor lands the version between our pre-check and our
# push, so the registry answers "absent" first and the CLI then reports a duplicate for a version that
# genuinely IS published. Model it faithfully, registry state included.
if [ -f "$FIXTURE_ROOT/race-duplicate" ]; then
  echo "$version" >>"$FIXTURE_ROOT/published/$spec"
  echo "$version" >>"$FIXTURE_ROOT/cdn/$spec"
  echo "[!] Unable to accept duplicate entry for: $spec ($version)"
  exit 1
fi
echo "$version" >>"$FIXTURE_ROOT/published/$spec"
if [ ! -f "$FIXTURE_ROOT/withhold-cdn" ]; then
  echo "$version" >>"$FIXTURE_ROOT/cdn/$spec"
fi
echo " 🚀  $spec ($version) successfully published"
SH
chmod +x "$tmp/bin/pod"
export PATH="$tmp/bin:$PATH"
export FIXTURE_ROOT="$tmp"

# ---- the stand-in checkout -------------------------------------------------------------------------
printf '0.0.7\n' >"$tmp/version"
for pod in CHop HopContract HopSDK; do
  printf 'Pod::Spec.new\n' >"$tmp/pods/$pod.podspec"
done
cat >"$tmp/pods/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
.binaryTarget(
  name: "CHop",
  url: "https://github.com/hopmesh/hop-sdk-apple/releases/download/v0.0.7/libhop.xcframework.zip",
  checksum: "080ca47a257f68c42e991aa4632ce6960705bc7880b8a335e215c133d8c688fd"
)
SWIFT

reset_state() {
  rm -f "$tmp/calls.log" "$tmp/lint-fails" "$tmp/withhold-cdn" "$tmp/fail-registry" "$tmp/race-duplicate"
  rm -f "$tmp/published"/* "$tmp/cdn"/*
}

run_publisher() {
  python3 "$publisher" publish --directory "$tmp/pods" --cdn-attempts 2 --cdn-delay 0 "$@" \
    >"$tmp/out.log" 2>&1
}

expect_fail() {
  local label="$1" needle="$2"
  shift 2
  if run_publisher "$@"; then
    echo "FAIL [$label]: publisher exited 0, it had to fail" >&2
    cat "$tmp/out.log" >&2
    exit 1
  fi
  if ! grep -qF "$needle" "$tmp/out.log"; then
    echo "FAIL [$label]: output does not name \"$needle\"" >&2
    cat "$tmp/out.log" >&2
    exit 1
  fi
  echo "ok   [$label] fails and names the cause"
}

expect_pass() {
  local label="$1"
  shift
  if ! run_publisher "$@"; then
    echo "FAIL [$label]: publisher exited nonzero" >&2
    cat "$tmp/out.log" >&2
    exit 1
  fi
  echo "ok   [$label]"
}

# 1. An absent credential must fail NAMING itself, never skip. This is the whole point of the step.
reset_state
COCOAPODS_TRUNK_TOKEN="" expect_fail "absent token" "COCOAPODS_TRUNK_TOKEN is not set"
reset_state
env -u COCOAPODS_TRUNK_TOKEN bash -c "
  python3 '$publisher' publish --directory '$tmp/pods' >'$tmp/out.log' 2>&1
" && { echo "FAIL: unset token exited 0" >&2; exit 1; }
grep -qF "COCOAPODS_TRUNK_TOKEN is not set" "$tmp/out.log" \
  || { echo "FAIL: unset token did not name the secret" >&2; cat "$tmp/out.log" >&2; exit 1; }
test ! -f "$tmp/calls.log" \
  || { echo "FAIL: publisher invoked pod despite having no credential" >&2; exit 1; }
echo "ok   [unset token] fails, names the secret, and never invokes pod"

export COCOAPODS_TRUNK_TOKEN="fixture-token"

# 2. A tag that disagrees with the podspec version must fail rather than publish the wrong version at it.
reset_state
expect_fail "version mismatch" "but this release is 0.0.9" --expect-version 0.0.9
test ! -f "$tmp/calls.log" || { echo "FAIL: pushed despite a version mismatch" >&2; exit 1; }

# 3. Happy path: three pushes, in dependency order, and the dependent one synchronised.
reset_state
expect_pass "clean publish" --expect-version 0.0.7
mapfile -t calls <"$tmp/calls.log"
test "${#calls[@]}" -eq 3 || { echo "FAIL: expected 3 pushes, saw ${#calls[@]}" >&2; exit 1; }
[[ "${calls[0]}" == "trunk push CHop.podspec --verbose" ]] \
  || { echo "FAIL: first push was '${calls[0]}'" >&2; exit 1; }
[[ "${calls[1]}" == "trunk push HopContract.podspec --verbose --synchronous" ]] \
  || { echo "FAIL: second push was '${calls[1]}'" >&2; exit 1; }
[[ "${calls[2]}" == "trunk push HopSDK.podspec --verbose --synchronous" ]] \
  || { echo "FAIL: third push was '${calls[2]}'" >&2; exit 1; }
grep -qF -- "--allow-warnings" "$tmp/calls.log" \
  && { echo "FAIL: a push carried --allow-warnings" >&2; exit 1; }
echo "ok   [clean publish] pushed CHop, HopContract, HopSDK in that order, dependents synchronised"

# 4. Re-running a released tag is a no-op, not a failure and not a second push. Registry and CDN state
#    carry over from case 3 on purpose; only the call log is cleared, so a new push is observable.
rm -f "$tmp/calls.log"
expect_pass "rerun of a published tag" --expect-version 0.0.7
test ! -f "$tmp/calls.log" || { echo "FAIL: rerun pushed again instead of detecting the version" >&2; exit 1; }
test "$(grep -cF "already on trunk, nothing to push" "$tmp/out.log")" -eq 3 \
  || { echo "FAIL: rerun did not report all three versions as already published" >&2; exit 1; }
echo "ok   [rerun] detected all three versions and pushed nothing"

# 5. The one tolerated error: the registry answers "absent", then another actor lands the version and
#    the CLI reports a duplicate. That means the work is done, so the run continues and succeeds.
reset_state
touch "$tmp/race-duplicate"
expect_pass "duplicate reported by the CLI" --expect-version 0.0.7
test "$(wc -l <"$tmp/calls.log")" -eq 3 \
  || { echo "FAIL: the race case did not attempt all three pushes" >&2; exit 1; }
test "$(grep -cF "was already on trunk (registry reported a duplicate entry)" "$tmp/out.log")" -eq 3 \
  || { echo "FAIL: a duplicate was not recognised as already published" >&2; exit 1; }
echo "ok   [duplicate race] tolerated the duplicate and verified each version against the registry"

# 6. A lint failure is NOT a duplicate and must stay fatal.
reset_state
touch "$tmp/lint-fails"
expect_fail "lint failure" "pod trunk push failed for CHop"

# 7. A registry that never shows the version must fail rather than report a publish that did not land.
reset_state
cat >"$tmp/bin/pod" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FIXTURE_ROOT/calls.log"
echo " 🚀  successfully published"
SH
chmod +x "$tmp/bin/pod"
expect_fail "silent no-op push" "is still absent from the registry after the push reported success"
cat >"$tmp/bin/pod" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FIXTURE_ROOT/calls.log"
spec="${3%.podspec}"
version="$(cat "$FIXTURE_ROOT/version")"
if grep -qx "$version" "$FIXTURE_ROOT/published/$spec" 2>/dev/null; then
  echo "[!] Unable to accept duplicate entry for: $spec ($version)"
  exit 1
fi
echo "$version" >>"$FIXTURE_ROOT/published/$spec"
if [ ! -f "$FIXTURE_ROOT/withhold-cdn" ]; then
  echo "$version" >>"$FIXTURE_ROOT/cdn/$spec"
fi
echo " 🚀  $spec ($version) successfully published"
SH
chmod +x "$tmp/bin/pod"

# 8. A push that lands but never propagates must fail NAMING the CDN, not fall through to the dependent
#    push and die with a misleading "unable to find a specification".
reset_state
touch "$tmp/withhold-cdn"
expect_fail "CDN never propagates" "never became readable from the CDN"
mapfile -t calls <"$tmp/calls.log"
test "${#calls[@]}" -eq 1 \
  || { echo "FAIL: continued past an unpropagated dependency (${#calls[@]} pushes)" >&2; exit 1; }
echo "ok   [CDN stall] stopped after the first push instead of pushing a dependent that cannot resolve"

# 9. A registry that ERRORS must not read as "pod absent". A failed fetch reported as absence is how a
#    publisher talks itself into believing nothing is published.
reset_state
touch "$tmp/fail-registry"
expect_fail "registry error" "registry query failed: HTTP 500"
test ! -f "$tmp/calls.log" || { echo "FAIL: pushed despite an unreadable registry" >&2; exit 1; }

# 10. A missing podspec must fail before anything is pushed.
reset_state
mv "$tmp/pods/HopSDK.podspec" "$tmp/HopSDK.podspec.away"
expect_fail "missing podspec" "missing podspec"
mv "$tmp/HopSDK.podspec.away" "$tmp/pods/HopSDK.podspec"

echo "trunk publisher tests passed"
