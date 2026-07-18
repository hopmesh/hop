#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$root/tools/release-artifact.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

export GITHUB_REPOSITORY=hopmesh/example
export GITHUB_SHA=1111111111111111111111111111111111111111
export GITHUB_REF=refs/tags/v1.2.3
export GITHUB_RUN_ID=42
export GITHUB_RUN_ATTEMPT=2
canonical=2222222222222222222222222222222222222222

mkdir "$tmp/good"
printf 'package bytes\n' > "$tmp/good/package.tgz"
python3 "$helper" create --directory "$tmp/good" --canonical-source-sha "$canonical" >/dev/null
python3 "$helper" verify --directory "$tmp/good" --canonical-source-sha "$canonical" >/dev/null

expect_bad() {
  name="$1"
  shift
  cp -R "$tmp/good" "$tmp/$name"
  "$@"
  if python3 "$helper" verify --directory "$tmp/$name" --canonical-source-sha "$canonical" >/dev/null 2>&1; then
    echo "release artifact verifier accepted: $name" >&2
    exit 1
  fi
}

expect_bad changed sh -c "printf forged > '$tmp/changed/package.tgz'"
expect_bad extra sh -c "printf extra > '$tmp/extra/unlisted'"
expect_bad missing rm "$tmp/missing/package.tgz"
expect_bad nested-manifest sh -c "mkdir '$tmp/nested-manifest/nested' && printf forged > '$tmp/nested-manifest/nested/release-manifest.json'"
mkdir "$tmp/outside"
expect_bad directory-symlink ln -s "$tmp/outside" "$tmp/directory-symlink/linked-dir"
expect_bad manifest-symlink sh -c "rm '$tmp/manifest-symlink/release-manifest.json' && ln -s '$tmp/good/release-manifest.json' '$tmp/manifest-symlink/release-manifest.json'"

cp -R "$tmp/good" "$tmp/source-mismatch"
if python3 "$helper" verify --directory "$tmp/source-mismatch" \
  --canonical-source-sha 3333333333333333333333333333333333333333 >/dev/null 2>&1; then
  echo "release artifact verifier accepted a different canonical source" >&2
  exit 1
fi

echo "release artifact tests passed"
