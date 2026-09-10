#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/tools/private-source-pin.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
expect() {
  local want="$1" label="$2"
  shift 2
  local rc=0 out
  out="$("$@" 2>&1)" || rc=$?
  if { [ "$want" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$want" = fail ] && [ "$rc" -ne 0 ]; }; then
    pass=$((pass + 1))
  else
    echo "FAIL $label: expected $want, exit=$rc" >&2
    echo "$out" >&2
    fail=$((fail + 1))
  fi
}

valid="$TMP/valid.lock"
printf '%s\n' '{"repository":"hopmesh/platform","commit":"0123456789abcdef0123456789abcdef01234567"}' > "$valid"
expect pass valid_lock python3 "$CHECK" verify-lock --lock "$valid"
[ "$(python3 "$CHECK" get --lock "$valid" repository)" = "hopmesh/platform" ] || { echo "FAIL repository get" >&2; exit 1; }
[ "$(python3 "$CHECK" get --lock "$valid" commit)" = "0123456789abcdef0123456789abcdef01234567" ] || { echo "FAIL commit get" >&2; exit 1; }

bad() {
  local name="$1" body="$2"
  printf '%s\n' "$body" > "$TMP/$name.lock"
  expect fail "$name" python3 "$CHECK" verify-lock --lock "$TMP/$name.lock"
}
bad short '{"repository":"hopmesh/platform","commit":"0123456"}'
bad branch '{"repository":"hopmesh/platform","commit":"main"}'
bad uppercase '{"repository":"hopmesh/platform","commit":"0123456789ABCDEF0123456789ABCDEF01234567"}'
bad wrong_repo '{"repository":"hopmesh/legacy","commit":"0123456789abcdef0123456789abcdef01234567"}'
bad extra_field '{"repository":"hopmesh/platform","commit":"0123456789abcdef0123456789abcdef01234567","ref":"main"}'
bad whitespace_value '{"repository":" hopmesh/platform","commit":"0123456789abcdef0123456789abcdef01234567"}'
ln -s "$valid" "$TMP/link.lock"
expect fail lock_symlink python3 "$CHECK" verify-lock --lock "$TMP/link.lock"
bad duplicate_repository '{"repository":"hopmesh/platform","repository":"hopmesh/platform","commit":"0123456789abcdef0123456789abcdef01234567"}'
bad duplicate_commit '{"repository":"hopmesh/platform","commit":"0123456789abcdef0123456789abcdef01234567","commit":"0123456789abcdef0123456789abcdef01234567"}'
bad reversed_keys '{"commit":"0123456789abcdef0123456789abcdef01234567","repository":"hopmesh/platform"}'
bad pretty_json '{ "repository": "hopmesh/platform", "commit": "0123456789abcdef0123456789abcdef01234567" }'
printf ' {"repository":"hopmesh/platform","commit":"0123456789abcdef0123456789abcdef01234567"}\n' > "$TMP/leading-space.lock"
expect fail leading_space python3 "$CHECK" verify-lock --lock "$TMP/leading-space.lock"
printf '{"repository":"hopmesh/platform","commit":"0123456789abcdef0123456789abcdef01234567"}\n\n' > "$TMP/trailing-blank.lock"
expect fail trailing_blank python3 "$CHECK" verify-lock --lock "$TMP/trailing-blank.lock"
printf '{"repository":"hopmesh/platform","commit":"0123456789abcdef0123456789abcdef01234567"}\r\n' > "$TMP/crlf.lock"
expect fail crlf python3 "$CHECK" verify-lock --lock "$TMP/crlf.lock"

checkout="$TMP/platform"
git init -q "$checkout"
git -C "$checkout" config user.name test
git -C "$checkout" config user.email test@example.invalid
git -C "$checkout" config commit.gpgsign false
mkdir -p "$checkout/tools"
printf 'pass\n' > "$checkout/tools/stage-commercial-source.py"
printf 'services/hop-accountd/Cargo.toml\n' > "$checkout/tools/commercial-source-manifest.txt"
git -C "$checkout" add .
git -C "$checkout" commit -q -m fixture
git -C "$checkout" remote add origin https://github.com/hopmesh/platform.git
head="$(git -C "$checkout" rev-parse HEAD)"
printf '%s\n' "{\"repository\":\"hopmesh/platform\",\"commit\":\"$head\"}" > "$TMP/checkout.lock"
expect pass exact_checkout python3 "$CHECK" verify-checkout --lock "$TMP/checkout.lock" --checkout "$checkout"

printf 'dirty\n' > "$checkout/untracked"
expect fail dirty_checkout python3 "$CHECK" verify-checkout --lock "$TMP/checkout.lock" --checkout "$checkout"
rm "$checkout/untracked"
git -C "$checkout" remote set-url origin https://github.com/hopmesh/legacy.git
expect fail wrong_remote python3 "$CHECK" verify-checkout --lock "$TMP/checkout.lock" --checkout "$checkout"
git -C "$checkout" remote set-url origin https://github.com/hopmesh/platform.git
rm "$checkout/tools/commercial-source-manifest.txt"
ln -s /etc/hosts "$checkout/tools/commercial-source-manifest.txt"
expect fail contract_symlink python3 "$CHECK" verify-checkout --lock "$TMP/checkout.lock" --checkout "$checkout"

if [ "$fail" -ne 0 ]; then
  echo "private-source-pin.test.sh: $fail failed, $pass passed" >&2
  exit 1
fi
echo "private-source-pin.test.sh: $pass passed, 0 failed"
