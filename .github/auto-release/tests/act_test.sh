#!/usr/bin/env bash
set -euo pipefail

# act_test.sh - Unit tests for act.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_support.sh"
ACT_SH="${SCRIPT_DIR}/../act.sh"

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

if [[ "$endpoint" =~ actions/workflows/ci\.yml/dispatches ]]; then
  if [[ -f "$TEST_TMP/simulate_dispatch_fail" ]]; then
    echo "HTTP 500: Server error" >&2
    exit 1
  fi
  if [[ -f "$TEST_TMP/dispatch_resp.json" ]]; then
    cat "$TEST_TMP/dispatch_resp.json"
    exit 0
  fi
  echo "{\"workflow_run_id\":987654321,\"run_url\":\"https://api.github.com/repos/${REPO:-pivotal-cf/replicator}/actions/runs/987654321\",\"html_url\":\"https://github.com/${REPO:-pivotal-cf/replicator}/actions/runs/987654321\"}"
  exit 0
fi

if [[ "$endpoint" =~ actions/runs/([0-9]+)$ ]]; then
  run_id="${BASH_REMATCH[1]}"
  if [[ -f "$TEST_TMP/simulate_run_fail" ]]; then
    echo "HTTP 500: Server error" >&2
    exit 1
  fi
  if [[ -f "$TEST_TMP/run.json" ]]; then
    cat "$TEST_TMP/run.json"
    exit 0
  fi
  echo "{\"id\":${run_id},\"event\":\"workflow_dispatch\",\"head_branch\":\"${VERSION:-0.23.0}\",\"head_sha\":\"${SHA:-0123456789abcdef0123456789abcdef01234567}\",\"status\":\"queued\"}"
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
  export GITHUB_STEP_SUMMARY="$TEST_TMP/summary.md"

  rm -f "$TEST_TMP/simulate_422" "$TEST_TMP/simulate_compare_fail" "$TEST_TMP/simulate_commit_fail" \
        "$TEST_TMP/simulate_dispatch_fail" "$TEST_TMP/simulate_run_fail" \
        "$TEST_TMP/gh_writes.log" "$TEST_TMP/gh_calls.log" "$TEST_TMP/summary.md" \
        "$TEST_TMP/approvals.json" "$TEST_TMP/tags.json" "$TEST_TMP/compare.json" \
        "$TEST_TMP/commit.json" "$TEST_TMP/commit_"*.json \
        "$TEST_TMP/ci_runs.json" "$TEST_TMP/dispatch_resp.json" "$TEST_TMP/run.json"

  echo '[]' > "$TEST_TMP/tags.json"
  echo '{"status":"identical"}' > "$TEST_TMP/compare.json"
  echo '{"workflow_runs":[{"event":"push","head_branch":"master","conclusion":"success"}]}' > "$TEST_TMP/ci_runs.json"
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
assert "422 did not trigger dispatch (immutability preserved)" "! grep -q 'actions/workflows/ci.yml/dispatches' '$TEST_TMP/gh_writes.log' 2>/dev/null"

# Existing tag immutability: tag already exists in refs/tags list must not dispatch
setup_env
cat << 'EOF' > "$TEST_TMP/tags.json"
[
  {"ref": "refs/tags/0.23.0"}
]
EOF
assert_rc "act.sh exits 0 no-op if tag exists" 0 "bash '$ACT_SH'"
assert "existing tag does not issue git/refs write" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"
assert "existing tag does not blindly dispatch ci.yml" "! grep -q 'actions/workflows/ci.yml/dispatches' '$TEST_TMP/gh_writes.log' 2>/dev/null"

# Dispatch API failure
setup_env
touch "$TEST_TMP/simulate_dispatch_fail"
assert_rc "act.sh fails closed if dispatch API call fails" 2 "bash '$ACT_SH'"

# Success path and write allowlist check
setup_env
assert_rc "act.sh success path in auto mode" 0 "bash '$ACT_SH'"
assert "fake gh saw git/refs POST" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/git/refs' '$TEST_TMP/gh_writes.log'"
assert "fake gh saw ci.yml dispatches POST with tag ref" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/actions/workflows/ci.yml/dispatches.*ref=0.23.0' '$TEST_TMP/gh_writes.log'"
assert "fake gh saw return_run_details=true typed flag" "grep -q -- '-F return_run_details=true' '$TEST_TMP/gh_writes.log'"
total_writes="$(wc -l < "$TEST_TMP/gh_writes.log" | tr -d ' ')"
assert "fake gh saw exactly two write operations" "[[ '$total_writes' == '2' ]]"
assert "summary includes markdown link to dispatched run" "grep -q '\[987654321\](https://github.com/pivotal-cf/replicator/actions/runs/987654321)' '$TEST_TMP/summary.md'"

echo "=== Testing Dispatch Response Contract & Schema Validation ==="
# Empty response
setup_env
echo "" > "$TEST_TMP/dispatch_resp.json"
assert_rc "act.sh fails if dispatch response is empty" 2 "bash '$ACT_SH'"

# Non-JSON response
setup_env
echo "not-a-json-object" > "$TEST_TMP/dispatch_resp.json"
assert_rc "act.sh fails if dispatch response is not JSON" 2 "bash '$ACT_SH'"

# Missing workflow_run_id
setup_env
echo '{"run_url":"https://api.github.com/repos/pivotal-cf/replicator/actions/runs/987654321","html_url":"https://github.com/pivotal-cf/replicator/actions/runs/987654321"}' > "$TEST_TMP/dispatch_resp.json"
assert_rc "act.sh fails if dispatch response lacks workflow_run_id" 2 "bash '$ACT_SH'"

# Non-integral / negative / zero workflow_run_id
setup_env
echo '{"workflow_run_id":0,"run_url":"https://api.github.com/repos/pivotal-cf/replicator/actions/runs/0","html_url":"https://github.com/pivotal-cf/replicator/actions/runs/0"}' > "$TEST_TMP/dispatch_resp.json"
assert_rc "act.sh fails if workflow_run_id is 0" 2 "bash '$ACT_SH'"

setup_env
echo '{"workflow_run_id":-123,"run_url":"https://api.github.com/repos/pivotal-cf/replicator/actions/runs/-123","html_url":"https://github.com/pivotal-cf/replicator/actions/runs/-123"}' > "$TEST_TMP/dispatch_resp.json"
assert_rc "act.sh fails if workflow_run_id is negative" 2 "bash '$ACT_SH'"

setup_env
echo '{"workflow_run_id":"987654321","run_url":"https://api.github.com/repos/pivotal-cf/replicator/actions/runs/987654321","html_url":"https://github.com/pivotal-cf/replicator/actions/runs/987654321"}' > "$TEST_TMP/dispatch_resp.json"
assert_rc "act.sh fails if workflow_run_id is string instead of number" 2 "bash '$ACT_SH'"

setup_env
echo '{"workflow_run_id":987654.321,"run_url":"https://api.github.com/repos/pivotal-cf/replicator/actions/runs/987654","html_url":"https://github.com/pivotal-cf/replicator/actions/runs/987654"}' > "$TEST_TMP/dispatch_resp.json"
assert_rc "act.sh fails if workflow_run_id is float" 2 "bash '$ACT_SH'"

# URL validation for expected repo
setup_env
echo '{"workflow_run_id":987654321,"run_url":"https://api.github.com/repos/other-org/other-repo/actions/runs/987654321","html_url":"https://github.com/pivotal-cf/replicator/actions/runs/987654321"}' > "$TEST_TMP/dispatch_resp.json"
assert_rc "act.sh fails if run_url repo does not match" 2 "bash '$ACT_SH'"

setup_env
echo '{"workflow_run_id":987654321,"run_url":"https://api.github.com/repos/pivotal-cf/replicator/actions/runs/987654321","html_url":"https://github.com/other-org/other-repo/actions/runs/987654321"}' > "$TEST_TMP/dispatch_resp.json"
assert_rc "act.sh fails if html_url repo does not match" 2 "bash '$ACT_SH'"

setup_env
echo '{"workflow_run_id":987654321,"run_url":"https://api.github.com/repos/pivotal-cf/replicator/actions/runs/111111","html_url":"https://github.com/pivotal-cf/replicator/actions/runs/987654321"}' > "$TEST_TMP/dispatch_resp.json"
assert_rc "act.sh fails if run_url run ID does not match workflow_run_id" 2 "bash '$ACT_SH'"

setup_env
echo '{"workflow_run_id":987654321,"run_url":"https://api.github.com/repos/pivotal-cf/replicator/actions/runs/987654321","html_url":""}' > "$TEST_TMP/dispatch_resp.json"
assert_rc "act.sh fails if html_url is empty" 2 "bash '$ACT_SH'"

echo "=== Testing Dispatched Run Identity Verification ==="
# Run fetch failure
setup_env
touch "$TEST_TMP/simulate_run_fail"
assert_rc "act.sh fails if run fetch API call fails" 2 "bash '$ACT_SH'"

# Run fetch body not object
setup_env
echo 'not a json object' > "$TEST_TMP/run.json"
assert_rc "act.sh fails if run fetch response is not JSON" 2 "bash '$ACT_SH'"

# Mismatched event: run has event 'push' instead of 'workflow_dispatch'
setup_env
cat << 'EOF' > "$TEST_TMP/run.json"
{
  "id": 987654321,
  "head_branch": "0.23.0",
  "head_sha": "0123456789abcdef0123456789abcdef01234567",
  "event": "push",
  "status": "queued"
}
EOF
assert_rc "act.sh fails if run event is push instead of workflow_dispatch" 2 "bash '$ACT_SH'"

# Mismatched branch: run has head_branch 'master' instead of target tag
setup_env
cat << 'EOF' > "$TEST_TMP/run.json"
{
  "id": 987654321,
  "head_branch": "master",
  "head_sha": "0123456789abcdef0123456789abcdef01234567",
  "event": "workflow_dispatch",
  "status": "queued"
}
EOF
assert_rc "act.sh fails if run head_branch is master instead of tag" 2 "bash '$ACT_SH'"

# Mismatched branch: run has head_branch of another version tag
setup_env
cat << 'EOF' > "$TEST_TMP/run.json"
{
  "id": 987654321,
  "head_branch": "0.24.0",
  "head_sha": "0123456789abcdef0123456789abcdef01234567",
  "event": "workflow_dispatch",
  "status": "queued"
}
EOF
assert_rc "act.sh fails if run head_branch is a different version" 2 "bash '$ACT_SH'"

# Mismatched SHA: run has different head_sha
setup_env
cat << 'EOF' > "$TEST_TMP/run.json"
{
  "id": 987654321,
  "head_branch": "0.23.0",
  "head_sha": "ffffffffffffffffffffffffffffffffffffffff",
  "event": "workflow_dispatch",
  "status": "queued"
}
EOF
assert_rc "act.sh fails if run head_sha does not match candidate SHA" 2 "bash '$ACT_SH'"

# Mismatched ID: run has different id
setup_env
cat << 'EOF' > "$TEST_TMP/run.json"
{
  "id": 111111,
  "head_branch": "0.23.0",
  "head_sha": "0123456789abcdef0123456789abcdef01234567",
  "event": "workflow_dispatch",
  "status": "queued"
}
EOF
assert_rc "act.sh fails if run id does not match dispatched run id" 2 "bash '$ACT_SH'"

# Tag ref prefix compatibility: head_branch with refs/tags/ prefix matches
setup_env
cat << 'EOF' > "$TEST_TMP/run.json"
{
  "id": 987654321,
  "head_branch": "refs/tags/0.23.0",
  "head_sha": "0123456789abcdef0123456789abcdef01234567",
  "event": "workflow_dispatch",
  "status": "queued"
}
EOF
assert_rc "act.sh accepts run with refs/tags/ prefix in head_branch" 0 "bash '$ACT_SH'"

test_finish "act_test"
