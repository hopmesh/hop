#!/usr/bin/env bash
# tools/test-module-inline-guard.test.sh
# Self-test for test-module-inline-guard.sh.
#
# Validates:
#   1. Rejects the real historical collision shape (commits 2d7822be and f4491d8c in hop-core).
#   2. Accepts the per-file shape (#[path = "..."] mod lane_tests;).
#   3. Rejects additive inline test modules in synthetic fixture repos.
#   4. Accepts the first inline test module on a new file.
#   5. Rejects multiple inline test modules introduced on a new file.
#   6. Accepts regular edits/additions inside an existing test module.
#   7. Enforces single-file mode (--file).
#   8. Enforces working-tree mode (--diff).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GUARD="$HERE/test-module-inline-guard.sh"

pass=0
fail=0

record_pass() {
  pass=$((pass + 1))
  echo "  OK: $1"
}

record_fail() {
  fail=$((fail + 1))
  echo "  FAIL: $1" >&2
}

echo "=== Running test-module-inline-guard self-tests ==="

# 1. Real historical shape: commit 2d7822be appended session_arbitration_tests to node.rs
echo "Test 1: Rejects historical commit 2d7822be (appended inline session_arbitration_tests)"
if git -C "$ROOT" cat-file -e 2d7822be^{commit} 2>/dev/null; then
  if bash "$GUARD" "2d7822be^..2d7822be" >/dev/null 2>&1; then
    record_fail "historical commit 2d7822be unexpectedly passed"
  else
    record_pass "historical commit 2d7822be correctly rejected"
  fi
else
  echo "  SKIP: commit 2d7822be not in local object database"
fi

# 2. Real historical shape: commit f4491d8c appended link_desync_tests to node.rs
echo "Test 2: Rejects historical commit f4491d8c (appended inline link_desync_tests)"
if git -C "$ROOT" cat-file -e f4491d8c^{commit} 2>/dev/null; then
  if bash "$GUARD" "f4491d8c^..f4491d8c" >/dev/null 2>&1; then
    record_fail "historical commit f4491d8c unexpectedly passed"
  else
    record_pass "historical commit f4491d8c correctly rejected"
  fi
else
  echo "  SKIP: commit f4491d8c not in local object database"
fi

# Set up isolated fixture repository for synthetic tests
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name "Test Runner"
git -C "$FIXTURE" config user.email "test@hopmesh.internal"
git -C "$FIXTURE" config commit.gpgsign false

# Seed initial commit with a Rust file that has one inline test module
mkdir -p "$FIXTURE/src"
cat <<'EOF' > "$FIXTURE/src/node.rs"
pub struct Node;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_test() {
        assert!(true);
    }
}
EOF
git -C "$FIXTURE" add src/node.rs
git -C "$FIXTURE" commit -q -m "feat: initial node implementation with unit tests"

# 3. Synthetic rejection: adding a second inline test module
echo "Test 3: Synthetic fixture: rejects appending a second inline test module"
git -C "$FIXTURE" checkout -q -b lane-inline
cat <<'EOF' >> "$FIXTURE/src/node.rs"

#[cfg(test)]
mod session_arbitration_tests {
    use super::*;

    #[test]
    fn concurrent_init() {
        assert!(true);
    }
}
EOF
git -C "$FIXTURE" add src/node.rs
git -C "$FIXTURE" commit -q -m "test(core): add concurrent init tests inline"

if (cd "$FIXTURE" && bash "$GUARD" "main..lane-inline") >/dev/null 2>&1; then
  record_fail "additive inline test module unexpectedly passed"
else
  record_pass "additive inline test module correctly rejected"
fi

# 4. Synthetic acceptance: per-file test module convention
echo "Test 4: Synthetic fixture: accepts per-file test module convention"
git -C "$FIXTURE" checkout -q main
git -C "$FIXTURE" checkout -q -b lane-per-file
cat <<'EOF' >> "$FIXTURE/src/node.rs"

#[cfg(test)]
#[path = "node_session_arbitration_tests.rs"]
mod session_arbitration_tests;
EOF

cat <<'EOF' > "$FIXTURE/src/node_session_arbitration_tests.rs"
use super::*;

#[test]
fn concurrent_init_per_file() {
    assert!(true);
}
EOF
git -C "$FIXTURE" add src/node.rs src/node_session_arbitration_tests.rs
git -C "$FIXTURE" commit -q -m "test(core): add concurrent init tests via per-file convention"

if (cd "$FIXTURE" && bash "$GUARD" "main..lane-per-file") >/dev/null 2>&1; then
  record_pass "per-file test module correctly accepted"
else
  record_fail "per-file test module unexpectedly rejected"
fi

# 5. Synthetic acceptance: adding tests inside existing mod tests block
echo "Test 5: Synthetic fixture: accepts additions inside existing test module"
git -C "$FIXTURE" checkout -q main
git -C "$FIXTURE" checkout -q -b lane-internal-test
python3 -c '
path = "'"$FIXTURE"'/src/node.rs"
with open(path, "r") as f:
    content = f.read()
replacement = """    #[test]
    fn second_internal_test() {
        assert!(true);
    }
}"""
content = content.replace("}", replacement, 1)
with open(path, "w") as f:
    f.write(content)
'
git -C "$FIXTURE" add src/node.rs
git -C "$FIXTURE" commit -q -m "test(core): add test inside existing test module"

if (cd "$FIXTURE" && bash "$GUARD" "main..lane-internal-test") >/dev/null 2>&1; then
  record_pass "test added inside existing module correctly accepted"
else
  record_fail "test added inside existing module unexpectedly rejected"
fi

# 6. Synthetic acceptance: single inline test module in new file
echo "Test 6: Synthetic fixture: accepts first inline test module on new file"
git -C "$FIXTURE" checkout -q main
git -C "$FIXTURE" checkout -q -b lane-new-file
cat <<'EOF' > "$FIXTURE/src/util.rs"
pub fn helper() {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helper_works() {}
}
EOF
git -C "$FIXTURE" add src/util.rs
git -C "$FIXTURE" commit -q -m "feat(core): add util with standard unit tests"

if (cd "$FIXTURE" && bash "$GUARD" "main..lane-new-file") >/dev/null 2>&1; then
  record_pass "first inline test module on new file correctly accepted"
else
  record_fail "first inline test module on new file unexpectedly rejected"
fi

# 7. Synthetic rejection: two inline test modules introduced in new file
echo "Test 7: Synthetic fixture: rejects two inline test modules in new file"
git -C "$FIXTURE" checkout -q main
git -C "$FIXTURE" checkout -q -b lane-multi-new
cat <<'EOF' > "$FIXTURE/src/stream.rs"
pub fn stream() {}

#[cfg(test)]
mod tests {
    use super::*;
}

#[cfg(test)]
mod stream_extra_tests {
    use super::*;
}
EOF
git -C "$FIXTURE" add src/stream.rs
git -C "$FIXTURE" commit -q -m "feat(core): add stream with multiple inline test modules"

if (cd "$FIXTURE" && bash "$GUARD" "main..lane-multi-new") >/dev/null 2>&1; then
  record_fail "two inline test modules in new file unexpectedly passed"
else
  record_pass "two inline test modules in new file correctly rejected"
fi

# 8. Single-file inspection mode (--file)
echo "Test 8: Single-file inspection mode (--file)"
cat <<'EOF' > "$TMP/good_single.rs"
pub fn foo() {}
#[cfg(test)]
mod tests {}
EOF

cat <<'EOF' > "$TMP/bad_multi.rs"
pub fn foo() {}
#[cfg(test)]
mod tests {}
#[cfg(test)]
mod extra_tests {}
EOF

if bash "$GUARD" --file "$TMP/good_single.rs" >/dev/null 2>&1; then
  record_pass "--file mode accepts file with single inline test module"
else
  record_fail "--file mode rejected file with single inline test module"
fi

if bash "$GUARD" --file "$TMP/bad_multi.rs" >/dev/null 2>&1; then
  record_fail "--file mode accepted file with multiple inline test modules"
else
  record_pass "--file mode rejects file with multiple inline test modules"
fi

# 9. Working-tree mode (--diff)
echo "Test 9: Working-tree mode (--diff)"
git -C "$FIXTURE" checkout -q main
cat <<'EOF' >> "$FIXTURE/src/node.rs"

#[cfg(test)]
mod uncommitted_tests {
    use super::*;
}
EOF

if (cd "$FIXTURE" && bash "$GUARD" --diff) >/dev/null 2>&1; then
  record_fail "--diff mode accepted uncommitted additive inline module"
else
  record_pass "--diff mode correctly rejected uncommitted additive inline module"
fi

echo ""
echo "=== Self-test results: $pass passed, $fail failed ==="
if [ "$fail" -ne 0 ]; then
  exit 1
fi
exit 0
