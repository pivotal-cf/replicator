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
  if [[ -f "$TEST_TMP/simulate_compare_fail" ]]; then
    echo "HTTP 500: Server error" >&2
    exit 1
  fi
  if [[ -f "$TEST_TMP/compare.json" ]]; then
    cat "$TEST_TMP/compare.json"
    exit 0
  fi
  echo '{"status":"identical"}'
  exit 0
fi

if [[ "$endpoint" =~ repos/[^/]+/[^/]+/commits/([^/?]+) ]]; then
  commit_sha="${BASH_REMATCH[1]}"
  if [[ -f "$TEST_TMP/simulate_commit_fail" ]]; then
    echo "HTTP 500: Server error" >&2
    exit 1
  fi
  if [[ -f "$TEST_TMP/commit_${commit_sha}.json" ]]; then
    cat "$TEST_TMP/commit_${commit_sha}.json"
    exit 0
  fi
  if [[ -f "$TEST_TMP/commit.json" ]]; then
    cat "$TEST_TMP/commit.json"
    exit 0
  fi
  echo '{"sha":"'"$commit_sha"'","files":[{"filename":"HomebrewFormula/replicator.rb"}]}'
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
  if [[ -f "$TEST_TMP/simulate_delay" ]]; then
    poll_count=0
    if [[ -f "$TEST_TMP/poll_count" ]]; then
      poll_count="$(cat "$TEST_TMP/poll_count")"
    fi
    poll_count=$(( poll_count + 1 ))
    echo "$poll_count" > "$TEST_TMP/poll_count"
    if (( poll_count < 2 )); then
      echo '{"total_count":0,"workflow_runs":[]}'
      exit 0
    fi
  fi
  if [[ -f "$TEST_TMP/dispatch_runs.json" ]]; then
    cat "$TEST_TMP/dispatch_runs.json"
    exit 0
  fi
  echo "{\"total_count\":1,\"workflow_runs\":[{\"id\":99999,\"name\":\"ci\",\"head_branch\":\"${VERSION:-0.23.0}\",\"head_sha\":\"${SHA:-0123456789abcdef0123456789abcdef01234567}\",\"event\":\"workflow_dispatch\",\"status\":\"queued\",\"conclusion\":null,\"created_at\":\"${NOW_OVERRIDE:-2026-10-07T01:00:01Z}\",\"run_started_at\":\"${NOW_OVERRIDE:-2026-10-07T01:00:02Z}\"}]}"
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

  rm -f "$TEST_TMP/simulate_422" "$TEST_TMP/simulate_compare_fail" "$TEST_TMP/simulate_commit_fail" \
        "$TEST_TMP/simulate_delay" "$TEST_TMP/poll_count" \
        "$TEST_TMP/gh_writes.log" "$TEST_TMP/gh_calls.log" \
        "$TEST_TMP/approvals.json" "$TEST_TMP/tags.json" "$TEST_TMP/compare.json" \
        "$TEST_TMP/commit.json" "$TEST_TMP/commit_"*.json \
        "$TEST_TMP/ci_runs.json" "$TEST_TMP/dispatch_runs.json"

  echo '[]' > "$TEST_TMP/tags.json"
  echo '{"status":"identical"}' > "$TEST_TMP/compare.json"
  echo '{"workflow_runs":[{"event":"push","head_branch":"master","conclusion":"success"}]}' > "$TEST_TMP/ci_runs.json"
  echo "{\"total_count\":1,\"workflow_runs\":[{\"id\":99999,\"name\":\"ci\",\"head_branch\":\"$VERSION\",\"head_sha\":\"$SHA\",\"event\":\"workflow_dispatch\",\"status\":\"queued\",\"conclusion\":null,\"created_at\":\"2026-10-07T01:00:01Z\",\"run_started_at\":\"2026-10-07T01:00:02Z\"}]}" > "$TEST_TMP/dispatch_runs.json"
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
assert "no write occurred when sha diverged from master" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

# --- Substantive tail / revert tail ---
setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":1,"commits":[{"sha":"1111111111111111111111111111111111111111"}]}
EOF
cat << 'EOF' > "$TEST_TMP/commit.json"
{"sha":"1111111111111111111111111111111111111111","files":[{"filename":"go.mod"}]}
EOF
assert_rc "act.sh exits 0 no-op if ahead tail has substantive advancement (go.mod)" 0 "bash '$ACT_SH'"
assert "no write occurred when ahead tail has substantive advancement" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":1,"commits":[{"sha":"2222222222222222222222222222222222222222"}]}
EOF
cat << 'EOF' > "$TEST_TMP/commit.json"
{"sha":"2222222222222222222222222222222222222222","files":[{"filename":"main.go"}]}
EOF
assert_rc "act.sh exits 0 no-op if ahead tail is a revert of candidate changes" 0 "bash '$ACT_SH'"
assert "no write occurred when ahead tail is a revert" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":1,"commits":[{"sha":"3333333333333333333333333333333333333333"}]}
EOF
cat << 'EOF' > "$TEST_TMP/commit.json"
{"sha":"3333333333333333333333333333333333333333","files":[{"filename":"HomebrewFormula/replicator.rb"},{"filename":"README.md"}]}
EOF
assert_rc "act.sh exits 0 no-op if brew commit also touches non-brew file" 0 "bash '$ACT_SH'"
assert "no write occurred when brew commit touches non-brew file" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":1,"commits":[{"sha":"4444444444444444444444444444444444444444"}]}
EOF
cat << 'EOF' > "$TEST_TMP/commit.json"
{"sha":"4444444444444444444444444444444444444444","files":[{"filename":"HomebrewFormula/sub/replicator.rb"}]}
EOF
assert_rc "act.sh exits 0 no-op if file under HomebrewFormula is in subdirectory" 0 "bash '$ACT_SH'"
assert "no write occurred for nested subdirectory" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":1,"commits":[{"sha":"5555555555555555555555555555555555555555"}]}
EOF
cat << 'EOF' > "$TEST_TMP/commit.json"
{"sha":"5555555555555555555555555555555555555555","files":[{"filename":"HomebrewFormula/replicator.rb.bak"}]}
EOF
assert_rc "act.sh exits 0 no-op if file under HomebrewFormula lacks .rb suffix" 0 "bash '$ACT_SH'"
assert "no write occurred for non-rb file" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

# --- Brew-only tail ---
setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":1,"commits":[{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
EOF
cat << 'EOF' > "$TEST_TMP/commit.json"
{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","files":[{"filename":"HomebrewFormula/replicator.rb"}]}
EOF
# A rename into Homebrew also removes the prior source path and is substantive.
cat > "$TEST_TMP/commit_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json" <<'JSON'
{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","files":[{"filename":"HomebrewFormula/replicator.rb","previous_filename":"main.go","status":"renamed"}]}
JSON
assert_rc "source rename into brew directory is a clean no-op" 0 "bash '$ACT_SH'"
assert "source rename into brew directory creates no tag" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"
cat > "$TEST_TMP/commit_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json" <<'JSON'
{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","files":[{"filename":"HomebrewFormula/replicator.rb"}]}
JSON
assert_rc "act.sh succeeds when ahead tail is verifiably brew-only" 0 "bash '$ACT_SH'"
assert "write occurred when ahead tail is brew-only" "[[ -f '$TEST_TMP/gh_writes.log' ]]"
total_writes="$(wc -l < "$TEST_TMP/gh_writes.log" | tr -d ' ')"
assert "fake gh saw exactly two write operations on brew-only tail" "[[ '$total_writes' == '2' ]]"

setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":2,"commits":[{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
EOF
cat << 'EOF' > "$TEST_TMP/commit_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json"
{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","files":[{"filename":"HomebrewFormula/replicator.rb"}]}
EOF
cat << 'EOF' > "$TEST_TMP/commit_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json"
{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","files":[{"filename":"HomebrewFormula/other.rb"}]}
EOF
assert_rc "act.sh succeeds with multiple brew-only tail commits" 0 "bash '$ACT_SH'"
total_writes="$(wc -l < "$TEST_TMP/gh_writes.log" | tr -d ' ')"
assert "fake gh saw exactly two write operations on multi-brew tail" "[[ '$total_writes' == '2' ]]"

setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":2,"commits":[{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"sha":"1111111111111111111111111111111111111111"}]}
EOF
cat << 'EOF' > "$TEST_TMP/commit_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json"
{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","files":[{"filename":"HomebrewFormula/replicator.rb"}]}
EOF
cat << 'EOF' > "$TEST_TMP/commit_1111111111111111111111111111111111111111.json"
{"sha":"1111111111111111111111111111111111111111","files":[{"filename":"go.sum"}]}
EOF
assert_rc "act.sh exits 0 no-op if multi-commit tail contains any non-brew commit" 0 "bash '$ACT_SH'"
assert "no write occurred when multi-commit tail has non-brew commit" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

# --- Truncation ---
setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":2,"commits":[{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
EOF
assert_rc "act.sh exits 2 if compare commits array is truncated" 2 "bash '$ACT_SH'"
assert "no write occurred on truncated compare" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":1,"commits":[{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
EOF
cp "${SCRIPT_DIR}/testdata/commit_truncated.json" "$TEST_TMP/commit.json"
assert_rc "act.sh exits 2 if commit files list is truncated at 300" 2 "bash '$ACT_SH'"
assert "no write occurred on truncated commit files" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

# --- Errors and Ambiguity ---
setup_env
echo "not json" > "$TEST_TMP/compare.json"
assert_rc "act.sh exits 2 if compare body is unparseable" 2 "bash '$ACT_SH'"

setup_env
echo "{}" > "$TEST_TMP/compare.json"
assert_rc "act.sh exits 2 if compare response is missing status" 2 "bash '$ACT_SH'"

setup_env
echo '{"status":"weird","total_commits":0,"commits":[]}' > "$TEST_TMP/compare.json"
assert_rc "act.sh exits 2 if compare status is unknown" 2 "bash '$ACT_SH'"

setup_env
echo '{"status":"ahead","total_commits":0,"commits":[]}' > "$TEST_TMP/compare.json"
assert_rc "act.sh exits 2 if compare ahead has empty commits" 2 "bash '$ACT_SH'"

setup_env
touch "$TEST_TMP/simulate_compare_fail"
assert_rc "act.sh exits 2 if compare API call fails" 2 "bash '$ACT_SH'"

setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":1,"commits":[{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
EOF
touch "$TEST_TMP/simulate_commit_fail"
assert_rc "act.sh exits 2 if commit API call fails" 2 "bash '$ACT_SH'"

setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":1,"commits":[{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
EOF
echo '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' > "$TEST_TMP/commit.json"
assert_rc "act.sh exits 2 if commit response is missing files array" 2 "bash '$ACT_SH'"

setup_env
cat << 'EOF' > "$TEST_TMP/compare.json"
{"status":"ahead","total_commits":1,"commits":[{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
EOF
echo 'not a json object' > "$TEST_TMP/commit.json"
assert_rc "act.sh exits 2 if commit response is unparseable" 2 "bash '$ACT_SH'"

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
assert "422 did not trigger workflow run (immutability preserved)" "! grep -q 'WORKFLOW_RUN' '$TEST_TMP/gh_writes.log'"

# Missing dispatch run
setup_env
echo '{"total_count":0,"workflow_runs":[]}' > "$TEST_TMP/dispatch_runs.json"
assert_rc "act.sh fails if dispatch run is missing after polling timeout" 2 "bash '$ACT_SH'"

# Success path and write allowlist check
setup_env
assert_rc "act.sh success path in auto mode" 0 "bash '$ACT_SH'"
assert "fake gh saw git/refs POST" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/git/refs' '$TEST_TMP/gh_writes.log'"
assert "fake gh saw workflow run" "grep -q 'WORKFLOW_RUN: workflow run ci.yml -R pivotal-cf/replicator --ref 0.23.0' '$TEST_TMP/gh_writes.log'"
total_writes="$(wc -l < "$TEST_TMP/gh_writes.log" | tr -d ' ')"
assert "fake gh saw exactly two write operations" "[[ '$total_writes' == '2' ]]"
assert "fake gh saw created filter in dispatch run query" "grep -q 'created=>=' '$TEST_TMP/gh_calls.log'"

echo "=== Testing Dispatch Confirmation & Polling Hardening ==="
# Existing tag immutability: tag already exists in refs/tags list must not dispatch
setup_env
cat << 'EOF' > "$TEST_TMP/tags.json"
[
  {"ref": "refs/tags/0.23.0"}
]
EOF
assert_rc "act.sh exits 0 no-op if tag exists" 0 "bash '$ACT_SH'"
assert "existing tag does not issue git/refs write" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"
assert "existing tag does not blindly dispatch ci.yml" "! grep -q 'WORKFLOW_RUN' '$TEST_TMP/gh_writes.log' 2>/dev/null || true"

# Empty results: empty workflow_runs array fails closed
setup_env
echo '{"total_count":0,"workflow_runs":[]}' > "$TEST_TMP/dispatch_runs.json"
assert_rc "act.sh fails if dispatch runs array is empty" 2 "bash '$ACT_SH'"

# Empty results: malformed object missing workflow_runs fails closed
setup_env
echo '{"total_count":0}' > "$TEST_TMP/dispatch_runs.json"
assert_rc "act.sh fails if dispatch response lacks workflow_runs array" 2 "bash '$ACT_SH'"

# Delayed results: run appears after initial empty poll within budget
setup_env
export POLL_TIMEOUT_SECONDS=2
export POLL_INTERVAL_SECONDS=0
touch "$TEST_TMP/simulate_delay"
assert_rc "act.sh succeeds when dispatch run appears after initial empty poll" 0 "bash '$ACT_SH'"
assert "delayed run triggered multiple polls" "[[ -f '$TEST_TMP/poll_count' && \$(cat '$TEST_TMP/poll_count') -ge 2 ]]"
total_writes="$(wc -l < "$TEST_TMP/gh_writes.log" | tr -d ' ')"
assert "delayed run still saw exactly two write operations" "[[ '$total_writes' == '2' ]]"

# Mismatched event: run has event 'push' instead of 'workflow_dispatch'
# Defensively rejects; unchecked workflow_runs[0] fallback must NOT accept it
setup_env
cat << 'EOF' > "$TEST_TMP/dispatch_runs.json"
{
  "total_count": 1,
  "workflow_runs": [
    {
      "id": 11111,
      "name": "ci",
      "head_branch": "0.23.0",
      "head_sha": "0123456789abcdef0123456789abcdef01234567",
      "event": "push",
      "status": "queued",
      "created_at": "2026-10-07T01:00:01Z"
    }
  ]
}
EOF
assert_rc "act.sh fails if run event is push instead of workflow_dispatch" 2 "bash '$ACT_SH'"

# Mismatched branch: run has head_branch 'master' instead of target tag
setup_env
cat << 'EOF' > "$TEST_TMP/dispatch_runs.json"
{
  "total_count": 1,
  "workflow_runs": [
    {
      "id": 22222,
      "name": "ci",
      "head_branch": "master",
      "head_sha": "0123456789abcdef0123456789abcdef01234567",
      "event": "workflow_dispatch",
      "status": "queued",
      "created_at": "2026-10-07T01:00:01Z"
    }
  ]
}
EOF
assert_rc "act.sh fails if run head_branch is master instead of tag" 2 "bash '$ACT_SH'"

# Mismatched branch: run has head_branch of another version tag
setup_env
cat << 'EOF' > "$TEST_TMP/dispatch_runs.json"
{
  "total_count": 1,
  "workflow_runs": [
    {
      "id": 22223,
      "name": "ci",
      "head_branch": "0.24.0",
      "head_sha": "0123456789abcdef0123456789abcdef01234567",
      "event": "workflow_dispatch",
      "status": "queued",
      "created_at": "2026-10-07T01:00:01Z"
    }
  ]
}
EOF
assert_rc "act.sh fails if run head_branch is a different version" 2 "bash '$ACT_SH'"

# Mismatched SHA: run has different head_sha
setup_env
cat << 'EOF' > "$TEST_TMP/dispatch_runs.json"
{
  "total_count": 1,
  "workflow_runs": [
    {
      "id": 33333,
      "name": "ci",
      "head_branch": "0.23.0",
      "head_sha": "ffffffffffffffffffffffffffffffffffffffff",
      "event": "workflow_dispatch",
      "status": "queued",
      "created_at": "2026-10-07T01:00:01Z"
    }
  ]
}
EOF
assert_rc "act.sh fails if run head_sha does not match candidate SHA" 2 "bash '$ACT_SH'"

# Stale result: run created before dispatch start timestamp
setup_env
cat << 'EOF' > "$TEST_TMP/dispatch_runs.json"
{
  "total_count": 1,
  "workflow_runs": [
    {
      "id": 44444,
      "name": "ci",
      "head_branch": "0.23.0",
      "head_sha": "0123456789abcdef0123456789abcdef01234567",
      "event": "workflow_dispatch",
      "status": "completed",
      "created_at": "2026-10-06T12:00:00Z"
    }
  ]
}
EOF
assert_rc "act.sh fails if run is stale (created before dispatch)" 2 "bash '$ACT_SH'"

# Stale + fresh run: distinguishes prior run and picks fresh dispatch run
setup_env
cat << 'EOF' > "$TEST_TMP/dispatch_runs.json"
{
  "total_count": 2,
  "workflow_runs": [
    {
      "id": 99999,
      "name": "ci",
      "head_branch": "0.23.0",
      "head_sha": "0123456789abcdef0123456789abcdef01234567",
      "event": "workflow_dispatch",
      "status": "queued",
      "created_at": "2026-10-07T01:00:01Z"
    },
    {
      "id": 44444,
      "name": "ci",
      "head_branch": "0.23.0",
      "head_sha": "0123456789abcdef0123456789abcdef01234567",
      "event": "workflow_dispatch",
      "status": "completed",
      "created_at": "2026-10-06T12:00:00Z"
    }
  ]
}
EOF
assert_rc "act.sh accepts fresh run when stale run also present" 0 "bash '$ACT_SH'"

# Tag ref prefix compatibility: head_branch with refs/tags/ prefix matches
setup_env
cat << 'EOF' > "$TEST_TMP/dispatch_runs.json"
{
  "total_count": 1,
  "workflow_runs": [
    {
      "id": 55555,
      "name": "ci",
      "head_branch": "refs/tags/0.23.0",
      "head_sha": "0123456789abcdef0123456789abcdef01234567",
      "event": "workflow_dispatch",
      "status": "queued",
      "created_at": "2026-10-07T01:00:01Z"
    }
  ]
}
EOF
assert_rc "act.sh accepts run with refs/tags/ prefix in head_branch" 0 "bash '$ACT_SH'"

echo "========================================="
echo "act_test: $TOTAL tests, $FAILED failed"
if (( FAILED > 0 )); then
  exit 1
fi
exit 0
