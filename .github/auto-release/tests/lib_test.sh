#!/usr/bin/env bash
set -euo pipefail

# lib_test.sh - Unit tests for lib.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/auto-release/lib.sh
source "${SCRIPT_DIR}/../lib.sh"

FAILED=0
TOTAL=0

assert() {
  local desc="$1"
  local cond="$2"
  TOTAL=$(( TOTAL + 1 ))
  if eval "$cond"; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc"
    FAILED=$(( FAILED + 1 ))
  fi
}

# assert_rc <desc> <expected exit code> <command>: run command in a subshell
assert_rc() {
  local desc="$1" want="$2" cmd="$3" rc=0
  TOTAL=$(( TOTAL + 1 ))
  ( eval "$cmd" ) >/dev/null 2>&1 || rc=$?
  if [[ "$rc" == "$want" ]]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (exit $rc, want $want)"
    FAILED=$(( FAILED + 1 ))
  fi
}

# Setup fake gh on PATH
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

mkdir -p "$TEST_TMP/bin"
cat << 'EOF' > "$TEST_TMP/bin/gh"
#!/usr/bin/env bash
echo "FAKE_GH_CALLED: $*"
exit 0
EOF
chmod +x "$TEST_TMP/bin/gh"
ORIG_PATH="$PATH"
export PATH="$TEST_TMP/bin:$ORIG_PATH"

echo "=== Testing is_semver ==="
assert "is_semver valid: 0.1.0" "is_semver '0.1.0'"
assert "is_semver valid: 1.2.3" "is_semver '1.2.3'"
assert "is_semver valid: 10.20.30" "is_semver '10.20.30'"
assert "is_semver invalid: v1.2.3" "! is_semver 'v1.2.3'"
assert "is_semver invalid: 1.2" "! is_semver '1.2'"
assert "is_semver invalid: 1.2.3.4" "! is_semver '1.2.3.4'"
assert "is_semver invalid: 1.2.3-rc1" "! is_semver '1.2.3-rc1'"
assert "is_semver invalid: empty" "! is_semver ''"
assert "is_semver invalid: text" "! is_semver 'foo'"

echo "=== Testing semver_cmp ==="
assert "semver_cmp equal: 1.2.3 vs 1.2.3 -> 0" "[[ \"\$(semver_cmp '1.2.3' '1.2.3')\" == '0' ]]"
assert "semver_cmp minor less: 0.9.0 vs 0.10.0 -> -1" "[[ \"\$(semver_cmp '0.9.0' '0.10.0')\" == '-1' ]]"
assert "semver_cmp minor greater: 0.10.0 vs 0.9.0 -> 1" "[[ \"\$(semver_cmp '0.10.0' '0.9.0')\" == '1' ]]"
assert "semver_cmp patch less: 1.2.3 vs 1.2.4 -> -1" "[[ \"\$(semver_cmp '1.2.3' '1.2.4')\" == '-1' ]]"
assert "semver_cmp patch greater: 1.2.4 vs 1.2.3 -> 1" "[[ \"\$(semver_cmp '1.2.4' '1.2.3')\" == '1' ]]"
assert "semver_cmp major less: 1.9.9 vs 2.0.0 -> -1" "[[ \"\$(semver_cmp '1.9.9' '2.0.0')\" == '-1' ]]"
assert "semver_cmp major greater: 2.0.0 vs 1.9.9 -> 1" "[[ \"\$(semver_cmp '2.0.0' '1.9.9')\" == '1' ]]"
assert_rc "semver_cmp invalid input exits 2" 2 "semver_cmp 'v1.0.0' '1.0.0'"

echo "=== Testing epoch ==="
assert "epoch standard rfc3339" "[[ \"\$(epoch '2026-10-07T00:00:00Z')\" == '1791331200' ]]"
assert "epoch fractional seconds stripped" "[[ \"\$(epoch '2026-10-07T00:00:00.000Z')\" == '1791331200' ]]"
assert_rc "epoch invalid timestamp exits 2" 2 "epoch 'not-a-date'"
assert_rc "epoch empty timestamp exits 2" 2 "epoch ''"

echo "=== Testing iso_now ==="
assert "iso_now honours NOW_OVERRIDE" "NOW_OVERRIDE='2026-10-07T12:00:00Z' && [[ \"\$(iso_now)\" == '2026-10-07T12:00:00Z' ]]"
unset NOW_OVERRIDE || true
assert "iso_now returns UTC format when unset" "[[ \"\$(iso_now)\" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]"

echo "=== Testing ghx write flag refusal ==="
assert "ghx allows GET call" "ghx repos/pivotal-cf/replicator/releases >/dev/null"
assert "ghx allows explicit -X GET" "ghx -X GET repos/pivotal-cf/replicator >/dev/null"
assert "ghx allows explicit --method=GET" "ghx --method=GET repos/pivotal-cf/replicator >/dev/null"
assert_rc "ghx refuses -f" 2 "ghx repos/test -f foo=bar"
assert_rc "ghx refuses -F" 2 "ghx repos/test -F foo=@bar"
assert_rc "ghx refuses --field" 2 "ghx repos/test --field foo=bar"
assert_rc "ghx refuses --raw-field" 2 "ghx repos/test --raw-field foo=bar"
assert_rc "ghx refuses --input" 2 "ghx repos/test --input file.json"
assert_rc "ghx refuses -X POST" 2 "ghx -X POST repos/test"
assert_rc "ghx refuses -XPOST" 2 "ghx -XPOST repos/test"
assert_rc "ghx refuses --method=POST" 2 "ghx --method=POST repos/test"
assert_rc "ghx refuses -X DELETE" 2 "ghx -X DELETE repos/test"
assert_rc "ghx refuses -X PUT" 2 "ghx -X PUT repos/test"
assert_rc "ghx refuses -X PATCH" 2 "ghx -X PATCH repos/test"

echo "=== Testing require_write ==="
assert "require_write succeeds when CLI_RELEASE_WRITE=1" "CLI_RELEASE_WRITE=1 require_write"
assert_rc "require_write fails when CLI_RELEASE_WRITE=0" 2 "CLI_RELEASE_WRITE=0 require_write"
assert_rc "require_write fails when CLI_RELEASE_WRITE unset" 2 "unset CLI_RELEASE_WRITE && require_write"
assert_rc "require_write fails when CLI_RELEASE_WRITE=true" 2 "CLI_RELEASE_WRITE=true require_write"

echo "=== Testing ghx_write allowed endpoints ==="
# Without CLI_RELEASE_WRITE=1, all must fail
assert_rc "ghx_write fails without CLI_RELEASE_WRITE" 2 "CLI_RELEASE_WRITE=0 ghx_write workflow run ci.yml"

# With CLI_RELEASE_WRITE=1
export CLI_RELEASE_WRITE=1
assert "ghx_write allows workflow run" "ghx_write workflow run ci.yml --ref 1.0.0 >/dev/null"
assert "ghx_write allows git/refs POST" "ghx_write repos/pivotal-cf/replicator/git/refs -f ref=refs/tags/1.0.0 >/dev/null"
assert "ghx_write allows issues POST" "ghx_write repos/pivotal-cf/replicator/issues -f title=test >/dev/null"
assert "ghx_write allows issues PATCH" "ghx_write repos/pivotal-cf/replicator/issues/123 -X PATCH -f state=closed >/dev/null"
assert "ghx_write allows issue comments POST" "ghx_write repos/pivotal-cf/replicator/issues/123/comments -f body=msg >/dev/null"
assert "ghx_write allows labels POST" "ghx_write repos/pivotal-cf/replicator/labels -f name=auto-release >/dev/null"
assert "ghx_write allows run cancel POST" "ghx_write repos/pivotal-cf/replicator/actions/runs/456/cancel >/dev/null"

echo "=== Testing ghx_write disallowed endpoints refusal ==="
assert_rc "ghx_write refuses releases endpoint" 2 "ghx_write repos/pivotal-cf/replicator/releases -f tag_name=1.0.0"
assert_rc "ghx_write refuses pulls endpoint" 2 "ghx_write repos/pivotal-cf/replicator/pulls -f title=foo"
assert_rc "ghx_write refuses DELETE method on git/refs" 2 "ghx_write repos/pivotal-cf/replicator/git/refs -X DELETE"
assert_rc "ghx_write refuses unknown endpoint" 2 "ghx_write repos/pivotal-cf/replicator/unknown"

echo "=== Testing summary_append and json_get ==="
SUMMARY_FILE="$TEST_TMP/summary.txt"
export GITHUB_STEP_SUMMARY="$SUMMARY_FILE"
summary_append "hello summary"
assert "summary_append wrote to file" "grep -q 'hello summary' '$SUMMARY_FILE'"

TEST_JSON="$TEST_TMP/data.json"
echo '{"name":"replicator","count":42}' > "$TEST_JSON"
assert "json_get extracts string" "[[ \"\$(json_get \"$TEST_JSON\" '.name')\" == 'replicator' ]]"
assert "json_get extracts number" "[[ \"\$(json_get \"$TEST_JSON\" '.count')\" == '42' ]]"
assert_rc "json_get missing file exits 2" 2 "json_get '$TEST_TMP/missing.json' '.name'"

echo "========================================="
echo "lib_test: $TOTAL tests, $FAILED failed"
if (( FAILED > 0 )); then
  exit 1
fi
exit 0
