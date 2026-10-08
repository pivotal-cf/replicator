#!/usr/bin/env bash
set -euo pipefail

# collect_test.sh - Offline tests for collect.sh (fake gh, curl and sleep on PATH)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECT="${SCRIPT_DIR}/../collect.sh"
TESTDATA_DIR="${SCRIPT_DIR}/testdata"

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

CAND="cccccccccccccccccccccccccccccccccccccccc"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin"
FAKE_LOG="$TEST_TMP/calls.log"
FAKE_STATE="$TEST_TMP/state"
export TESTDATA_DIR FAKE_LOG FAKE_STATE

# Fake gh: only `gh api --hostname github.com [--paginate] <endpoint>`; any other flag or an
# endpoint without a fixture fails. With --paginate it follows rel="next" in <name>_pageN.header.
cat << 'EOF' > "$TEST_TMP/bin/gh"
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$FAKE_LOG"
[[ "${1:-}" == "api" ]] || { echo "fake gh: only 'gh api' is expected" >&2; exit 64; }
shift
paginate=0
endpoint=""
host=""
while (( $# )); do
  case "$1" in
    --hostname) host="$2"; shift 2 ;;
    --paginate) paginate=1; shift ;;
    -*) echo "fake gh: unexpected flag $1" >&2; exit 64 ;;
    *) [[ -z "$endpoint" ]] || { echo "fake gh: two endpoints" >&2; exit 64; }; endpoint="$1"; shift ;;
  esac
done
[[ "$host" == "github.com" ]] || { echo "fake gh: --hostname github.com missing" >&2; exit 64; }

if [[ -n "${FAKE_FAIL_MATCH:-}" && "$endpoint" == $FAKE_FAIL_MATCH ]]; then
  status="${FAKE_FAIL_STATUS:-404}"
  echo "{\"message\":\"HTTP ${status}\",\"status\":\"${status}\"}"
  echo "gh: HTTP ${status} (https://api.github.com/${endpoint})" >&2
  exit 1
fi

fx() { if [[ "$1" == /* ]]; then echo "$1"; else echo "$TESTDATA_DIR/$1"; fi; }
emit() {
  local f base page next
  f="$(fx "$1")"
  cat "$f"
  if (( paginate )) && [[ "$f" == *_page1.json ]]; then
    base="${f%_page1.json}"
    page=1
    while [[ -f "${base}_page${page}.header" ]]; do
      next="$(sed -n 's/.*[?&]page=\([0-9]*\)>; rel="next".*/\1/p' "${base}_page${page}.header")"
      [[ -n "$next" ]] || break
      cat "${base}_page${next}.json"
      page="$next"
    done
  fi
}
count() {
  local n
  n=$(( $(cat "$FAKE_STATE/$1" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$FAKE_STATE/$1"
  echo "$n"
}

R="repos/pivotal-cf/replicator"
C="cccccccccccccccccccccccccccccccccccccccc"
case "$endpoint" in
  "$R/releases?per_page=100") emit "${FAKE_RELEASES:-releases.json}" ;;
  "$R/git/matching-refs/tags") emit "${FAKE_TAGS:-tags.json}" ;;
  "$R/actions/workflows/ci.yml/runs?branch=master&event=push&status=success&per_page=1") emit "${FAKE_MASTER_RUNS:-workflow_runs_ci.json}" ;;
  "$R/actions/workflows/ci.yml/runs?branch=0.23.0&per_page=20")
    if [[ "$(count tag_runs)" == "1" && -n "${FAKE_TAG_RUNS_FIRST:-}" ]]; then
      emit "$FAKE_TAG_RUNS_FIRST"
    else
      emit "${FAKE_TAG_RUNS:-workflow_runs_tag.json}"
    fi
    ;;
  "$R/actions/workflows/ci.yml/runs?head_sha=${C}&event=push") emit commit_runs_ci.json ;;
  "$R/actions/workflows/ci.yml/runs?head_sha=1111111111111111111111111111111111111111&event=push") emit runs_empty.json ;;
  "$R/events?per_page=100") emit events.json ;;
  "$R/compare/${C}...master") emit "${FAKE_TAIL:-compare_tail_identical.json}" ;;
  "$R/compare/0.22.0...${C}") emit "${FAKE_FROM_LATEST:-compare_from_latest_ahead.json}" ;;
  "$R/commits/1111111111111111111111111111111111111111") emit commit_c1.json ;;
  "$R/commits/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") emit commit_brew.json ;;
  "$R/commits/${C}") emit "${FAKE_COMMIT_CAND:-commit_cand.json}" ;;
  *) echo "fake gh: no fixture for ${endpoint}" >&2; exit 65 ;;
esac
EOF

# Fake curl: prints FAKE_DOCKER_STATUS for -w '%{http_code}', or fails like a refused connection.
cat << 'EOF' > "$TEST_TMP/bin/curl"
#!/usr/bin/env bash
set -euo pipefail
echo "curl $*" >> "$FAKE_LOG"
if [[ -n "${FAKE_CURL_EXIT:-}" ]]; then
  printf '000'
  exit "$FAKE_CURL_EXIT"
fi
printf '%s' "${FAKE_DOCKER_STATUS:-200}"
EOF

# Fake sleep: records the requested duration and returns at once.
cat << 'EOF' > "$TEST_TMP/bin/sleep"
#!/usr/bin/env bash
echo "sleep $*" >> "$FAKE_LOG"
EOF
chmod +x "$TEST_TMP/bin/gh" "$TEST_TMP/bin/curl" "$TEST_TMP/bin/sleep"
export PATH="$TEST_TMP/bin:$PATH"

# collect_case <desc> <want exit> <out> [VAR=value...]: run collect.sh with the happy-path
# environment (workflow_run of the candidate), overridden by the VAR=value arguments.
collect_case() {
  local desc="$1" want="$2" out="$3" rc=0
  shift 3
  rm -rf "$FAKE_STATE"
  mkdir -p "$FAKE_STATE"
  : > "$FAKE_LOG"
  env -u REPO GITHUB_REPOSITORY=pivotal-cf/replicator EVENT_NAME=workflow_run WORKFLOW_RUN_HEAD_SHA="$CAND" \
    MAX_CANDIDATE_WINDOW=100 NOW_OVERRIDE=2026-06-12T00:00:00Z "$@" \
    bash "$COLLECT" "$out" > "$TEST_TMP/stdout" 2> "$TEST_TMP/stderr" || rc=$?
  TOTAL=$(( TOTAL + 1 ))
  if [[ "$rc" == "$want" ]]; then
    echo "PASS: $desc (exit $rc)"
  else
    echo "FAIL: $desc (exit $rc, want $want)"
    sed 's/^/    /' "$TEST_TMP/stderr"
    FAILED=$(( FAILED + 1 ))
  fi
}

# Helpers for assert conditions (called through eval).
# shellcheck disable=SC2329
calls() { grep -c -F -- "$1" "$FAKE_LOG" || true; }
# shellcheck disable=SC2329
q() { jq -c "$2" "$1" 2>/dev/null; }

echo "=== happy path: facts.json matches the 5.9 contract exactly ==="
OUT="$TEST_TMP/happy.json"
collect_case "workflow_run with a tag above latest and a brew-only tail" 0 "$OUT" \
  FAKE_TAGS=tags_above.json FAKE_TAIL=compare_tail_ahead_brew.json
assert "facts.json equals testdata/collect_expected_facts.json" \
  "diff <(jq -S . '$OUT') <(jq -S . '$TESTDATA_DIR/collect_expected_facts.json')"
assert "releases and tags are listed with --paginate" \
  "[[ \$(calls 'api --hostname github.com --paginate repos/pivotal-cf/replicator/releases?per_page=100') == 1 && \$(calls '--paginate repos/pivotal-cf/replicator/git/matching-refs/tags') == 1 ]]"
assert "Docker Hub is queried for the latest tag with the LLDD curl command" \
  "[[ \$(calls 'curl -s -o /dev/null -w %{http_code} https://hub.docker.com/v2/repositories/pivotalcfreleng/replicator/tags/0.22.0') == 1 ]]"
assert "tag runs found on first query: one query, no sleep" \
  "[[ \$(calls 'runs?branch=0.23.0') == 1 && \$(calls 'sleep') == 0 ]]"
assert "workflow_run candidate does not query master runs" "[[ \$(calls 'branch=master') == 0 ]]"
assert "every gh call is a GET through 'gh api --hostname github.com'" \
  "[[ \$(grep -c '^gh ' '$FAKE_LOG') == \$(grep -c '^gh api --hostname github.com ' '$FAKE_LOG') ]]"

echo "=== pagination via Link header ==="
OUT="$TEST_TMP/paged.json"
collect_case "releases and tags split over two pages" 0 "$OUT" \
  FAKE_RELEASES=releases_page1.json FAKE_TAGS=tags_page1.json
assert "latest comes from page 2 of releases" "[[ \$(q '$OUT' .latest.tag) == '\"0.22.0\"' ]]"
assert "both release pages merged" "[[ \$(q '$OUT' '[.releases[].tag]') == '[\"0.22.0\",\"0.21.0\"]' ]]"
assert "latest tag commit comes from page 2 of tags" \
  "[[ \$(q '$OUT' .latest.tag_commit) == '\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"' ]]"

echo "=== API failures (403/404/garbage) fail closed with exit 3 ==="
collect_case "403 on releases" 3 "$TEST_TMP/x.json" FAKE_FAIL_MATCH='*/releases*' FAKE_FAIL_STATUS=403
collect_case "404 on matching-refs" 3 "$TEST_TMP/x.json" FAKE_FAIL_MATCH='*/matching-refs/*'
collect_case "403 on tag runs" 3 "$TEST_TMP/x.json" FAKE_TAGS=tags_above.json FAKE_FAIL_MATCH='*runs?branch=0.23.0*' FAKE_FAIL_STATUS=403
collect_case "404 on events" 3 "$TEST_TMP/x.json" FAKE_TAGS=tags_above.json FAKE_FAIL_MATCH='*/events*'
collect_case "404 on compare candidate...master" 3 "$TEST_TMP/x.json" FAKE_FAIL_MATCH='*...master'
collect_case "404 on compare latest...candidate" 3 "$TEST_TMP/x.json" FAKE_FAIL_MATCH='*/compare/0.22.0...*'
collect_case "403 on commit files" 3 "$TEST_TMP/x.json" FAKE_FAIL_MATCH='*/commits/*' FAKE_FAIL_STATUS=403
collect_case "404 on push-time runs" 3 "$TEST_TMP/x.json" FAKE_FAIL_MATCH='*head_sha=*'
printf 'not json\n' > "$TEST_TMP/garbage.json"
collect_case "unparseable compare body" 3 "$TEST_TMP/x.json" FAKE_TAIL="$TEST_TMP/garbage.json"
printf '{"message":"ok"}\n' > "$TEST_TMP/object.json"
collect_case "object where a list is expected" 3 "$TEST_TMP/x.json" FAKE_RELEASES="$TEST_TMP/object.json"
collect_case "runs response without workflow_runs" 3 "$TEST_TMP/x.json" EVENT_NAME=schedule FAKE_MASTER_RUNS="$TEST_TMP/object.json"
printf '{"status":"weird","total_commits":0,"commits":[]}\n' > "$TEST_TMP/weird.json"
collect_case "unknown compare status" 3 "$TEST_TMP/x.json" FAKE_TAIL="$TEST_TMP/weird.json"
assert "no facts.json written on failure" "[[ ! -e '$TEST_TMP/x.json' ]]"

echo "=== anomalies fail closed with exit 2 ==="
collect_case "candidate commit lists 300 files (truncated)" 2 "$TEST_TMP/x.json" FAKE_COMMIT_CAND=commit_truncated.json
collect_case "compare lists fewer commits than total_commits" 2 "$TEST_TMP/x.json" FAKE_FROM_LATEST=compare_from_latest_truncated.json
collect_case "window larger than MAX_CANDIDATE_WINDOW" 2 "$TEST_TMP/x.json" MAX_CANDIDATE_WINDOW=1
collect_case "window equal to MAX_CANDIDATE_WINDOW is fine" 0 "$TEST_TMP/w.json" MAX_CANDIDATE_WINDOW=2
collect_case "semver tag that is annotated" 2 "$TEST_TMP/x.json" FAKE_TAGS=tags_annotated.json
printf '%s\n' "$(jq -c '[.[0]]' "$TESTDATA_DIR/tags.json")" > "$TEST_TMP/tags_no_latest.json"
collect_case "latest release without a tag ref" 2 "$TEST_TMP/x.json" FAKE_TAGS="$TEST_TMP/tags_no_latest.json"
printf '[]\n' > "$TEST_TMP/empty_list.json"
collect_case "no published semver release" 2 "$TEST_TMP/x.json" FAKE_RELEASES="$TEST_TMP/empty_list.json"
collect_case "schedule with no green master-push run" 2 "$TEST_TMP/x.json" EVENT_NAME=schedule FAKE_MASTER_RUNS=runs_empty.json

echo "=== inputs are validated (exit 2) ==="
collect_case "workflow_run without a head sha" 2 "$TEST_TMP/x.json" WORKFLOW_RUN_HEAD_SHA=
collect_case "workflow_run with an abbreviated head sha" 2 "$TEST_TMP/x.json" WORKFLOW_RUN_HEAD_SHA=ccccccc
collect_case "unknown EVENT_NAME" 2 "$TEST_TMP/x.json" EVENT_NAME=push
collect_case "missing repository" 2 "$TEST_TMP/x.json" GITHUB_REPOSITORY=
collect_case "MAX_CANDIDATE_WINDOW 0" 2 "$TEST_TMP/x.json" MAX_CANDIDATE_WINDOW=0
collect_case "MAX_CANDIDATE_WINDOW 251" 2 "$TEST_TMP/x.json" MAX_CANDIDATE_WINDOW=251
collect_case "MAX_CANDIDATE_WINDOW not a number" 2 "$TEST_TMP/x.json" MAX_CANDIDATE_WINDOW=ten
collect_case "TAG_RUNS_REQUERY_SLEEP not a number" 2 "$TEST_TMP/x.json" TAG_RUNS_REQUERY_SLEEP=2m

echo "=== Docker Hub status ==="
OUT="$TEST_TMP/docker404.json"
collect_case "404 (image missing) is recorded, not fatal" 0 "$OUT" FAKE_DOCKER_STATUS=404
assert "docker.http is 404" "[[ \$(q '$OUT' .docker) == '{\"tag\":\"0.22.0\",\"http\":404}' ]]"
collect_case "500 fails closed" 3 "$TEST_TMP/x.json" FAKE_DOCKER_STATUS=500
collect_case "429 fails closed" 3 "$TEST_TMP/x.json" FAKE_DOCKER_STATUS=429
collect_case "301 fails closed" 3 "$TEST_TMP/x.json" FAKE_DOCKER_STATUS=301
collect_case "transport error fails closed" 3 "$TEST_TMP/x.json" FAKE_CURL_EXIT=7

echo "=== tag runs: 120 s re-query when a tag above latest has no run ==="
OUT="$TEST_TMP/requery.json"
collect_case "no run at first, runs on re-query" 0 "$OUT" FAKE_TAGS=tags_above.json FAKE_TAG_RUNS_FIRST=runs_empty.json
assert "slept the default 120 s once" "[[ \$(grep '^sleep' '$FAKE_LOG') == 'sleep 120' ]]"
assert "queried the tag runs twice" "[[ \$(calls 'runs?branch=0.23.0') == 2 ]]"
assert "tag_runs holds the re-queried runs" "[[ \$(q '$OUT' '[.tag_runs[\"0.23.0\"][].id]') == '[2002,2001]' ]]"
collect_case "sleep is injectable" 0 "$OUT" FAKE_TAGS=tags_above.json FAKE_TAG_RUNS_FIRST=runs_empty.json TAG_RUNS_REQUERY_SLEEP=0
assert "slept TAG_RUNS_REQUERY_SLEEP seconds" "[[ \$(grep '^sleep' '$FAKE_LOG') == 'sleep 0' ]]"
OUT="$TEST_TMP/norun.json"
collect_case "still no run after the re-query" 0 "$OUT" FAKE_TAGS=tags_above.json FAKE_TAG_RUNS=runs_empty.json
assert "tag_runs is empty for the tag" "[[ \$(q '$OUT' '.tag_runs') == '{\"0.23.0\":[]}' ]]"
assert "tag_events has the tag CreateEvent (not the branch one)" "[[ \$(q '$OUT' '.tag_events') == '{\"0.23.0\":\"2026-06-11T11:00:00Z\"}' ]]"
OUT="$TEST_TMP/notag.json"
collect_case "no tag above latest" 0 "$OUT"
assert "tag_runs and tag_events are empty" "[[ \$(q '$OUT' '[.tag_runs, .tag_events]') == '[{},{}]' ]]"
assert "no runs, events or sleep queried" "[[ \$(calls 'runs?branch=') == 0 && \$(calls '/events') == 0 && \$(calls 'sleep') == 0 ]]"
assert "identical tail has no commits" "[[ \$(q '$OUT' '.candidate.tail_after_candidate') == '{\"status\":\"identical\",\"commits\":[]}' ]]"

echo "=== candidate selection ==="
OUT="$TEST_TMP/schedule.json"
collect_case "schedule uses the newest green master-push ci run" 0 "$OUT" EVENT_NAME=schedule WORKFLOW_RUN_HEAD_SHA=
assert "candidate from the master run, source schedule" \
  "[[ \$(q '$OUT' '[.trigger, .candidate.source, .candidate.sha]') == '[\"schedule\",\"schedule\",\"$CAND\"]' ]]"
assert "master runs queried with the LLDD filter" \
  "[[ \$(calls 'runs?branch=master&event=push&status=success&per_page=1') == 1 ]]"
OUT="$TEST_TMP/dispatch.json"
collect_case "workflow_dispatch also uses the master run" 0 "$OUT" EVENT_NAME=workflow_dispatch
assert "trigger workflow_dispatch, source schedule" \
  "[[ \$(q '$OUT' '[.trigger, .candidate.source]') == '[\"workflow_dispatch\",\"schedule\"]' ]]"
OUT="$TEST_TMP/diverged.json"
collect_case "diverged candidate is recorded without fetching its commits" 0 "$OUT" FAKE_FROM_LATEST=compare_from_latest_diverged.json
assert "from_latest diverged with no commits" "[[ \$(q '$OUT' '.candidate.from_latest') == '{\"status\":\"diverged\",\"commits\":[]}' ]]"

echo ""
echo "collect_test: $TOTAL tests, $FAILED failed"
if (( FAILED > 0 )); then
  exit 1
fi
exit 0
