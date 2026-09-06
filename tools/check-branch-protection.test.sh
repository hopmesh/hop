#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
guard="$root/tools/check-branch-protection.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"

# The guard makes calls to: the protection endpoint, the repo endpoint for allow_auto_merge,
# and the environment endpoints for deployment_branch_policy.
# The stub dispatches on URL instead of returning one body for everything. It exits 97 on an
# unrecognized URL, proving the guard talks to the intended endpoints.
cat > "$tmp/bin/curl" <<'SH'
#!/usr/bin/env sh
protection="https://api.github.com/repos/hopmesh/hop/branches/main/protection"
repo="https://api.github.com/repos/hopmesh/hop"
pages="https://api.github.com/repos/hopmesh/hop/pages"
target=""
for argument in "$@"; do
  case "$argument" in
    "$protection") target=protection ;;
    "$repo") target=repo ;;
    "$pages") target=pages ;;
    https://api.github.com/repos/hopmesh/hop/environments/*) target=env ;;
  esac
done
repo_body="${FAKE_REPO_BODY:-}"
[ -n "$repo_body" ] || repo_body='{"allow_auto_merge": true}'
pages_body="${FAKE_PAGES_BODY:-}"
[ -n "$pages_body" ] || pages_body='{"cname":"hopme.sh","protected_domain_state":"verified"}'
env_body="${FAKE_ENV_BODY:-}"
[ -n "$env_body" ] || env_body='{"protection_rules":[{"type":"branch_policy"}],"deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}'
case "$target" in
  protection) printf '%s\n%s\n' "$FAKE_BODY" "${FAKE_CODE:-200}" ;;
  repo) printf '%s\n%s\n' "$repo_body" "${FAKE_REPO_CODE:-200}" ;;
  pages) printf '%s\n%s\n' "$pages_body" "${FAKE_PAGES_CODE:-200}" ;;
  env) printf '%s\n%s\n' "$env_body" "${FAKE_ENV_CODE:-200}" ;;
  *) exit 97 ;;
esac
SH
chmod +x "$tmp/bin/curl"

run_case() {
  label="$1"
  expected="$2"
  body="$3"
  if output="$(PATH="$tmp/bin:$PATH" GH_TOKEN=test FAKE_BODY="$body" \
      FAKE_REPO_BODY="${CASE_REPO_BODY:-}" FAKE_REPO_CODE="${CASE_REPO_CODE:-}" \
      FAKE_PAGES_BODY="${CASE_PAGES_BODY:-}" FAKE_PAGES_CODE="${CASE_PAGES_CODE:-}" \
      FAKE_ENV_BODY="${CASE_ENV_BODY:-}" FAKE_ENV_CODE="${CASE_ENV_CODE:-}" bash "$guard" 2>&1)"; then
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

good='{"required_status_checks":{"strict":true,"checks":[{"context":"CI gate"}]},"enforce_admins":{"enabled":true},"required_pull_request_reviews":{"required_approving_review_count":0}}'

run_case exact pass "$good"
run_case stale-extra fail '{"required_status_checks":{"strict":true,"checks":[{"context":"CI gate"},{"context":"Stale check"}]},"enforce_admins":{"enabled":true}}'
run_case missing-gate fail '{"required_status_checks":{"strict":true,"checks":[{"context":"Other check"}]},"enforce_admins":{"enabled":true}}'
run_case strict-false fail '{"required_status_checks":{"strict":false,"checks":[{"context":"CI gate"}]},"enforce_admins":{"enabled":true}}'
run_case strict-missing fail '{"required_status_checks":{"checks":[{"context":"CI gate"}]},"enforce_admins":{"enabled":true}}'
run_case strict-non-boolean fail '{"required_status_checks":{"strict":"yes","checks":[{"context":"CI gate"}]},"enforce_admins":{"enabled":true}}'
run_case enforce-admins-false fail '{"required_status_checks":{"strict":true,"checks":[{"context":"CI gate"}]},"enforce_admins":{"enabled":false}}'
run_case enforce-admins-missing fail '{"required_status_checks":{"strict":true,"checks":[{"context":"CI gate"}]}}'
# INFRA-022: main branch protection must require pull request reviews or lock the branch against direct pushes.
run_case no-pr-reviews fail '{"required_status_checks":{"strict":true,"checks":[{"context":"CI gate"}]},"enforce_admins":{"enabled":true}}'
run_case pr-reviews-null fail '{"required_status_checks":{"strict":true,"checks":[{"context":"CI gate"}]},"enforce_admins":{"enabled":true},"required_pull_request_reviews":null}'
run_case lock-branch-pass pass '{"required_status_checks":{"strict":true,"checks":[{"context":"CI gate"}]},"enforce_admins":{"enabled":true},"lock_branch":{"enabled":true}}'

# allow_auto_merge is live repo config that no repo file can hold, exactly like the protection rule.
# hopmesh/hop shipped with it OFF and every pr-automerge run failed with "Auto merge is not allowed for
# this repository" while the required CI gate stayed green. Protection being correct must NOT be enough
# to pass, or the guard would have kept reporting green through that.
CASE_REPO_BODY='{"allow_auto_merge": false}' run_case auto-merge-disabled fail "$good"
CASE_REPO_BODY='{}'                          run_case auto-merge-absent   fail "$good"
CASE_REPO_BODY='{"allow_auto_merge": true}'  run_case auto-merge-enabled  pass "$good"
# Unable to READ the setting is an unknown, never a pass, matching the protection branches above.
CASE_REPO_CODE=500 CASE_REPO_BODY='{}'       run_case auto-merge-api-error fail "$good"


# Environment deployment branch policy tests.
# Environments (component-sync, release, github-pages) must have deployment_branch_policy with
# protected_branches: true. Test that the prior unconfigured live state fails.
CASE_ENV_BODY='{"protection_rules":[],"deployment_branch_policy":null}' run_case env-unprotected fail "$good"
CASE_ENV_BODY='{"protection_rules":[],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":false}}' run_case env-branches-unprotected fail "$good"
CASE_ENV_CODE=404 run_case env-missing fail "$good"
CASE_ENV_CODE=500 run_case env-api-error fail "$good"

# INFRA-021: Pages custom domain must have protected_domain_state == "verified" to prevent domain takeover.
CASE_PAGES_BODY='{"cname":"hopme.sh","protected_domain_state":"unverified"}' run_case pages-unverified fail "$good"
CASE_PAGES_BODY='{"cname":"hopme.sh","protected_domain_state":"verified"}'   run_case pages-verified   pass "$good"
CASE_PAGES_CODE=404 CASE_PAGES_BODY='{}'                                     run_case pages-404-ok     pass "$good"
CASE_PAGES_CODE=500 CASE_PAGES_BODY='{}'                                     run_case pages-api-error  fail "$good"
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
