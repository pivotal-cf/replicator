#!/usr/bin/env bash
# test_support.sh - Shared test harness for auto-release test suites.
# Provides test accounting, assertions, hermetic temporary environment, and portability helpers.
set -euo pipefail

FAILED=0
TOTAL=0

# Create hermetic temp directory and schedule automatic cleanup on EXIT
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"
ORIG_PATH="$PATH"
export PATH="$TEST_TMP/bin:$ORIG_PATH"
export TEST_TMP ORIG_PATH

# assert <desc> <condition>: evaluate condition string in current shell/eval
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

# assert_rc <desc> <expected_exit_code> <command>: run command in subshell and assert exit code
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

# Hash a file portably across macOS and Linux.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# test_finish <suite_name>: report summary and exit with status code
test_finish() {
  local suite="${1:-test}"
  echo "========================================="
  echo "${suite}: $TOTAL tests, $FAILED failed"
  if (( FAILED > 0 )); then
    exit 1
  fi
  exit 0
}
