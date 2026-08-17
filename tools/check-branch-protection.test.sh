#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/tools/check-branch-protection.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"

# The guard makes TWO calls now: the protection endpoint, then the repo endpoint for allow_auto_merge.
# So the stub dispatches on URL instead of returning one body for everything. It still exits 97 on an
# unrecognized URL, which is what proves the guard is talking to the repository the test intends.
cat > "$tmp/bin/curl" <<'SH'
#!/usr/bin/env sh
protection="https://api.github.com/repos/hopmesh/hop/branches/main/protection"
repo="https://api.github.com/repos/hopmesh/hop"
target=""
for argument in "$@"; do
  case "$argument" in
    "$protection") target=protection ;;
    "$repo") target=repo ;;
  esac
done
repo_body="${FAKE_REPO_BODY:-}"
[ -n "$repo_body" ] || repo_body='{"allow_auto_merge": true}'
case "$target" in
  protection) printf '%s\n%s\n' "$FAKE_BODY" "${FAKE_CODE:-200}" ;;
  repo) printf '%s\n%s\n' "$repo_body" "${FAKE_REPO_CODE:-200}" ;;
  *) exit 97 ;;
esac
SH
chmod +x "$tmp/bin/curl"

run_case() {
  label="$1"
  expected="$2"
  body="$3"
  if output="$(PATH="$tmp/bin:$PATH" GH_TOKEN=test FAKE_BODY="$body" \
      FAKE_REPO_BODY="${CASE_REPO_BODY:-}" FAKE_REPO_CODE="${CASE_REPO_CODE:-}" bash "$guard" 2>&1)"; then
    actual=pass
  else
    actual=fail
  fi
  if [ "$actual" != "$expected" ]; then
    printf 'branch-protection case %s: expected %s, got %s\n%s\n' \
      "$label" "$expected" "$actual" "$output" >&2
    exit 1
  fi
}

good='{"required_status_checks":{"checks":[{"context":"CI gate"}]}}'

run_case exact pass "$good"
run_case stale-extra fail '{"required_status_checks":{"checks":[{"context":"CI gate"},{"context":"Stale check"}]}}'
run_case missing-gate fail '{"required_status_checks":{"checks":[{"context":"Other check"}]}}'

# allow_auto_merge is live repo config that no repo file can hold, exactly like the protection rule.
# hopmesh/hop shipped with it OFF and every pr-automerge run failed with "Auto merge is not allowed for
# this repository" while the required CI gate stayed green. Protection being correct must NOT be enough
# to pass, or the guard would have kept reporting green through that.
CASE_REPO_BODY='{"allow_auto_merge": false}' run_case auto-merge-disabled fail "$good"
CASE_REPO_BODY='{}'                          run_case auto-merge-absent   fail "$good"
CASE_REPO_BODY='{"allow_auto_merge": true}'  run_case auto-merge-enabled  pass "$good"
# Unable to READ the setting is an unknown, never a pass, matching the protection branches above.
CASE_REPO_CODE=500 CASE_REPO_BODY='{}'       run_case auto-merge-api-error fail "$good"

# The workflow WRAPPER, not just the script. This audit is the only live assertion that main still
# requires the CI gate, and it used to `exit 0` when BRANCH_PROTECTION_TOKEN was absent: deleting one
# secret disarmed the detector and every subsequent run reported green. Inability to read the live rule
# is an unknown, never a pass, so the missing-credential branch must fail. Run the actual step body
# extracted from the workflow with an empty token, and require a non-zero exit.
workflow="$root/.github/workflows/branch-protection-audit.yml"
step="$(python3 - "$workflow" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(
    r"(?ms)^      - name: Assert main branch protection requires the CI checks\n.*?^        run: \|\n(.*?)(?=^      - |\Z)",
    text,
)
if match is None:
    raise SystemExit("branch-protection audit step not found")
print("\n".join(line[10:] for line in match.group(1).splitlines()))
PY
)"
case "$step" in
  *"exit 0"*) echo "branch-protection audit still exits 0 on a missing token" >&2; exit 1 ;;
esac
if (cd "$root" && BP_TOKEN="" bash -c "$step") >/dev/null 2>&1; then
  echo "branch-protection audit PASSED with no token: the drift-detector can be disarmed" >&2
  exit 1
fi

echo "branch protection guard tests passed"
