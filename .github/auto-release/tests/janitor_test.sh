#!/usr/bin/env bash
set -euo pipefail

# janitor_test.sh - Unit tests for janitor.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JANITOR_SH="${SCRIPT_DIR}/../janitor.sh"

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

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

mkdir -p "$TEST_TMP/bin"
cat << 'EOF' > "$TEST_TMP/bin/gh"
#!/usr/bin/env bash
echo "$*" >> "$TEST_TMP/gh_calls.log"

endpoint=""
is_write=0
for a in "$@"; do
  if [[ "$a" == "-f" || "$a" == "-F" || "$a" == "-X" || "$a" =~ ^--field || "$a" =~ ^-X ]]; then
    is_write=1
  fi
  if [[ "$a" =~ ^repos/ ]]; then
    endpoint="$a"
  fi
done

if (( is_write )); then
  echo "API_WRITE: $endpoint $*" >> "$TEST_TMP/gh_writes.log"
fi

if [[ "$endpoint" =~ repos/[^/]+/[^/]+/actions/runs\? ]]; then
  if [[ -f "$TEST_TMP/runs.json" ]]; then
    cat "$TEST_TMP/runs.json"
    exit 0
  fi
  echo '{"workflow_runs":[]}'
  exit 0
fi

if [[ "$endpoint" =~ repos/[^/]+/[^/]+/actions/runs/[0-9]+/cancel$ ]]; then
  if [[ -f "$TEST_TMP/cancel_fail" ]]; then
    echo "Cannot cancel run" >&2
    exit 1
  fi
  echo "{}"
  exit 0
fi

echo "{}"
exit 0
EOF

chmod +x "$TEST_TMP/bin/gh"
ORIG_PATH="$PATH"
export PATH="$TEST_TMP/bin:$ORIG_PATH"
export TEST_TMP

setup_env() {
  export CLI_RELEASE_WRITE=1
  export REPO="pivotal-cf/replicator"
  export APPROVAL_STALE_HOURS=24
  export NOW_OVERRIDE="2026-10-07T12:00:00Z"
  export GITHUB_STEP_SUMMARY="$TEST_TMP/summary.txt"

  rm -f "$TEST_TMP/gh_calls.log" "$TEST_TMP/gh_writes.log" "$TEST_TMP/runs.json" \
        "$TEST_TMP/cancel_fail" "$TEST_TMP/summary.txt"
  echo '{"workflow_runs":[]}' > "$TEST_TMP/runs.json"
}

echo "=== Testing CLI_RELEASE_WRITE refusal ==="
setup_env
export CLI_RELEASE_WRITE=0
assert_rc "janitor.sh refuses without CLI_RELEASE_WRITE=1" 2 "bash '$JANITOR_SH'"

echo "=== Testing Input Validations ==="
setup_env
export REPO="invalid/repo"
assert_rc "janitor.sh refuses invalid repo allowlist" 2 "bash '$JANITOR_SH'"

setup_env
export APPROVAL_STALE_HOURS=0
assert_rc "janitor.sh refuses invalid APPROVAL_STALE_HOURS (0)" 2 "bash '$JANITOR_SH'"

echo "=== Testing Path Filter ==="
setup_env
# Run 101 has wrong path (.github/workflows/ci.yml) even though it is waiting and stale (48h old)
cat << 'EOF' > "$TEST_TMP/runs.json"
{
  "workflow_runs": [
    {
      "id": 101,
      "path": ".github/workflows/ci.yml",
      "status": "waiting",
      "created_at": "2026-10-05T12:00:00Z"
    }
  ]
}
EOF
assert_rc "janitor.sh ignores runs with non-matching path" 0 "bash '$JANITOR_SH'"
assert "run 101 was not cancelled" "! grep -q '101/cancel' '$TEST_TMP/gh_writes.log' 2>/dev/null"

echo "=== Testing Age Filter ==="
setup_env
# Run 102 is fresh (only 2 hours old vs 24h stale limit)
# Run 103 is stale (30 hours old)
cat << 'EOF' > "$TEST_TMP/runs.json"
{
  "workflow_runs": [
    {
      "id": 102,
      "path": ".github/workflows/auto-release.yml",
      "status": "waiting",
      "created_at": "2026-10-07T10:00:00Z"
    },
    {
      "id": 103,
      "path": ".github/workflows/auto-release.yml",
      "status": "waiting",
      "created_at": "2026-10-06T06:00:00Z"
    }
  ]
}
EOF
assert_rc "janitor.sh cancels only stale run" 0 "bash '$JANITOR_SH'"
assert "stale run 103 was cancelled" "grep -q '103/cancel' '$TEST_TMP/gh_writes.log'"
assert "fresh run 102 was not cancelled" "! grep -q '102/cancel' '$TEST_TMP/gh_writes.log'"
assert "summary records cancellation of 103" "grep -q 'Cancelled stale auto-release run #103' '$TEST_TMP/summary.txt'"

echo "=== Testing Error Handling on Cancel ==="
setup_env
touch "$TEST_TMP/cancel_fail"
cat << 'EOF' > "$TEST_TMP/runs.json"
{
  "workflow_runs": [
    {
      "id": 104,
      "path": ".github/workflows/auto-release.yml",
      "status": "waiting",
      "created_at": "2026-10-05T12:00:00Z"
    }
  ]
}
EOF
# Must warn and exit 0, NOT crash or exit non-zero
assert_rc "janitor.sh warns but exits 0 when cancel API call fails" 0 "bash '$JANITOR_SH'"

echo "========================================="
echo "janitor_test: $TOTAL tests, $FAILED failed"
if (( FAILED > 0 )); then
  exit 1
fi
exit 0
