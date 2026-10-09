#!/usr/bin/env bash
set -euo pipefail

# decide_test.sh: offline tests for decide.sh (LLDD-A sections 5, 5.9 and 7).
# Cases run decide.sh on the hand-made fixtures in testdata/decide/, each case
# transformed by small jq filters; the replay cases build facts/scan from the
# U1 spike fixtures (testdata/release-*.json, testdata/commit-*.json, copied
# byte-identical from TNZ-113132-spike-artifacts/u1/fixtures).

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECIDE="${TESTS_DIR}/../decide.sh"
TD="${TESTS_DIR}/testdata"
BASE="${TD}/decide"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

TOTAL=0
FAILED=0
RC=0

pass() { TOTAL=$(( TOTAL + 1 )); echo "PASS: $1"; }
fail() { TOTAL=$(( TOTAL + 1 )); FAILED=$(( FAILED + 1 )); echo "FAIL: $1"; }

# eq <desc> <want> <got>
eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi
}

# ok <desc> <command...>: the command must succeed.
ok() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# no <desc> <command...>: the command must fail.
no() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}

# run_files <facts> <scan> <constants>: runs decide.sh, sets RC; outputs in $OUT.
run_files() {
  rm -f "$OUT/decision.json" "$OUT/summary.md" "$OUT/gh_output" "$OUT/step_summary"
  RC=0
  GITHUB_OUTPUT="$OUT/gh_output" GITHUB_STEP_SUMMARY="$OUT/step_summary" \
    bash "$DECIDE" "$1" "$2" "$3" "$OUT/decision.json" "$OUT/summary.md" >"$OUT/stdout" 2>"$OUT/stderr" || RC=$?
}

# run [facts filter] [scan filter] [constants filter]: base fixtures, transformed.
run() {
  jq "${1:-.}" "$BASE/facts_base.json" >"$OUT/facts.json"
  jq "${2:-.}" "$BASE/scan_base.json" >"$OUT/scan.json"
  jq "${3:-.}" "$BASE/constants_base.json" >"$OUT/constants.json"
  run_files "$OUT/facts.json" "$OUT/scan.json" "$OUT/constants.json"
}

# d [jq options] <jq filter>: reads the last decision.json.
d() { jq -r "$@" "$OUT/decision.json" 2>/dev/null || echo "<no decision.json>"; }

# expect <desc> <rc> <decision>
expect() {
  eq "$1: exit code" "$2" "$RC"
  eq "$1: decision" "$3" "$(d '.decision')"
}

# expect_invalid <desc>: exit 2 and no decision written.
expect_invalid() {
  eq "$1: exit 2" "2" "$RC"
  if [[ -e "$OUT/decision.json" ]]; then fail "$1: no decision.json"; else pass "$1: no decision.json"; fi
}

closes() { jq -e --arg t "$1" '.close_issue_titles | index($t) != null' "$OUT/decision.json"; }
output_has() { grep -qxF -- "$1" "$OUT/gh_output"; }

echo "=== base case ==="
run
expect "base" 0 RELEASE
eq "base: version minor" "0.23.0" "$(d '.version')"
eq "base: candidate_sha" "cccccccccccccccccccccccccccccccccccccccc" "$(d '.candidate_sha')"
eq "base: latest" "0.22.0" "$(d '.latest')"
eq "base: mode" "report" "$(d '.mode')"
eq "base: fixed_ids" '["GO-2026-0001","GO-2026-0002"]' "$(d -c '.fixed_ids')"
eq "base: fixed_count" "2" "$(d '.fixed_count')"
eq "base: introduced_count" "0" "$(d '.introduced_count')"
eq "base: stuck false" "false" "$(d '.stuck')"
eq "base: no issue in report mode" "null" "$(d '.issue')"
eq "base: eligible_at ignores the newer non-shipped README commit" "2026-10-06T00:00:00Z" "$(d '.eligible_at')"
eq "base: schema" "1" "$(d '.schema')"
eq "base: decision.json keys" \
  '["candidate_sha","close_issue_titles","decision","eligible_at","fixed_count","fixed_ids","introduced_count","issue","latest","mode","reason","schema","stuck","version"]' \
  "$(d -c 'keys')"

echo "=== input validation (exit 2, nothing decided) ==="
run_files "$OUT/missing.json" "$BASE/scan_base.json" "$BASE/constants_base.json"
expect_invalid "missing facts.json"
run_files "$BASE/facts_base.json" "$OUT/missing.json" "$BASE/constants_base.json"
expect_invalid "missing scan.json"
run_files "$BASE/facts_base.json" "$BASE/scan_base.json" ""
expect_invalid "missing constants"
run '.schema = 2'
expect_invalid "facts schema 2"
run . '.schema = 2'
expect_invalid "scan schema 2"
run 'del(.now)'
expect_invalid "facts without now"
run '.now = "yesterday"'
expect_invalid "facts with an invalid now"
run '.tool = "../x"'
expect_invalid "facts with an invalid tool"
run . . '.mode = "off"'
expect_invalid "constants mode off"
run . . 'del(.mode)'
expect_invalid "constants without mode"
run . . '.MIN_FIXED_FINDINGS = "abc"'
expect_invalid "constants MIN_FIXED_FINDINGS not an integer"
run . . 'del(.COOLDOWN_HOURS)'
expect_invalid "constants without COOLDOWN_HOURS"
run . . '.VERSION_BUMP = "major"'
expect_invalid "constants VERSION_BUMP major"
run . . '.INTRODUCED_POLICY = "ignore"'
expect_invalid "constants INTRODUCED_POLICY unknown"
run '.latest.published_at = null'
expect_invalid "latest without published_at"
run '.releases += [{"tag": "0.23.0", "draft": false, "prerelease": false, "published_at": "2026-10-02T00:00:00Z", "assets": []}]'
expect_invalid "latest is not the newest published release"
run '.releases[0].assets |= map(select(.name != "checksums.txt"))'
expect_invalid "latest release lacks checksums.txt"
run '.releases[0].assets[0].digest = null'
expect_invalid "missing digest of the linux asset"
run '.releases[0].assets[0].digest = "sha256:xyz"'
expect_invalid "malformed digest of the linux asset"
run '.releases[0].assets[0].digest = "sha256:ABC"' '.latest.asset_sha256 = "ABC"'
expect_invalid "non-sha256 digest even when the scan agrees"
run '.tags |= map(select(.name != "0.22.0"))'
expect_invalid "latest without a tag"
run '.docker.http = 500'
expect_invalid "docker status 500"
run '.docker.tag = "0.21.0"'
expect_invalid "docker status for another tag"
run . '.latest.digest_ok = false'
expect_invalid "scan digest_ok false"
run . '.latest.asset_sha256 = "2222222222222222222222222222222222222222222222222222222222222222"'
expect_invalid "scanned sha256 differs from the API digest"
run . '.latest.db_last_modified = "2026-10-06T00:00:00Z"'
expect_invalid "DB timestamp mismatch (db_rerun false)"
run . '.latest.db_last_modified = "2026-10-06T00:00:00Z" | .db_rerun = true'
expect_invalid "DB timestamp mismatch after a re-run"
run . 'del(.candidate.db_last_modified)'
expect_invalid "DB timestamp missing"
run . '.db_rerun = "no"'
expect_invalid "db_rerun not a boolean"
run . '.candidate.findings = "GO-2026-0003"'
expect_invalid "findings not an array"
run '.tags += [{"name": 5, "object_type": "commit"}]'
expect_invalid "malformed facts (jq failure maps to exit 2)"
run . '.db_rerun = true'
expect "DB timestamps equal after a re-run" 0 RELEASE

echo "=== constants as JSON text (the config job output) ==="
rm -f "$OUT/decision.json"
RC=0
CONSTANTS_JSON="$(jq -c . "$BASE/constants_base.json")" DECISION_JSON="$OUT/decision.json" SUMMARY_MD="$OUT/summary.md" \
  bash "$DECIDE" "$BASE/facts_base.json" "$BASE/scan_base.json" >/dev/null 2>&1 || RC=$?
expect "constants_json passed via env" 0 RELEASE

echo "=== STOP: lightweight-tag violation ==="
run '.tags += [{"name": "0.20.0", "object_type": "tag"}]'
expect "annotated semver tag" 2 STOP
ok "annotated semver tag: reason names the tag" grep -q "0.20.0" "$OUT/summary.md"
run '.tags += [{"name": "nightly", "object_type": "tag"}]'
expect "annotated non-semver tag is ignored" 0 RELEASE

echo "=== STOP: latest release without Docker image ==="
run '.docker.http = 404 | .now = "2026-10-01T01:00:00Z"'
expect "image missing, young" 0 STOP
eq "image missing, young: not stuck" "false" "$(d '.stuck')"
eq "image missing, young: no issue" "null" "$(d '.issue')"
run '.docker.http = 404 | .now = "2026-10-01T02:00:00Z"'
expect "image missing, at the threshold" 0 STOP
eq "image missing, at the threshold: stuck" "true" "$(d '.stuck')"
eq "image missing: issue kind" "stuck" "$(d '.issue.kind')"
eq "image missing: issue title" "[auto-release] stuck release 0.22.0 (image missing)" "$(d '.issue.title')"
no "image missing: does not close its own issue" closes "[auto-release] stuck release 0.22.0 (image missing)"
ok "image missing: output stuck=true" output_has "stuck=true"
ok "image missing: output issue_kind=stuck" output_has "issue_kind=stuck"

echo "=== STOP: tag above latest (in flight / stuck) ==="
ABOVE='.tags += [{"name": "0.23.0", "object_type": "commit"}]'
for st in queued in_progress waiting; do
  run "$ABOVE"' | .tag_runs["0.23.0"] = [{"id": 1, "event": "workflow_dispatch", "status": "'"$st"'", "conclusion": null, "created_at": "2026-10-01T00:00:00Z"}]'
  expect "tag above, run $st" 0 STOP
  eq "tag above, run $st: not stuck" "false" "$(d '.stuck')"
  ok "tag above, run $st: release in flight" grep -q "release in flight" "$OUT/summary.md"
done
run "$ABOVE"' | .tag_runs["0.23.0"] = [{"id": 1, "event": "push", "status": "completed", "conclusion": "failure", "created_at": "2026-10-07T11:00:00Z"}]'
expect "tag above, failed run 1 h old" 0 STOP
eq "tag above, failed run 1 h old: not stuck" "false" "$(d '.stuck')"
eq "tag above, failed run 1 h old: no issue" "null" "$(d '.issue')"
run "$ABOVE"' | .tag_runs["0.23.0"] = [{"id": 2, "event": "push", "status": "completed", "conclusion": "failure", "created_at": "2026-10-07T11:00:00Z"}, {"id": 1, "event": "push", "status": "completed", "conclusion": "failure", "created_at": "2026-10-07T09:00:00Z"}]'
expect "tag above, earliest failed run 3 h old" 0 STOP
eq "tag above, stuck" "true" "$(d '.stuck')"
eq "tag above, stuck: issue kind" "stuck" "$(d '.issue.kind')"
eq "tag above, stuck: issue title" "[auto-release] stuck release 0.23.0" "$(d '.issue.title')"
eq "tag above, stuck: version null" "null" "$(d '.version')"
ok "tag above, stuck: closes the release issue of the tagged version" closes "[auto-release] release 0.23.0 warranted"
no "tag above, stuck: does not close its own issue" closes "[auto-release] stuck release 0.23.0"
run "$ABOVE"' | .tag_runs["0.23.0"] = [{"id": 1, "event": "push", "status": "completed", "conclusion": "failure", "created_at": "2026-10-07T10:00:00Z"}]'
eq "tag above, failed run exactly at the threshold: stuck" "true" "$(d '.stuck')"
run "$ABOVE"' | .tag_runs["0.23.0"] = [{"id": 1, "event": "push", "status": "completed", "conclusion": "failure", "created_at": "2026-10-07T10:00:01Z"}]'
eq "tag above, failed run 1 s under the threshold: not stuck" "false" "$(d '.stuck')"
run "$ABOVE"' | .tag_events["0.23.0"] = "2026-10-07T11:30:00Z"'
expect "tag above, no run, CreateEvent 30 min old" 0 STOP
eq "tag above, CreateEvent young: not stuck" "false" "$(d '.stuck')"
run "$ABOVE"' | .tag_events["0.23.0"] = "2026-10-07T08:00:00Z"'
eq "tag above, CreateEvent 4 h old: stuck" "true" "$(d '.stuck')"
run '.tags += [{"name": "0.23.0", "object_type": "commit", "committer_date": "2026-10-07T11:00:00Z"}] | .tag_events["0.23.0"] = null'
eq "tag above, only a young committer date: not stuck" "false" "$(d '.stuck')"
run '.tags += [{"name": "0.23.0", "object_type": "commit", "committer_date": "2026-10-06T00:00:00Z"}]'
eq "tag above, only an old committer date: stuck" "true" "$(d '.stuck')"
run "$ABOVE"
expect "tag above, nothing to age it" 0 STOP
eq "tag above, nothing to age it: stuck" "true" "$(d '.stuck')"
run "$ABOVE"' | .tags += [{"name": "0.24.0", "object_type": "commit"}] | .tag_runs["0.24.0"] = [{"id": 3, "event": "push", "status": "in_progress", "conclusion": null, "created_at": "2026-10-07T11:59:00Z"}]'
expect "two tags above, one stuck and one running" 0 STOP
eq "two tags above: in flight wins (not stuck)" "false" "$(d '.stuck')"
run "$ABOVE"' | .tag_runs["0.23.0"] = [{"id": 1, "event": "push", "status": "completed", "conclusion": "failure", "created_at": "2026-10-07T09:00:00Z"}]' . '.mode = "notify"'
eq "stuck issue in notify mode too" "stuck" "$(d '.issue.kind')"

echo "=== NO_TAG: commits after the candidate ==="
TAIL='.candidate.tail_after_candidate.status = "ahead" | .candidate.tail_after_candidate.commits = '
run "$TAIL"'[{"sha": "d1", "files": ["HomebrewFormula/replicator.rb"], "files_truncated": false}]'
expect "brew-only tail" 0 RELEASE
run "$TAIL"'[{"sha": "d1", "files": ["HomebrewFormula/replicator.rb"], "files_truncated": false}, {"sha": "d2", "files": ["HomebrewFormula/other.rb"], "files_truncated": false}]'
expect "two brew-only tail commits" 0 RELEASE
run "$TAIL"'[{"sha": "d1", "files": ["main.go"], "files_truncated": false}]'
expect "non-brew tail commit" 0 NO_TAG
eq "non-brew tail commit: no version" "null" "$(d '.version')"
run "$TAIL"'[{"sha": "d1", "files": ["HomebrewFormula/replicator.rb", "README.md"], "files_truncated": false}]'
expect "brew commit that also touches README.md is not brew" 0 NO_TAG
run "$TAIL"'[{"sha": "d1", "files": ["HomebrewFormula/sub/replicator.rb"], "files_truncated": false}]'
expect "formula in a subdirectory is not brew" 0 NO_TAG
run "$TAIL"'[{"sha": "d1", "files": ["HomebrewFormula/replicator.rb.orig"], "files_truncated": false}]'
expect "non-.rb file under HomebrewFormula is not brew" 0 NO_TAG
run "$TAIL"'[{"sha": "d1", "files": [], "files_truncated": false}]'
expect "tail commit with no files" 0 NO_TAG
run "$TAIL"'[{"sha": "d1", "files": ["HomebrewFormula/replicator.rb"], "files_truncated": true}]'
expect "tail commit with a truncated file list" 0 NO_TAG
run "$TAIL"'[{"sha": "d1", "files": ["HomebrewFormula/replicator.rb"], "files_truncated": false}, {"sha": "d2", "files": ["go.sum"], "files_truncated": false}]'
expect "brew commit followed by a non-brew one" 0 NO_TAG
run '.candidate.tail_after_candidate.status = "behind"'
expect "master behind the candidate" 0 NO_TAG
run "$TAIL"'[]'
expect_invalid "master ahead with no commits listed"
run '.candidate.tail_after_candidate.status = "weird"'
expect_invalid "unknown tail status"
run '.candidate.sha = "not-a-sha"'
expect_invalid "invalid candidate sha"

echo "=== NO_CHANGE / STOP: candidate vs latest ==="
run '.candidate.from_latest = {"status": "identical", "commits": []}'
expect "candidate identical to latest" 0 NO_CHANGE
run '.candidate.from_latest = {"status": "behind", "commits": []}'
expect "candidate behind latest" 0 NO_CHANGE
run '.candidate.from_latest.commits = []'
expect "candidate ahead with no commits" 0 NO_CHANGE
eq "NO_CHANGE: fixed_count stays 0" "0" "$(d '.fixed_count')"
run '.candidate.from_latest = {"status": "diverged", "commits": []}'
expect "candidate diverged from latest" 2 STOP
ok "diverged: summary written" grep -q "diverged" "$OUT/summary.md"
run '.candidate.from_latest.status = "unknown"'
expect_invalid "unknown from_latest status"
run . . '.MAX_CANDIDATE_WINDOW = "1"'
expect_invalid "window larger than MAX_CANDIDATE_WINDOW"
run . . '.MAX_CANDIDATE_WINDOW = "2"'
expect "window equal to MAX_CANDIDATE_WINDOW" 0 RELEASE

echo "=== NO_RELEASE / RELEASE: fixed and introduced ==="
run . '.candidate.findings = .latest.findings'
expect "fixed 0" 0 NO_RELEASE
eq "fixed 0: fixed_count" "0" "$(d '.fixed_count')"
eq "fixed 0: version null" "null" "$(d '.version')"
ok "fixed 0: closes the release issue of the next version" closes "[auto-release] release 0.23.0 warranted"
run . '.candidate.findings = ["GO-2026-0002", "GO-2026-0003"]' '.MIN_FIXED_FINDINGS = "2"'
expect "fixed 1 below MIN_FIXED_FINDINGS 2" 0 NO_RELEASE
run . . '.MIN_FIXED_FINDINGS = "2"'
expect "fixed 2 meets MIN_FIXED_FINDINGS 2" 0 RELEASE
run . '.candidate.findings = ["GO-2026-0003", "GO-2026-0009"]'
expect "introduced under block" 0 NO_RELEASE
eq "introduced under block: reason" "candidate introduces 1 findings" "$(d '.reason')"
eq "introduced under block: counts" "2/1" "$(d '"\(.fixed_count)/\(.introduced_count)"')"
no "introduced under block: summary never names the introduced id" grep -q "GO-2026-0009" "$OUT/summary.md"
run . '.candidate.findings = ["GO-2026-0003", "GO-2026-0009"]' '.INTRODUCED_POLICY = "allow"'
expect "introduced under allow" 0 RELEASE
eq "introduced under allow: introduced_count" "1" "$(d '.introduced_count')"
run . '.candidate.findings = ["GO-2026-0001", "GO-2026-0002", "GO-2026-0003", "GO-2026-0009"]' '.INTRODUCED_POLICY = "allow"'
expect "introduced under allow but fixed 0" 0 NO_RELEASE
run . '.latest.findings = ["GO-2026-0001", "GO-2026-0001", "GO-2026-0003"]'
eq "duplicate ids count once" "1" "$(d '.fixed_count')"

echo "=== WAIT: pacing ==="
run '.candidate.from_latest.commits[0].push_time = "2026-10-07T00:00:00Z"'
expect "cooldown not elapsed" 0 WAIT
eq "cooldown: eligible_at = push + 24 h" "2026-10-08T00:00:00Z" "$(d '.eligible_at')"
eq "cooldown: version" "0.23.0" "$(d '.version')"
ok "WAIT closes a stale release issue" closes "[auto-release] release 0.23.0 warranted"
run '.latest.published_at = "2026-10-06T12:00:00Z" | .releases[0].published_at = "2026-10-06T12:00:00Z"'
expect "minimum interval not elapsed" 0 WAIT
eq "interval: eligible_at = published + 3 d" "2026-10-09T12:00:00Z" "$(d '.eligible_at')"
run '.candidate.from_latest.commits[0].push_time = null | .candidate.from_latest.commits[0].committer_date = "2026-10-07T01:30:00Z"'
expect "push_time missing: committer date" 0 WAIT
eq "push_time fallback: eligible_at = committer date + 24 h" "2026-10-08T01:30:00Z" "$(d '.eligible_at')"
run '.candidate.from_latest.commits[1].files = ["cmd/foo_test.go"] | .candidate.from_latest.commits[1].push_time = "2026-10-07T11:00:00Z"'
expect "newer _test.go commit is not shipped" 0 RELEASE
run '.candidate.from_latest.commits[1].files = ["cmd/foo.go"] | .candidate.from_latest.commits[1].push_time = "2026-10-07T11:00:00Z"'
expect "newer .go commit is shipped" 0 WAIT
for f in go.mod go.sum Dockerfile .goreleaser.yml; do
  run '.candidate.from_latest.commits[1].files = ["'"$f"'"] | .candidate.from_latest.commits[1].push_time = "2026-10-07T11:00:00Z"'
  eq "newer $f commit is shipped" "WAIT" "$(d '.decision')"
done
run '.candidate.from_latest.commits[1].files = ["docs/go.mod"] | .candidate.from_latest.commits[1].push_time = "2026-10-07T11:00:00Z"'
eq "docs/go.mod is not a shipped input" "RELEASE" "$(d '.decision')"
run '.candidate.from_latest.commits |= map(.files = ["README.md"]) | .candidate.from_latest.commits[1].push_time = "2026-10-07T11:00:00Z"'
expect "no shipped commit: the newest commit paces" 0 WAIT
run . . '.COOLDOWN_HOURS = "0" | .MIN_RELEASE_INTERVAL_DAYS = "0"'
eq "zero pacing: eligible_at = newest shipped push" "2026-10-05T00:00:00Z" "$(d '.eligible_at')"
run '.candidate.from_latest.commits[0].files_truncated = true'
expect_invalid "truncated file list in the window"
run '.candidate.from_latest.commits[0].files = [range(300) | "f\(.).go"]'
expect_invalid "300 files in a window commit"
run '.candidate.from_latest.commits[0].push_time = null | .candidate.from_latest.commits[0].committer_date = null'
expect_invalid "window commit without any timestamp"

echo "=== version ==="
run . . '.VERSION_BUMP = "patch"'
eq "patch bump" "0.22.1" "$(d '.version')"
# shellcheck source=.github/auto-release/decide.sh
source "$DECIDE"
eq "next_version minor" "1.10.0" "$(next_version 1.9.3 minor '[]')"
eq "next_version patch" "1.9.4" "$(next_version 1.9.3 patch '[]')"
RC=0
( next_version 0.22.0 minor '[{"name": "0.23.0"}]' ) >/dev/null 2>&1 || RC=$?
eq "next_version: version already exists => exit 2" "2" "$RC"
RC=0
( next_version 0.22.0 patch '[{"name": "0.22.1"}]' ) >/dev/null 2>&1 || RC=$?
eq "next_version patch: version already exists => exit 2" "2" "$RC"

echo "=== issues by mode ==="
run . . '.mode = "notify"'
expect "notify RELEASE" 0 RELEASE
eq "notify: issue kind" "release" "$(d '.issue.kind')"
eq "notify: issue title" "[auto-release] release 0.23.0 warranted" "$(d '.issue.title')"
ok "notify: body has the version" grep -q "0.23.0" <<<"$(d '.issue.body')"
ok "notify: body has the candidate" grep -q "cccccccccccccccccccccccccccccccccccccccc" <<<"$(d '.issue.body')"
ok "notify: body has the fixed ids" grep -q "GO-2026-0001, GO-2026-0002" <<<"$(d '.issue.body')"
ok "notify: body has eligible_at" grep -q "2026-10-06T00:00:00Z" <<<"$(d '.issue.body')"
no "notify: body never names residual findings" grep -q "GO-2026-0003" <<<"$(d '.issue.body')"
no "notify: does not close its own issue" closes "[auto-release] release 0.23.0 warranted"
ok "notify: output issue_kind=release" output_has "issue_kind=release"
ok "notify: output issue_title" output_has "issue_title=[auto-release] release 0.23.0 warranted"
for m in report approve auto; do
  run . . ".mode = \"$m\""
  eq "$m RELEASE: no issue" "null" "$(d '.issue')"
  eq "$m RELEASE: mode recorded" "$m" "$(d '.mode')"
done
run . '.candidate.findings = .latest.findings' '.mode = "notify"'
eq "notify NO_RELEASE: no issue" "null" "$(d '.issue')"
run '.candidate.from_latest.commits[0].push_time = "2026-10-07T00:00:00Z"' . '.mode = "notify"'
eq "notify WAIT: no issue" "null" "$(d '.issue')"

echo "=== close_issue_titles ==="
run
ok "closes the stuck issue of a published release" closes "[auto-release] stuck release 0.22.0"
ok "closes the stuck issue of an older published release" closes "[auto-release] stuck release 0.21.0"
ok "closes the image-missing issue once the image exists" closes "[auto-release] stuck release 0.22.0 (image missing)"
ok "closes the release issue of an existing tag" closes "[auto-release] release 0.22.0 warranted"
no "RELEASE keeps the release issue of the next version" closes "[auto-release] release 0.23.0 warranted"
run '.docker.http = 404 | .now = "2026-10-01T01:00:00Z"'
no "image still missing: keeps the image-missing issue" closes "[auto-release] stuck release 0.22.0 (image missing)"
run '.releases += [range(10; 21) | {"tag": "0.\(.).0", "draft": false, "prerelease": false, "published_at": "2025-01-01T00:00:00Z", "assets": []}]
     | .tags += [range(10; 21) | {"name": "0.\(.).0", "object_type": "commit"}]'
eq "close titles bounded per kind (10 stuck + image + 10 release)" "21" "$(d '.close_issue_titles | length')"
no "oldest stuck titles dropped" closes "[auto-release] stuck release 0.12.0"
no "oldest release titles dropped" closes "[auto-release] release 0.12.0 warranted"
ok "newest stuck titles kept" closes "[auto-release] stuck release 0.13.0"
ok "newest release titles kept" closes "[auto-release] release 0.13.0 warranted"

echo "=== job outputs and summary ==="
run
for line in "decision=RELEASE" "version=0.23.0" "candidate_sha=cccccccccccccccccccccccccccccccccccccccc" \
  "eligible_at=2026-10-06T00:00:00Z" "latest=0.22.0" "issue_kind=" "issue_title=" "stuck=" \
  "close_needed=true" "decision_started_at=2026-10-07T12:00:00Z" "fixed_count=2"; do
  ok "output $line" output_has "$line"
done
ok "output close_titles is a JSON array" jq -e 'type == "array"' <<<"$(sed -n 's/^close_titles=//p' "$OUT/gh_output")"
ok "output issue_body heredoc" output_has "issue_body<<DECIDE_ISSUE_BODY_EOF"
ok "step summary appended" cmp -s "$OUT/summary.md" "$OUT/step_summary"
ok "summary has the fixed ids" grep -q "GO-2026-0001, GO-2026-0002" "$OUT/summary.md"
ok "summary has the version" grep -q "0.23.0" "$OUT/summary.md"
ok "summary has the mode" grep -q "Mode: report" "$OUT/summary.md"
ok "summary has the constants" grep -q "MIN_RELEASE_INTERVAL_DAYS" "$OUT/summary.md"
no "summary never names residual findings" grep -q "GO-2026-0003" "$OUT/summary.md"
no "decision.json never names residual findings" grep -q "GO-2026-0003" "$OUT/decision.json"
cp "$OUT/decision.json" "$OUT/first.json"
run
ok "deterministic: same inputs, same decision.json" cmp -s "$OUT/first.json" "$OUT/decision.json"

echo "=== replay: U1 adjacent human releases (DB filtered at newer release - 1 h) ==="
# Pacing constants are zeroed: the replay checks the signal and release rule
# (pairs such as 0.17.0 -> 0.18.0 were 6 h apart).
jq '.COOLDOWN_HOURS = "0" | .MIN_RELEASE_INTERVAL_DAYS = "0"' "$BASE/constants_base.json" >"$OUT/replay_constants.json"

# replay_scan <latest fixture> <candidate fixture> <asof epoch>
replay_scan() {
  jq -n --slurpfile a "$1" --slurpfile b "$2" --argjson t "$3" '
    def known($osv): [.[] | select($osv[.] != null and ($osv[.] | fromdateiso8601) <= $t)];
    ($a[0].osv_published + $b[0].osv_published) as $osv
    | {schema: 1,
       latest: {asset_sha256: "1111111111111111111111111111111111111111111111111111111111111111", digest_ok: true,
                findings: ($a[0].findings | known($osv)), db_last_modified: $a[0].db_last_modified},
       candidate: {findings: ($b[0].findings | known($osv)), db_last_modified: $b[0].db_last_modified},
       db_rerun: false}' >"$OUT/replay_scan.json"
}

# replay_facts <tool> <latest version> <latest fixture> <now> <candidate sha>
replay_facts() {
  jq -n --arg tool "$1" --arg v "$2" --slurpfile a "$3" --arg now "$4" --arg sha "$5" '
    {schema: 1, repo: "pivotal-cf/\($tool)", tool: $tool, now: $now, trigger: "workflow_run",
     latest: {tag: $v, published_at: $a[0].published_at, tag_commit: ("a" * 40)},
     releases: [{tag: $v, draft: false, prerelease: false, published_at: $a[0].published_at,
                 assets: ([{name: "\($tool)-linux", digest: ("sha256:" + "1" * 64)}]
                          + [("-linux.tar.gz", "-darwin", "-darwin.tar.gz", "-windows.exe", "-windows.zip")
                             | {name: "\($tool)\(.)", digest: null}]
                          + [{name: "checksums.txt", digest: null}])}],
     tags: [{name: $v, object_type: "commit"}],
     tag_runs: {}, tag_events: {}, docker: {tag: $v, http: 200},
     candidate: {sha: $sha, source: "workflow_run",
                 tail_after_candidate: {status: "identical", commits: []},
                 from_latest: {status: "ahead", commits: [{sha: $sha, committer_date: $now, files: ["go.mod", "go.sum"],
                                                           files_truncated: false, push_time: $now}]}}}' >"$OUT/replay_facts.json"
}

# replay_pair <tool> <old> <new> <decision> <fixed count>
replay_pair() {
  local old="${TD}/release-$1-$2.json" new="${TD}/release-$1-$3.json" asof
  asof=$(( $(jq -r '.published_at | fromdateiso8601' "$new") - 3600 ))
  replay_scan "$old" "$new" "$asof"
  replay_facts "$1" "$2" "$old" "$(jq -nr --argjson e "$asof" '$e | todateiso8601')" "$(printf '%040d' 1)"
  run_files "$OUT/replay_facts.json" "$OUT/replay_scan.json" "$OUT/replay_constants.json"
  eq "replay $1 $2 -> $3" "$4 fixed=$5 introduced=0 rc=0" \
    "$(d '.decision') fixed=$(d '.fixed_count') introduced=$(d '.introduced_count') rc=$RC"
  if [[ "$4" == "RELEASE" ]]; then
    eq "replay $1 $2 -> $3: version" "$3" "$(d '.version')"
  fi
}

replay_pair replicator 0.15.0 0.16.0 RELEASE 8
replay_pair replicator 0.16.0 0.17.0 NO_RELEASE 0
replay_pair replicator 0.17.0 0.18.0 RELEASE 2
replay_pair replicator 0.18.0 0.19.0 RELEASE 7
replay_pair replicator 0.19.0 0.20.0 RELEASE 3
replay_pair replicator 0.20.0 0.21.0 RELEASE 14
replay_pair replicator 0.21.0 0.22.0 RELEASE 3
replay_pair winfs-injector 0.27.0 0.28.0 RELEASE 5
replay_pair winfs-injector 0.28.0 0.29.0 RELEASE 8
replay_pair winfs-injector 0.29.0 0.30.0 RELEASE 3
replay_pair winfs-injector 0.30.0 0.31.0 RELEASE 3
replay_pair winfs-injector 0.31.0 0.32.0 RELEASE 24
replay_pair winfs-injector 0.32.0 0.33.0 RELEASE 13
replay_pair winfs-injector 0.33.0 0.34.0 RELEASE 5

echo "=== replay: U1 per-commit sweep (DB filtered at commit time) ==="
# replay_commit <tool> <base> <next> <sha10> <committer date UTC, from u1 sweep.index> <decision> <fixed count>
replay_commit() {
  local base="${TD}/release-$1-$2.json" commit="${TD}/commit-$1-$2-$3-$4.json"
  replay_scan "$base" "$commit" "$(jq -nr --arg t "$5" '$t | fromdateiso8601')"
  replay_facts "$1" "$2" "$base" "$5" "$4$(printf '%030d' 0)"
  run_files "$OUT/replay_facts.json" "$OUT/replay_scan.json" "$OUT/replay_constants.json"
  eq "sweep $1 $2..$3 commit $4" "$6 fixed=$7 rc=0" "$(d '.decision') fixed=$(d '.fixed_count') rc=$RC"
}

replay_commit replicator 0.21.0 0.22.0 185db56e16 2026-06-09T21:15:21Z NO_RELEASE 0
replay_commit replicator 0.21.0 0.22.0 89dc59de07 2026-06-09T21:21:07Z NO_RELEASE 0
replay_commit replicator 0.21.0 0.22.0 c035fe64aa 2026-06-09T21:21:54Z RELEASE 3
ok "sweep replicator: fires before the human 0.22.0 release" \
  test "$(jq -r '.published_at' "$TD/release-replicator-0.22.0.json")" '>' 2026-06-09T21:21:54Z
replay_commit winfs-injector 0.33.0 0.34.0 42fc8dccad 2026-07-29T22:53:00Z NO_RELEASE 0
replay_commit winfs-injector 0.33.0 0.34.0 05ccb9ab12 2026-07-29T23:02:25Z NO_RELEASE 0
replay_commit winfs-injector 0.33.0 0.34.0 a5f0fcfacc 2026-07-29T23:03:00Z RELEASE 1
eq "sweep winfs-injector: fires 284 h before the human 0.34.0 release" "284" \
  "$(jq -r '((.published_at | fromdateiso8601) - ("2026-07-29T23:03:00Z" | fromdateiso8601)) / 3600 | floor' \
     "$TD/release-winfs-injector-0.34.0.json")"

echo "=== current-state controls (today's DB) ==="
# replicator master: the same 10 findings as 0.22.0.
jq -n --slurpfile a "$TD/release-replicator-0.22.0.json" '
  {schema: 1, latest: {asset_sha256: ("1" * 64), digest_ok: true, findings: $a[0].findings, db_last_modified: $a[0].db_last_modified},
   candidate: {findings: $a[0].findings, db_last_modified: $a[0].db_last_modified}, db_rerun: false}' >"$OUT/replay_scan.json"
replay_facts replicator 0.22.0 "$TD/release-replicator-0.22.0.json" 2026-10-07T15:00:00Z "$(printf '%040d' 2)"
run_files "$OUT/replay_facts.json" "$OUT/replay_scan.json" "$OUT/replay_constants.json"
eq "control replicator master (10 = 0.22.0's 10)" "NO_RELEASE fixed=0" "$(d '.decision') fixed=$(d '.fixed_count')"
# winfs-injector master: 12 findings vs 0.34.0's 17 (a 12-id subset stands in for master's set).
jq -n --slurpfile a "$TD/release-winfs-injector-0.34.0.json" '
  {schema: 1, latest: {asset_sha256: ("1" * 64), digest_ok: true, findings: $a[0].findings, db_last_modified: $a[0].db_last_modified},
   candidate: {findings: ($a[0].findings | sort | .[:12]), db_last_modified: $a[0].db_last_modified}, db_rerun: false}' >"$OUT/replay_scan.json"
replay_facts winfs-injector 0.34.0 "$TD/release-winfs-injector-0.34.0.json" 2026-10-07T15:00:00Z "$(printf '%040d' 3)"
run_files "$OUT/replay_facts.json" "$OUT/replay_scan.json" "$OUT/replay_constants.json"
eq "control winfs-injector master (12 vs 0.34.0's 17)" "RELEASE fixed=5 version=0.35.0" \
  "$(d '.decision') fixed=$(d '.fixed_count') version=$(d '.version')"

echo "decide_test: ${TOTAL} tests, ${FAILED} failed"
(( FAILED == 0 ))
