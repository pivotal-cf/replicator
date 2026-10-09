#!/usr/bin/env bash
set -euo pipefail

# notify_test.sh - Unit tests for notify.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY_SH="${SCRIPT_DIR}/../notify.sh"

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
rest=""
is_write=0
for a in "$@"; do
  if [[ "$a" == "-f" || "$a" == "-F" || "$a" == "-X" || "$a" =~ ^--field || "$a" =~ ^-X ]]; then
    is_write=1
  fi
  if [[ -z "$endpoint" && "$a" =~ ^repos/ ]]; then
    endpoint="$a"
  elif [[ -n "$endpoint" ]]; then
    rest+=" $a"
  fi
done

if (( is_write )); then
  echo "API_WRITE: $endpoint$rest" >> "$TEST_TMP/gh_writes.log"
fi

if [[ "$endpoint" =~ repos/[^/]+/[^/]+/labels/auto-release$ ]]; then
  if [[ -f "$TEST_TMP/label_exists" ]]; then
    echo '{"name":"auto-release"}'
    exit 0
  else
    echo "Not Found" >&2
    exit 1
  fi
fi

if [[ "$endpoint" =~ repos/[^/]+/[^/]+/labels$ ]]; then
  echo '{"name":"auto-release"}'
  exit 0
fi

if [[ "$endpoint" =~ repos/[^/]+/[^/]+/issues\? ]]; then
  if [[ -f "$TEST_TMP/issues_page1.json" ]]; then
    cat "$TEST_TMP/issues_page1.json"
    if [[ -f "$TEST_TMP/issues_page2.json" ]]; then
      cat "$TEST_TMP/issues_page2.json"
    fi
    exit 0
  fi
  if [[ -f "$TEST_TMP/open_issues.json" ]]; then
    cat "$TEST_TMP/open_issues.json"
    exit 0
  fi
  echo "[]"
  exit 0
fi

if [[ "$endpoint" =~ repos/[^/]+/[^/]+/issues$ ]] && (( is_write )); then
  echo '{"number":42,"title":"created issue"}'
  exit 0
fi

if [[ "$endpoint" =~ repos/[^/]+/[^/]+/issues/[0-9]+$ ]] && (( is_write )); then
  echo '{"number":1,"state":"closed"}'
  exit 0
fi

if [[ "$endpoint" =~ repos/[^/]+/[^/]+/issues/[0-9]+/comments$ ]] && (( is_write )); then
  echo '{"id":101,"body":"commented"}'
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
  export ISSUE_KIND="release"
  export ISSUE_TITLE="[auto-release] release 0.23.0 warranted"
  export ISSUE_BODY="Release details here"
  export CLOSE_TITLES="[]"
  export GITHUB_STEP_SUMMARY="$TEST_TMP/summary.txt"

  rm -f "$TEST_TMP/gh_calls.log" "$TEST_TMP/gh_writes.log" "$TEST_TMP/open_issues.json" \
        "$TEST_TMP/issues_page1.json" "$TEST_TMP/issues_page2.json" \
        "$TEST_TMP/label_exists" "$TEST_TMP/summary.txt"
  echo "[]" > "$TEST_TMP/open_issues.json"
}

echo "=== Testing CLI_RELEASE_WRITE refusal ==="
setup_env
export CLI_RELEASE_WRITE=0
assert_rc "notify.sh refuses without CLI_RELEASE_WRITE=1" 2 "bash '$NOTIFY_SH'"

echo "=== Testing Input Validations ==="
setup_env
export REPO="invalid/repo"
assert_rc "notify.sh refuses invalid repo allowlist" 2 "bash '$NOTIFY_SH'"

setup_env
export CLOSE_TITLES="invalid-json"
assert_rc "notify.sh refuses malformed CLOSE_TITLES" 2 "bash '$NOTIFY_SH'"

echo "=== Testing Label Creation ==="
setup_env
# Label does not exist
assert_rc "notify.sh succeeds when label needs creation" 0 "bash '$NOTIFY_SH'"
assert "fake gh created label auto-release" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/labels' '$TEST_TMP/gh_writes.log'"

setup_env
touch "$TEST_TMP/label_exists"
assert_rc "notify.sh succeeds when label already exists" 0 "bash '$NOTIFY_SH'"
assert "fake gh did not recreate existing label" "! grep -q 'API_WRITE: repos/pivotal-cf/replicator/labels' '$TEST_TMP/gh_writes.log'"

echo "=== Testing Create vs Update ==="
# No open issue exists -> CREATE
setup_env
touch "$TEST_TMP/label_exists"
echo "[]" > "$TEST_TMP/open_issues.json"
assert_rc "notify.sh creates issue when none open" 0 "bash '$NOTIFY_SH'"
assert "issue was created via POST" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues -f title=\[auto-release\] release 0.23.0 warranted' '$TEST_TMP/gh_writes.log'"
assert "summary mentions created issue" "grep -q 'Created auto-release issue' '$TEST_TMP/summary.txt'"

# Open issue with exact title already exists -> UPDATE (no duplicate created)
setup_env
touch "$TEST_TMP/label_exists"
cat << 'EOF' > "$TEST_TMP/open_issues.json"
[
  {
    "number": 10,
    "title": "[auto-release] release 0.23.0 warranted",
    "body": "Old body"
  }
]
EOF
assert_rc "notify.sh updates existing issue" 0 "bash '$NOTIFY_SH'"
assert "issue 10 was updated via PATCH" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues/10 -X PATCH -f body=Release details here' '$TEST_TMP/gh_writes.log'"
assert "no new issue was created via POST" "! grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues -f title=' '$TEST_TMP/gh_writes.log'"
assert "summary mentions updated issue" "grep -q 'Updated auto-release issue #10' '$TEST_TMP/summary.txt'"

echo "=== Testing Duplicate Resolution ==="
# Multiple open issues with exact title -> Update first, close duplicate
setup_env
touch "$TEST_TMP/label_exists"
cat << 'EOF' > "$TEST_TMP/open_issues.json"
[
  {
    "number": 10,
    "title": "[auto-release] release 0.23.0 warranted",
    "body": "First open"
  },
  {
    "number": 11,
    "title": "[auto-release] release 0.23.0 warranted",
    "body": "Duplicate open"
  }
]
EOF
assert_rc "notify.sh closes duplicate issue" 0 "bash '$NOTIFY_SH'"
assert "issue 10 was updated" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues/10 -X PATCH' '$TEST_TMP/gh_writes.log'"
assert "issue 11 received duplicate comment" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues/11/comments' '$TEST_TMP/gh_writes.log'"
assert "issue 11 was closed via PATCH" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues/11 -X PATCH -f state=closed' '$TEST_TMP/gh_writes.log'"
assert "summary mentions closed duplicate" "grep -q 'Closed duplicate auto-release issue #11' '$TEST_TMP/summary.txt'"

echo "=== Testing Close Titles ==="
# Open issue matches CLOSE_TITLES -> Close with comment
setup_env
touch "$TEST_TMP/label_exists"
export CLOSE_TITLES='["[auto-release] release 0.22.0 warranted", "[auto-release] stuck release 0.21.0"]'
cat << 'EOF' > "$TEST_TMP/open_issues.json"
[
  {
    "number": 5,
    "title": "[auto-release] release 0.22.0 warranted",
    "body": "Old release issue"
  },
  {
    "number": 6,
    "title": "[auto-release] other open issue",
    "body": "Unrelated issue"
  }
]
EOF
export ISSUE_TITLE="" # No new issue to create
assert_rc "notify.sh closes titles in CLOSE_TITLES" 0 "bash '$NOTIFY_SH'"
assert "issue 5 received comment" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues/5/comments' '$TEST_TMP/gh_writes.log'"
assert "issue 5 was closed" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues/5 -X PATCH -f state=closed' '$TEST_TMP/gh_writes.log'"
assert "unrelated issue 6 was not closed" "! grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues/6' '$TEST_TMP/gh_writes.log'"

echo "=== Testing Stuck Issue Handling ==="
setup_env
touch "$TEST_TMP/label_exists"
export ISSUE_KIND="stuck"
export ISSUE_TITLE="[auto-release] stuck release 0.23.0"
export ISSUE_BODY="Stuck release detected"
assert_rc "notify.sh creates stuck issue" 0 "bash '$NOTIFY_SH'"
assert "stuck issue created" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues -f title=\[auto-release\] stuck release 0.23.0' '$TEST_TMP/gh_writes.log'"

echo "=== Testing Mode Enforcements ==="
# Mode off -> exits 0 no-op, no writes
setup_env
touch "$TEST_TMP/label_exists"
export MODE="off"
assert_rc "notify.sh exits 0 no-op in off mode" 0 "bash '$NOTIFY_SH'"
assert "no writes in off mode" "[[ ! -f '$TEST_TMP/gh_writes.log' ]]"

# Invalid MODE -> exits 2
setup_env
touch "$TEST_TMP/label_exists"
export MODE="invalid-mode"
assert_rc "notify.sh refuses invalid MODE" 2 "bash '$NOTIFY_SH'"

# Release issues ONLY permitted in notify mode
setup_env
touch "$TEST_TMP/label_exists"
export MODE="report"
export ISSUE_KIND="release"
assert_rc "notify.sh refuses release issue in report mode" 2 "bash '$NOTIFY_SH'"

setup_env
touch "$TEST_TMP/label_exists"
export MODE="approve"
export ISSUE_KIND="release"
assert_rc "notify.sh refuses release issue in approve mode" 2 "bash '$NOTIFY_SH'"

setup_env
touch "$TEST_TMP/label_exists"
export MODE="auto"
export ISSUE_KIND="release"
assert_rc "notify.sh refuses release issue in auto mode" 2 "bash '$NOTIFY_SH'"

# Stuck issues allowed in report/approve/auto modes
setup_env
touch "$TEST_TMP/label_exists"
export MODE="report"
export ISSUE_KIND="stuck"
export ISSUE_TITLE="[auto-release] stuck release 0.23.0"
export ISSUE_BODY="Stuck release detected"
assert_rc "notify.sh allows stuck issue in report mode" 0 "bash '$NOTIFY_SH'"
assert "stuck issue created in report mode" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues -f title=\[auto-release\] stuck release 0.23.0' '$TEST_TMP/gh_writes.log'"

# Close titles allowed in approve mode
setup_env
touch "$TEST_TMP/label_exists"
export MODE="approve"
export CLOSE_TITLES='["[auto-release] release 0.22.0 warranted"]'
export ISSUE_KIND=""
export ISSUE_TITLE=""
cat << 'EOF' > "$TEST_TMP/open_issues.json"
[
  {
    "number": 8,
    "title": "[auto-release] release 0.22.0 warranted",
    "body": "To close"
  }
]
EOF
assert_rc "notify.sh allows closing issues in approve mode" 0 "bash '$NOTIFY_SH'"
assert "issue closed in approve mode" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues/8 -X PATCH -f state=closed' '$TEST_TMP/gh_writes.log'"

# Release issue allowed in notify mode
setup_env
touch "$TEST_TMP/label_exists"
export MODE="notify"
export ISSUE_KIND="release"
export ISSUE_TITLE="[auto-release] release 0.23.0 warranted"
export ISSUE_BODY="Warranted release"
assert_rc "notify.sh allows release issue in notify mode" 0 "bash '$NOTIFY_SH'"
assert "release issue created in notify mode" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues -f title=\[auto-release\] release 0.23.0 warranted' '$TEST_TMP/gh_writes.log'"

echo "=== Testing Multi-page Issues Pagination (>100 open issues) ==="
setup_env
touch "$TEST_TMP/label_exists"
export MODE="notify"
export ISSUE_KIND="release"
export ISSUE_TITLE="[auto-release] release 0.23.0 warranted"
export ISSUE_BODY="Warranted release"
export CLOSE_TITLES='["[auto-release] release 0.22.0 warranted"]'

# Page 1: 100 open issues (issues 1..100), issue 50 matches CLOSE_TITLES, issue 100 has ISSUE_TITLE
issues_p1='['
for i in $(seq 1 100); do
  (( i > 1 )) && issues_p1+=','
  if (( i == 50 )); then
    issues_p1+="{\"number\":$i,\"title\":\"[auto-release] release 0.22.0 warranted\",\"body\":\"Old release\"}"
  elif (( i == 100 )); then
    issues_p1+="{\"number\":$i,\"title\":\"[auto-release] release 0.23.0 warranted\",\"body\":\"Existing target\"}"
  else
    issues_p1+="{\"number\":$i,\"title\":\"[auto-release] noise issue $i\",\"body\":\"noise\"}"
  fi
done
issues_p1+=']'
echo "$issues_p1" > "$TEST_TMP/issues_page1.json"

# Page 2: 5 open issues (issues 101..105), issue 105 also has duplicate ISSUE_TITLE
issues_p2='['
for i in $(seq 101 105); do
  (( i > 101 )) && issues_p2+=','
  if (( i == 105 )); then
    issues_p2+="{\"number\":$i,\"title\":\"[auto-release] release 0.23.0 warranted\",\"body\":\"Duplicate on page 2\"}"
  else
    issues_p2+="{\"number\":$i,\"title\":\"[auto-release] noise issue $i\",\"body\":\"noise\"}"
  fi
done
issues_p2+=']'
echo "$issues_p2" > "$TEST_TMP/issues_page2.json"

assert_rc "notify.sh handles pagination across >100 issues without error" 0 "bash '$NOTIFY_SH'"
assert "issue 50 closed from page 1" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues/50 -X PATCH -f state=closed' '$TEST_TMP/gh_writes.log'"
assert "issue 100 updated on page 1" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues/100 -X PATCH -f body=Warranted release' '$TEST_TMP/gh_writes.log'"
assert "duplicate issue 105 closed on page 2" "grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues/105 -X PATCH -f state=closed' '$TEST_TMP/gh_writes.log'"
assert "no new issue created" "! grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues -f title=' '$TEST_TMP/gh_writes.log'"

echo "=== Testing Malformed Issues Page Fails Closed ==="
setup_env
touch "$TEST_TMP/label_exists"
export MODE="notify"
export ISSUE_KIND="release"
export ISSUE_TITLE="[auto-release] release 0.23.0 warranted"
export ISSUE_BODY="Warranted release"
echo '[{"number":1,"title":"[auto-release] foo"}]' > "$TEST_TMP/issues_page1.json"
echo 'malformed-not-json' > "$TEST_TMP/issues_page2.json"
assert_rc "notify.sh fails closed on malformed issues page" 2 "bash '$NOTIFY_SH'"
assert "no issues modified on malformed page" "! grep -q 'API_WRITE: repos/pivotal-cf/replicator/issues' '$TEST_TMP/gh_writes.log' 2>/dev/null"

echo "========================================="
echo "notify_test: $TOTAL tests, $FAILED failed"
if (( FAILED > 0 )); then
  exit 1
fi
exit 0
