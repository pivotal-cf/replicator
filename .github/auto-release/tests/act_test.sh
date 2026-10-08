#!/usr/bin/env bash
set -euo pipefail

# act_test.sh - Unit tests for act.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACT_SH="${SCRIPT_DIR}/../act.sh"

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

if [[ "${1:-}" == "workflow" && "${2:-}" == "run" ]]; then
  echo "WORKFLOW_RUN: $*" >> "$TEST_TMP/gh_writes.log"
  exit 0
fi

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

if [[ "$endpoint" =~ actions/runs/[0-9]+/approvals ]]; then
  if [[ -f "$TEST_TMP/approvals.json" ]]; then
    cat "$TEST_TMP/approvals.json"
    exit 0
  fi
  echo "[]"
  exit 0
fi

if [[ "$endpoint" =~ git/matching-refs/tags ]]; then
  if [[ -f "$TEST_TMP/tags.json" ]]; then
    cat "$TEST_TMP/tags.json"
    exit 0
  fi
  echo "[]"
  exit 0
fi

if [[ "$endpoint" =~ compare/ ]]; then
  if [[ -f "$TEST_TMP/compare.json" ]]; then
    cat "$TEST_TMP/compare.json"
    exit 0
  fi
  echo '{"status":"identical"}'
  exit 0
fi

if [[ "$endpoint" =~ actions/workflows/ci\.yml/runs\?.*event=push ]]; then
  if [[ -f "$TEST_TMP/ci_runs.json" ]]; then
    cat "$TEST_TMP/ci_runs.json"
    exit 0
  fi
  echo '{"workflow_runs":[{"event":"push","head_branch":"master","conclusion":"success"}]}'
  exit 0
fi

if [[ "$endpoint" =~ actions/workflows/ci\.yml/runs\?.*event=workflow_dispatch ]]; then
  if [[ -f "$TEST_TMP/dispatch_runs.json" ]]; then
    cat "$TEST_TMP/dispatch_runs.json"
    exit 0
  fi
  echo '{"workflow_runs":[{"id":99999,"event":"workflow_dispatch"}]}'
  exit 0
fi

if [[ "$endpoint" =~ git/refs ]]; then
  if [[ -f "$TEST_TMP/simulate_422" ]]; then
    echo "HTTP 422: Reference already exists" >&2
    exit 1
  fi
  echo '{"ref":"refs/tags/0.23.0"}'
  exit 0
fi

echo "{}"
exit 0
EOF

chmod +x "$TEST_TMP/bin/gh"
ORIG_PATH="$PATH"
export PATH="$TEST_TMP/bin:$ORIG_PATH"
export TEST_TMP

# Standard valid environment
setup_env() {
  export CLI_RELEASE_WRITE=1
  export REPO="pivotal-cf/replicator"
  export VERSION="0.23.0"
  export SHA="0123456789abcdef0123456789abcdef01234567"
  export DECISION_STARTED_AT="2026-10-07T00:00:00Z"
  export NOW_OVERRIDE="2026-10-07T01:00:00Z"
  export APPROVAL_STALE_HOURS=24
  export RELEASE_MODE="auto"
  export INPUT_MODE_OVERRIDE="none"
  export GITHUB_RUN_ATTEMPT=1
  export GITHUB_RUN_ID=12345
  export POLL_TIMEOUT_SECONDS=1
  export POLL_INTERVAL_SECONDS=0

  rm -f "$TEST_TMP/simulate_422" "$TEST_TMP/gh_writes.log" "$TEST_TMP/gh_calls.log" \
        "$TEST_TMP/approvals.json" "$TEST_TMP/tags.json" "$TEST_TMP/compare.json" \
        "$TEST_TMP/ci_runs.json" "$TEST_TMP/dispatch_runs.json"

  echo '[]' > "$TEST_TMP/tags.json"
  echo '{"status":"identical"}' > "$TEST_TMP/compare.json"
  echo '{"workflow_runs":[{"event":"push","head_branch":"master","conclusion":"success"}]}' > "$TEST_TMP/ci_runs.json"
  echo '{"workflow_runs":[{"id":99999,"event":"workflow_dispatch"}]}' > "$TEST_TMP/dispatch_runs.json"
}

echo "=== Testing CLI_RELEASE_WRITE refusal ==="
setup_env
export CLI_RELEASE_WRITE=0
assert_rc "act.sh refuses without CLI_RELEASE_WRITE=1" 2 "bash '$ACT_SH'"

echo "=== Testing Input Validations ==="
setup_env
export REPO="invalid/repo"
assert_rc "act.sh refuses invalid repo allowlist" 2 "bash '$ACT_SH'"

setup_env
export REPO="pivotal-cf/winfs-injector"
assert_rc "act.sh accepts pivotal-cf/winfs-injector" 0 "bash '$ACT_SH'"

setup_env
export VERSION="v1.0.0"
assert_rc "act.sh refuses non-semver version (v prefix)" 2 "bash '$ACT_SH'"

setup_env
export SHA="short-sha"
assert_rc "act.sh refuses non-40-hex SHA" 2 "bash '$ACT_SH'"

setup_env
export APPROVAL_STALE_HOURS=0
assert_rc "act.sh refuses invalid APPROVAL_STALE_HOURS (0)" 2 "bash '$ACT_SH'"

echo "=== Testing Mode Re-derivation ==="
setup_env
export RELEASE_MODE="report"
assert_rc "act.sh refuses report mode (not approve/auto)" 2 "bash '$ACT_SH'"

setup_env
export RELEASE_MODE="auto"
export INPUT_MODE_OVERRIDE="report"
assert_rc "act.sh refuses when INPUT_MODE_OVERRIDE lowers to report" 2 "bash '$ACT_SH'"

setup_env
export RELEASE_MODE="approve"
export INPUT_MODE_OVERRIDE="auto"
assert_rc "act.sh refuses INPUT_MODE_OVERRIDE=auto" 2 "bash '$ACT_SH'"

setup_env
export RELEASE_MODE="approve"
export INPUT_MODE_OVERRIDE="invalid-mode"
assert_rc "act.sh refuses invalid INPUT_MODE_OVERRIDE" 2 "bash '$ACT_SH'"

echo "=== Testing Approvals Guard (approve mode) ==="
setup_env
export RELEASE_MODE="approve"
export GITHUB_RUN_ATTEMPT=2
assert_rc "act.sh refuses if GITHUB_RUN_ATTEMPT is 2" 2 "bash '$ACT_SH'"

setup_env
export RELEASE_MODE="approve"
export GITHUB_RUN_ATTEMPT=1
echo '[]' > "$TEST_TMP/approvals.json"
assert_rc "act.sh refuses if approvals list is empty" 2 "bash '$ACT_SH'"

setup_env
export RELEASE_MODE="approve"
cat << 'EOF' > "$TEST_TMP/approvals.json"
[
  {
    "state": "rejected",
    "user": {"login": "approver"},
    "environments": [{"name": "release"}]
  }
]
EOF
assert_rc "act.sh refuses if approval state is rejected" 2 "bash '$ACT_SH'"

setup_env
export RELEASE_MODE="approve"
cat << 'EOF' > "$TEST_TMP/approvals.json"
[
  {
    "state": "approved",
    "user": {"login": ""},
    "environments": [{"name": "release"}]
  }
]
EOF
assert_rc "act.sh refuses if user.login is empty" 2 "bash '$ACT_SH'"

setup_env
export RELEASE_MODE="approve"
cat << 'EOF' > "$TEST_TMP/approvals.json"
[
  {
    "state": "approved",
    "user": {"login": "approver"},
    "environments": [{"name": "staging"}]
  }
]
EOF
assert_rc "act.sh refuses if environment is not 'release'" 2 "bash '$ACT_SH'"

setup_env
export RELEASE_MODE="approve"
cat << 'EOF' > "$TEST_TMP/approvals.json"
[
  {
    "state": "approved",
    "user": {"login": "approver"},
    "environments": [{"name": "release"}]
  }
]
EOF
assert_rc "act.sh proceeds if valid approval exists in approve mode" 0 "bash '$ACT_SH'"

echo "=== Testing Re-validation: Tags ==="
setup_env
cat << 'EOF' > "$TEST_TMP/tags.json"
[
  {"ref": "refs/tags/0.23.0"}
]
EOF
assert_rc "act.sh exits 0 no-op if version already exists" 0 "bash '$ACT_SH'"
assert "no write occurred when version already exists" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

setup_env
cat << 'EOF' > "$TEST_TMP/tags.json"
[
  {"ref": "refs/tags/0.24.0"}
]
EOF
assert_rc "act.sh exits 0 no-op if higher semver tag exists" 0 "bash '$ACT_SH'"
assert "no write occurred when higher semver tag exists" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

echo "=== Testing Re-validation: Compare Master ==="
setup_env
echo '{"status":"behind"}' > "$TEST_TMP/compare.json"
assert_rc "act.sh exits 0 no-op if sha is behind master" 0 "bash '$ACT_SH'"
assert "no write occurred when sha is behind master" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

setup_env
echo '{"status":"diverged"}' > "$TEST_TMP/compare.json"
assert_rc "act.sh exits 0 no-op if sha diverged from master" 0 "bash '$ACT_SH'"

echo "=== Testing Re-validation: Master CI Run ==="
setup_env
echo '{"workflow_runs":[{"event":"push","head_branch":"master","conclusion":"failure"}]}' > "$TEST_TMP/ci_runs.json"
assert_rc "act.sh exits 0 no-op if master CI run is not success" 0 "bash '$ACT_SH'"
assert "no write occurred when master CI run failed" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

echo "=== Testing Re-validation: Stale Decision ==="
setup_env
export DECISION_STARTED_AT="2026-10-05T00:00:00Z" # 49 hours before NOW_OVERRIDE
export APPROVAL_STALE_HOURS=24
assert_rc "act.sh exits 0 no-op if decision is older than APPROVAL_STALE_HOURS" 0 "bash '$ACT_SH'"
assert "no write occurred when decision is stale" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

echo "=== Testing Write Behavior ==="
# HTTP 422: Reference already exists
setup_env
touch "$TEST_TMP/simulate_422"
assert_rc "act.sh exits 0 on 422 Reference already exists" 0 "bash '$ACT_SH'"
assert "422 did not trigger workflow run" "! grep -q 'WORKFLOW_RUN' '$TEST_TMP/gh_writes.log'"

# Missing dispatch run
setup_env
echo '{"workflow_runs":[]}' > "$TEST_TMP/dispatch_runs.json"
assert_rc "act.sh fails if dispatch run is missing after polling timeout" 2 "bash '$ACT_SH'"

# Success path and write allowlist check
setup_env
assert_rc "act.sh success path in auto mode" 0 "bash '$ACT_SH'"
assert "fake gh saw git/refs POST" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/git/refs' '$TEST_TMP/gh_writes.log'"
assert "fake gh saw workflow run" "grep -q 'WORKFLOW_RUN: workflow run ci.yml -R pivotal-cf/replicator --ref 0.23.0' '$TEST_TMP/gh_writes.log'"
total_writes="$(wc -l < "$TEST_TMP/gh_writes.log" | tr -d ' ')"
assert "fake gh saw exactly two write operations" "[[ '$total_writes' == '2' ]]"

echo "========================================="
echo "act_test: $TOTAL tests, $FAILED failed"
if (( FAILED > 0 )); then
  exit 1
fi
exit 0
