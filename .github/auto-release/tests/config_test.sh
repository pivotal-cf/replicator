#!/usr/bin/env bash
set -euo pipefail

# config_test.sh - Unit tests for config.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SCRIPT="${SCRIPT_DIR}/../config.sh"

# Clear GitHub Actions runner output variables so unit tests default to stdout mode
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY

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

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

# Helper to run config.sh with given env overrides
run_config() {
  # Default baseline environment
  local RM="${TEST_RELEASE_MODE-report}"
  local CH="${TEST_COOLDOWN_HOURS-24}"
  local MRI="${TEST_MIN_RELEASE_INTERVAL_DAYS-3}"
  local VB="${TEST_VERSION_BUMP-minor}"
  local IP="${TEST_INTRODUCED_POLICY-block}"
  local MFF="${TEST_MIN_FIXED_FINDINGS-1}"
  local SRA="${TEST_STUCK_RELEASE_ALERT_HOURS-2}"
  local ASH="${TEST_APPROVAL_STALE_HOURS-24}"
  local GV="${TEST_GOVULNCHECK_VERSION-v1.3.0}"
  local MCW="${TEST_MAX_CANDIDATE_WINDOW-100}"
  local IMO="${TEST_INPUT_MODE_OVERRIDE-none}"
  local EN="${TEST_EVENT_NAME-workflow_run}"

  (
    unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY
    export RELEASE_MODE="$RM"
    export COOLDOWN_HOURS="$CH"
    export MIN_RELEASE_INTERVAL_DAYS="$MRI"
    export VERSION_BUMP="$VB"
    export INTRODUCED_POLICY="$IP"
    export MIN_FIXED_FINDINGS="$MFF"
    export STUCK_RELEASE_ALERT_HOURS="$SRA"
    export APPROVAL_STALE_HOURS="$ASH"
    export GOVULNCHECK_VERSION="$GV"
    export MAX_CANDIDATE_WINDOW="$MCW"
    export INPUT_MODE_OVERRIDE="$IMO"
    export EVENT_NAME="$EN"

    bash "$CONFIG_SCRIPT"
  )
}

echo "=== Baseline Test ==="
assert "baseline configuration runs successfully" "run_config >/dev/null"

echo "=== Testing RELEASE_MODE Validation ==="
assert_rc "RELEASE_MODE empty fails exit 2" 2 "TEST_RELEASE_MODE='' run_config"
assert_rc "RELEASE_MODE whitespace fails exit 2" 2 "TEST_RELEASE_MODE='  ' run_config"
assert_rc "RELEASE_MODE typo 'foo' fails exit 2" 2 "TEST_RELEASE_MODE='foo' run_config"
assert_rc "RELEASE_MODE uppercase 'REPORT' fails exit 2" 2 "TEST_RELEASE_MODE='REPORT' run_config"
for mode in off report notify approve auto; do
  assert "RELEASE_MODE valid '$mode' passes" "TEST_RELEASE_MODE='$mode' run_config >/dev/null"
done

echo "=== Testing COOLDOWN_HOURS Validation (0..720) ==="
assert_rc "COOLDOWN_HOURS empty fails exit 2" 2 "TEST_COOLDOWN_HOURS='' run_config"
assert_rc "COOLDOWN_HOURS whitespace fails exit 2" 2 "TEST_COOLDOWN_HOURS=' 24 ' run_config"
assert_rc "COOLDOWN_HOURS negative fails exit 2" 2 "TEST_COOLDOWN_HOURS='-1' run_config"
assert_rc "COOLDOWN_HOURS non-numeric fails exit 2" 2 "TEST_COOLDOWN_HOURS='abc' run_config"
assert_rc "COOLDOWN_HOURS above 720 fails exit 2" 2 "TEST_COOLDOWN_HOURS='721' run_config"
assert "COOLDOWN_HOURS min bound 0 passes" "TEST_COOLDOWN_HOURS='0' run_config >/dev/null"
assert "COOLDOWN_HOURS max bound 720 passes" "TEST_COOLDOWN_HOURS='720' run_config >/dev/null"

echo "=== Testing MIN_RELEASE_INTERVAL_DAYS Validation (0..90) ==="
assert_rc "MIN_RELEASE_INTERVAL_DAYS empty fails exit 2" 2 "TEST_MIN_RELEASE_INTERVAL_DAYS='' run_config"
assert_rc "MIN_RELEASE_INTERVAL_DAYS negative fails exit 2" 2 "TEST_MIN_RELEASE_INTERVAL_DAYS='-1' run_config"
assert_rc "MIN_RELEASE_INTERVAL_DAYS non-integer fails exit 2" 2 "TEST_MIN_RELEASE_INTERVAL_DAYS='3.5' run_config"
assert_rc "MIN_RELEASE_INTERVAL_DAYS above 90 fails exit 2" 2 "TEST_MIN_RELEASE_INTERVAL_DAYS='91' run_config"
assert "MIN_RELEASE_INTERVAL_DAYS min bound 0 passes" "TEST_MIN_RELEASE_INTERVAL_DAYS='0' run_config >/dev/null"
assert "MIN_RELEASE_INTERVAL_DAYS max bound 90 passes" "TEST_MIN_RELEASE_INTERVAL_DAYS='90' run_config >/dev/null"

echo "=== Testing VERSION_BUMP Validation (minor|patch) ==="
assert_rc "VERSION_BUMP empty fails exit 2" 2 "TEST_VERSION_BUMP='' run_config"
assert_rc "VERSION_BUMP 'major' fails exit 2" 2 "TEST_VERSION_BUMP='major' run_config"
assert_rc "VERSION_BUMP uppercase 'MINOR' fails exit 2" 2 "TEST_VERSION_BUMP='MINOR' run_config"
assert "VERSION_BUMP 'minor' passes" "TEST_VERSION_BUMP='minor' run_config >/dev/null"
assert "VERSION_BUMP 'patch' passes" "TEST_VERSION_BUMP='patch' run_config >/dev/null"

echo "=== Testing INTRODUCED_POLICY Validation (block|allow) ==="
assert_rc "INTRODUCED_POLICY empty fails exit 2" 2 "TEST_INTRODUCED_POLICY='' run_config"
assert_rc "INTRODUCED_POLICY 'warn' fails exit 2" 2 "TEST_INTRODUCED_POLICY='warn' run_config"
assert_rc "INTRODUCED_POLICY 'deny' fails exit 2" 2 "TEST_INTRODUCED_POLICY='deny' run_config"
assert "INTRODUCED_POLICY 'block' passes" "TEST_INTRODUCED_POLICY='block' run_config >/dev/null"
assert "INTRODUCED_POLICY 'allow' passes" "TEST_INTRODUCED_POLICY='allow' run_config >/dev/null"

echo "=== Testing MIN_FIXED_FINDINGS Validation (1..50) ==="
assert_rc "MIN_FIXED_FINDINGS empty fails exit 2" 2 "TEST_MIN_FIXED_FINDINGS='' run_config"
assert_rc "MIN_FIXED_FINDINGS below min (0) fails exit 2" 2 "TEST_MIN_FIXED_FINDINGS='0' run_config"
assert_rc "MIN_FIXED_FINDINGS above max (51) fails exit 2" 2 "TEST_MIN_FIXED_FINDINGS='51' run_config"
assert "MIN_FIXED_FINDINGS min bound 1 passes" "TEST_MIN_FIXED_FINDINGS='1' run_config >/dev/null"
assert "MIN_FIXED_FINDINGS max bound 50 passes" "TEST_MIN_FIXED_FINDINGS='50' run_config >/dev/null"

echo "=== Testing STUCK_RELEASE_ALERT_HOURS Validation (1..168) ==="
assert_rc "STUCK_RELEASE_ALERT_HOURS empty fails exit 2" 2 "TEST_STUCK_RELEASE_ALERT_HOURS='' run_config"
assert_rc "STUCK_RELEASE_ALERT_HOURS below min (0) fails exit 2" 2 "TEST_STUCK_RELEASE_ALERT_HOURS='0' run_config"
assert_rc "STUCK_RELEASE_ALERT_HOURS above max (169) fails exit 2" 2 "TEST_STUCK_RELEASE_ALERT_HOURS='169' run_config"
assert "STUCK_RELEASE_ALERT_HOURS min bound 1 passes" "TEST_STUCK_RELEASE_ALERT_HOURS='1' run_config >/dev/null"
assert "STUCK_RELEASE_ALERT_HOURS max bound 168 passes" "TEST_STUCK_RELEASE_ALERT_HOURS='168' run_config >/dev/null"

echo "=== Testing APPROVAL_STALE_HOURS Validation (1..720) ==="
assert_rc "APPROVAL_STALE_HOURS empty fails exit 2" 2 "TEST_APPROVAL_STALE_HOURS='' run_config"
assert_rc "APPROVAL_STALE_HOURS below min (0) fails exit 2" 2 "TEST_APPROVAL_STALE_HOURS='0' run_config"
assert_rc "APPROVAL_STALE_HOURS above max (721) fails exit 2" 2 "TEST_APPROVAL_STALE_HOURS='721' run_config"
assert "APPROVAL_STALE_HOURS min bound 1 passes" "TEST_APPROVAL_STALE_HOURS='1' run_config >/dev/null"
assert "APPROVAL_STALE_HOURS max bound 720 passes" "TEST_APPROVAL_STALE_HOURS='720' run_config >/dev/null"

echo "=== Testing GOVULNCHECK_VERSION Validation (^v[0-9]+\.[0-9]+\.[0-9]+$) ==="
assert_rc "GOVULNCHECK_VERSION empty fails exit 2" 2 "TEST_GOVULNCHECK_VERSION='' run_config"
assert_rc "GOVULNCHECK_VERSION leading whitespace fails exit 2" 2 "TEST_GOVULNCHECK_VERSION=' v1.3.0' run_config"
assert_rc "GOVULNCHECK_VERSION missing 'v' fails exit 2" 2 "TEST_GOVULNCHECK_VERSION='1.3.0' run_config"
assert_rc "GOVULNCHECK_VERSION two digits fails exit 2" 2 "TEST_GOVULNCHECK_VERSION='v1.3' run_config"
assert_rc "GOVULNCHECK_VERSION with prerelease fails exit 2" 2 "TEST_GOVULNCHECK_VERSION='v1.3.0-rc1' run_config"
assert "GOVULNCHECK_VERSION valid v1.3.0 passes" "TEST_GOVULNCHECK_VERSION='v1.3.0' run_config >/dev/null"
assert "GOVULNCHECK_VERSION valid v0.0.1 passes" "TEST_GOVULNCHECK_VERSION='v0.0.1' run_config >/dev/null"
assert "GOVULNCHECK_VERSION valid v10.20.30 passes" "TEST_GOVULNCHECK_VERSION='v10.20.30' run_config >/dev/null"

echo "=== Testing MAX_CANDIDATE_WINDOW Validation (1..250) ==="
assert_rc "MAX_CANDIDATE_WINDOW empty fails exit 2" 2 "TEST_MAX_CANDIDATE_WINDOW='' run_config"
assert_rc "MAX_CANDIDATE_WINDOW below min (0) fails exit 2" 2 "TEST_MAX_CANDIDATE_WINDOW='0' run_config"
assert_rc "MAX_CANDIDATE_WINDOW above max (251) fails exit 2" 2 "TEST_MAX_CANDIDATE_WINDOW='251' run_config"
assert "MAX_CANDIDATE_WINDOW min bound 1 passes" "TEST_MAX_CANDIDATE_WINDOW='1' run_config >/dev/null"
assert "MAX_CANDIDATE_WINDOW max bound 250 passes" "TEST_MAX_CANDIDATE_WINDOW='250' run_config >/dev/null"

echo "=== Testing INPUT_MODE_OVERRIDE Validation (none|off|report|notify|approve) ==="
assert_rc "INPUT_MODE_OVERRIDE empty fails exit 2" 2 "TEST_INPUT_MODE_OVERRIDE='' run_config"
assert_rc "INPUT_MODE_OVERRIDE 'auto' fails exit 2 (not an allowed override option)" 2 "TEST_INPUT_MODE_OVERRIDE='auto' run_config"
assert_rc "INPUT_MODE_OVERRIDE 'true' fails exit 2" 2 "TEST_INPUT_MODE_OVERRIDE='true' run_config"
for o in none off report notify approve; do
  assert "INPUT_MODE_OVERRIDE valid '$o' passes" "TEST_INPUT_MODE_OVERRIDE='$o' run_config >/dev/null"
done

echo "=== Testing EVENT_NAME Validation ==="
assert_rc "EVENT_NAME empty fails exit 2" 2 "TEST_EVENT_NAME='' run_config"
assert_rc "EVENT_NAME whitespace-only fails exit 2" 2 "TEST_EVENT_NAME='   ' run_config"
assert "EVENT_NAME 'workflow_run' passes" "TEST_EVENT_NAME='workflow_run' run_config >/dev/null"
assert "EVENT_NAME 'schedule' passes" "TEST_EVENT_NAME='schedule' run_config >/dev/null"
assert "EVENT_NAME 'workflow_dispatch' passes" "TEST_EVENT_NAME='workflow_dispatch' run_config >/dev/null"

echo "=== Testing Full 25-Cell Effective Mode Table ==="
# Hierarchy: auto (4) > approve (3) > notify (2) > report (1) > off (0)
# Override can only LOWER; none = no override; override can NEVER raise

# Literal expectation table: <RELEASE_MODE> <INPUT_MODE_OVERRIDE> <effective mode>
# Override can only LOWER along auto > approve > notify > report > off; none = no override.
while read -r own override want; do
  got="$(TEST_RELEASE_MODE="$own" TEST_INPUT_MODE_OVERRIDE="$override" run_config | grep '^mode=' | cut -d= -f2)"
  TOTAL=$(( TOTAL + 1 ))
  if [[ "$got" == "$want" ]]; then
    echo "PASS: mode $own + override $override -> $want"
  else
    echo "FAIL: mode $own + override $override -> $want (got '$got')"
    FAILED=$(( FAILED + 1 ))
  fi
done <<'TABLE'
off off off
off none off
off report off
off notify off
off approve off
report none report
report off off
report report report
report notify report
report approve report
notify none notify
notify off off
notify report report
notify notify notify
notify approve notify
approve none approve
approve off off
approve report report
approve notify notify
approve approve approve
auto none auto
auto off off
auto report report
auto notify notify
auto approve approve
TABLE

echo "=== Testing GITHUB_OUTPUT and Step Summary Integration ==="
OUTPUT_FILE="$TEST_TMP/github_output.txt"
SUMMARY_FILE="$TEST_TMP/step_summary.txt"

(
  export RELEASE_MODE="auto"
  export COOLDOWN_HOURS="48"
  export MIN_RELEASE_INTERVAL_DAYS="7"
  export VERSION_BUMP="patch"
  export INTRODUCED_POLICY="allow"
  export MIN_FIXED_FINDINGS="2"
  export STUCK_RELEASE_ALERT_HOURS="4"
  export APPROVAL_STALE_HOURS="48"
  export GOVULNCHECK_VERSION="v1.3.0"
  export MAX_CANDIDATE_WINDOW="150"
  export INPUT_MODE_OVERRIDE="approve"
  export EVENT_NAME="workflow_dispatch"
  export GITHUB_OUTPUT="$OUTPUT_FILE"
  export GITHUB_STEP_SUMMARY="$SUMMARY_FILE"

  bash "$CONFIG_SCRIPT"
)

assert "GITHUB_OUTPUT contains mode=approve" "grep -q '^mode=approve$' '$OUTPUT_FILE'"
assert "GITHUB_OUTPUT contains constants_json" "grep -q '^constants_json=' '$OUTPUT_FILE'"

JSON_STRING="$(grep '^constants_json=' "$OUTPUT_FILE" | cut -d= -f2-)"
assert "constants_json is valid JSON" "echo '$JSON_STRING' | jq . >/dev/null"
assert "constants_json has mode == 'approve'" "[[ \"\$(echo '$JSON_STRING' | jq -r .mode)\" == 'approve' ]]"
assert "constants_json has RELEASE_MODE == 'auto'" "[[ \"\$(echo '$JSON_STRING' | jq -r .RELEASE_MODE)\" == 'auto' ]]"
assert "constants_json has COOLDOWN_HOURS == '48'" "[[ \"\$(echo '$JSON_STRING' | jq -r .COOLDOWN_HOURS)\" == '48' ]]"
assert "constants_json has MIN_RELEASE_INTERVAL_DAYS == '7'" "[[ \"\$(echo '$JSON_STRING' | jq -r .MIN_RELEASE_INTERVAL_DAYS)\" == '7' ]]"
assert "constants_json has VERSION_BUMP == 'patch'" "[[ \"\$(echo '$JSON_STRING' | jq -r .VERSION_BUMP)\" == 'patch' ]]"
assert "constants_json has INTRODUCED_POLICY == 'allow'" "[[ \"\$(echo '$JSON_STRING' | jq -r .INTRODUCED_POLICY)\" == 'allow' ]]"
assert "constants_json has MIN_FIXED_FINDINGS == '2'" "[[ \"\$(echo '$JSON_STRING' | jq -r .MIN_FIXED_FINDINGS)\" == '2' ]]"
assert "constants_json has STUCK_RELEASE_ALERT_HOURS == '4'" "[[ \"\$(echo '$JSON_STRING' | jq -r .STUCK_RELEASE_ALERT_HOURS)\" == '4' ]]"
assert "constants_json has APPROVAL_STALE_HOURS == '48'" "[[ \"\$(echo '$JSON_STRING' | jq -r .APPROVAL_STALE_HOURS)\" == '48' ]]"
assert "constants_json has GOVULNCHECK_VERSION == 'v1.3.0'" "[[ \"\$(echo '$JSON_STRING' | jq -r .GOVULNCHECK_VERSION)\" == 'v1.3.0' ]]"
assert "constants_json has MAX_CANDIDATE_WINDOW == '150'" "[[ \"\$(echo '$JSON_STRING' | jq -r .MAX_CANDIDATE_WINDOW)\" == '150' ]]"
assert "constants_json has INPUT_MODE_OVERRIDE == 'approve'" "[[ \"\$(echo '$JSON_STRING' | jq -r .INPUT_MODE_OVERRIDE)\" == 'approve' ]]"
assert "constants_json has EVENT_NAME == 'workflow_dispatch'" "[[ \"\$(echo '$JSON_STRING' | jq -r .EVENT_NAME)\" == 'workflow_dispatch' ]]"

assert "step summary written" "grep -q '### Auto-Release Configuration' '$SUMMARY_FILE'"
assert "step summary has effective mode" "grep -q 'Effective Mode.*approve' '$SUMMARY_FILE'"

echo "========================================="
echo "config_test: $TOTAL tests, $FAILED failed"
if (( FAILED > 0 )); then
  exit 1
fi
exit 0
