#!/usr/bin/env bash
set -euo pipefail

# collect.sh: network READS only (ghx GETs + one Docker Hub GET) -> facts.json
# (LLDD-A section 5 steps 1-3; shape per section 5.9).
# Usage: collect.sh [facts.json]
# Env: REPO or GITHUB_REPOSITORY; EVENT_NAME (workflow_run|schedule|workflow_dispatch);
#      WORKFLOW_RUN_HEAD_SHA (required for workflow_run); MAX_CANDIDATE_WINDOW (1..250);
#      TAG_RUNS_REQUERY_SLEEP (seconds before re-querying a tag with no ci run, default 120);
#      NOW_OVERRIDE (tests).
# Exit codes: 0 ok, 2 anomaly / invalid input, 3 transport failure (failed API call,
# unexpected response, Docker Hub status other than 200/404).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/auto-release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
SHA_RE='^[0-9a-f]{40}$'

fail3() {
  echo "::error::collect.sh: $*" >&2
  exit 3
}

# get <list|object|runs> <ghx args...>: GET through ghx. `list` merges the pages of a
# --paginate call into one array, `object` expects one JSON object, `runs` one object
# with a `workflow_runs` array. A failed call or any other body is a transport failure.
get() {
  local shape="$1" out filter
  shift
  out="$(ghx "$@")" || fail3 "GET ${*: -1} failed"
  case "$shape" in
    list) filter='if length > 0 and all(.[]; type == "array") then add else error("not a JSON array") end' ;;
    object) filter='if length == 1 and (.[0] | type) == "object" then .[0] else error("not one JSON object") end' ;;
    runs) filter='if length == 1 and (.[0].workflow_runs | type) == "array" then .[0] else error("no workflow_runs array") end' ;;
  esac
  jq -c -s "$filter" <<<"$out" 2>/dev/null || fail3 "unexpected response from GET ${*: -1}"
}

# commit_files <sha>: JSON array of the commit's file names; 300 entries means GitHub
# truncated the list, which is an anomaly (exit 2).
commit_files() {
  local sha="$1" resp n
  resp="$(get object "repos/${REPO}/commits/${sha}")" || exit $?
  n="$(jq -r 'if (.files | type) == "array" and all(.files[]; (.filename | type) == "string") then .files | length else error("no files") end' <<<"$resp" 2>/dev/null)" \
    || fail3 "commit ${sha}: no files array"
  if (( n >= 300 )); then
    die "collect.sh: commit ${sha} lists ${n} files (truncated at 300)"
  fi
  jq -c '[.files[].filename]' <<<"$resp"
}

# compare_status <compare json>: the status, which must be one of GitHub's four values.
compare_status() {
  local status
  status="$(jq -r '.status // empty' <<<"$1")"
  case "$status" in
    identical|ahead|behind|diverged) echo "$status" ;;
    *) fail3 "unexpected compare status '${status}'" ;;
  esac
}

# compare_total <compare json> <label>: total_commits, failing closed when the commit
# list is not complete.
compare_total() {
  local total len
  total="$(jq -r '.total_commits' <<<"$1")"
  len="$(jq -r '.commits | if type == "array" then length else error("no commits") end' <<<"$1" 2>/dev/null)" \
    || fail3 "$2: compare response has no commits array"
  [[ "$total" =~ ^[0-9]+$ ]] || fail3 "$2: compare response has no total_commits"
  if (( total != len )); then
    die "collect.sh: $2 lists ${len} of ${total} commits (truncated)"
  fi
  echo "$total"
}

REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "collect.sh: invalid REPO/GITHUB_REPOSITORY '${REPO}'"
TOOL="${REPO#*/}"
FACTS_OUT="${1:-facts.json}"

EVENT="${EVENT_NAME:-}"
case "$EVENT" in
  workflow_run|schedule|workflow_dispatch) ;;
  *) die "collect.sh: invalid EVENT_NAME '${EVENT}'" ;;
esac

WINDOW="${MAX_CANDIDATE_WINDOW:-}"
if [[ ! "$WINDOW" =~ ^[0-9]+$ ]] || (( 10#$WINDOW < 1 || 10#$WINDOW > 250 )); then
  die "collect.sh: invalid MAX_CANDIDATE_WINDOW '${WINDOW}' (1..250)"
fi
WINDOW=$(( 10#$WINDOW ))

REQUERY_SLEEP="${TAG_RUNS_REQUERY_SLEEP:-120}"
[[ "$REQUERY_SLEEP" =~ ^[0-9]+$ ]] || die "collect.sh: invalid TAG_RUNS_REQUERY_SLEEP '${REQUERY_SLEEP}'"

NOW="$(iso_now)"

# 1. Latest release: published, non-prerelease, semver tag; max by numeric semver.
releases_raw="$(get list --paginate "repos/${REPO}/releases?per_page=100")"
releases="$(jq -c --arg re "$SEMVER_RE" '
  [ .[] | select(.draft == false and .prerelease == false and ((.tag_name // "") | test($re))) ]
  | sort_by(.tag_name | split(".") | map(tonumber)) | reverse
  | map({tag: .tag_name, draft, prerelease, published_at,
         assets: [ (.assets // [])[] | {name, digest: (.digest // null)} ]})' <<<"$releases_raw" 2>/dev/null)" \
  || fail3 "unexpected releases response"
latest_tag="$(jq -r '.[0].tag // empty' <<<"$releases")"
[[ -n "$latest_tag" ]] || die "collect.sh: ${REPO} has no published semver release"
latest_pub="$(jq -r '.[0].published_at // empty' <<<"$releases")"
epoch "$latest_pub" >/dev/null

# Docker image of the latest release: 200 complete, 404 incomplete, anything else fails.
docker_http="$(curl -s -o /dev/null -w '%{http_code}' "https://hub.docker.com/v2/repositories/pivotalcfreleng/${TOOL}/tags/${latest_tag}")" \
  || fail3 "Docker Hub request for ${TOOL}:${latest_tag} failed"
case "$docker_http" in
  200|404) ;;
  *) fail3 "Docker Hub returned HTTP ${docker_http} for ${TOOL}:${latest_tag}" ;;
esac

# 2. Tags: every semver tag must be lightweight (object type commit).
tags_raw="$(get list --paginate "repos/${REPO}/git/matching-refs/tags")"
tags="$(jq -c '
  map(if (.ref | type) == "string" and (.object.type | type) == "string" then . else error("bad ref") end
      | {name: (.ref | sub("^refs/tags/"; "")), object_type: .object.type, sha: .object.sha})' <<<"$tags_raw" 2>/dev/null)" \
  || fail3 "unexpected matching-refs response"
annotated="$(jq -r --arg re "$SEMVER_RE" '[.[] | select((.name | test($re)) and .object_type != "commit") | .name] | join(" ")' <<<"$tags")"
if [[ -n "$annotated" ]]; then
  die "collect.sh: semver tags that are not lightweight: ${annotated}"
fi
latest_commit="$(jq -r --arg t "$latest_tag" '[.[] | select(.name == $t) | .sha][0] // empty' <<<"$tags")"
[[ "$latest_commit" =~ $SHA_RE ]] || die "collect.sh: release ${latest_tag} has no tag ref"

# Semver tags above latest have no published release: their ci runs and CreateEvent.
tag_runs='{}'
tag_events='{}'
events=''
while IFS= read -r tag; do
  [[ "$(semver_cmp "$tag" "$latest_tag")" == "1" ]] || continue
  runs="$(get runs "repos/${REPO}/actions/workflows/ci.yml/runs?branch=${tag}&per_page=20")"
  if [[ "$(jq '.workflow_runs | length' <<<"$runs")" == "0" ]]; then
    note "collect.sh: no ci run for tag ${tag} yet; re-querying in ${REQUERY_SLEEP}s"
    sleep "$REQUERY_SLEEP"
    runs="$(get runs "repos/${REPO}/actions/workflows/ci.yml/runs?branch=${tag}&per_page=20")"
  fi
  tag_runs="$(jq -c --arg t "$tag" --argjson r "$runs" \
    '.[$t] = [$r.workflow_runs[] | {id, event, status, conclusion, created_at}]' <<<"$tag_runs")"
  if [[ -z "$events" ]]; then
    events="$(get list "repos/${REPO}/events?per_page=100")"
  fi
  tag_events="$(jq -c --arg t "$tag" --argjson e "$events" '
    .[$t] = ([$e[] | select(.type == "CreateEvent" and .payload.ref_type == "tag" and .payload.ref == $t)
              | .created_at] | min)' <<<"$tag_events")"
done < <(jq -r --arg re "$SEMVER_RE" '.[] | select(.name | test($re)) | .name' <<<"$tags")

# 3. Candidate: the workflow_run head, else the newest green master-push ci run.
if [[ "$EVENT" == "workflow_run" ]]; then
  cand="${WORKFLOW_RUN_HEAD_SHA:-}"
  cand_source="workflow_run"
else
  master_runs="$(get runs "repos/${REPO}/actions/workflows/ci.yml/runs?branch=master&event=push&status=success&per_page=1")"
  cand="$(jq -r '.workflow_runs[0].head_sha // empty' <<<"$master_runs")"
  cand_source="schedule"
fi
[[ "$cand" =~ $SHA_RE ]] || die "collect.sh: no valid candidate sha ('${cand}', source ${cand_source})"

# (a) Commits on master after the candidate, with their files (decide.sh checks brew-only).
tail_resp="$(get object "repos/${REPO}/compare/${cand}...master")"
tail_status="$(compare_status "$tail_resp")"
tail_commits='[]'
if [[ "$tail_status" == "ahead" ]]; then
  compare_total "$tail_resp" "compare ${cand}...master" >/dev/null
  while IFS= read -r sha; do
    [[ "$sha" =~ $SHA_RE ]] || fail3 "compare ${cand}...master: bad commit sha '${sha}'"
    files="$(commit_files "$sha")"
    tail_commits="$(jq -c --arg s "$sha" --argjson f "$files" \
      '. + [{sha: $s, files: $f, files_truncated: false}]' <<<"$tail_commits")"
  done < <(jq -r '.commits[].sha' <<<"$tail_resp")
fi

# (b) Commits from the latest tag to the candidate, with files and push_time.
from_resp="$(get object "repos/${REPO}/compare/${latest_tag}...${cand}")"
from_status="$(compare_status "$from_resp")"
from_commits='[]'
if [[ "$from_status" == "ahead" ]]; then
  total="$(compare_total "$from_resp" "compare ${latest_tag}...${cand}")"
  if (( total > WINDOW )); then
    die "collect.sh: ${total} commits between ${latest_tag} and ${cand} exceed MAX_CANDIDATE_WINDOW ${WINDOW}"
  fi
  while IFS=$'\t' read -r sha committer_date; do
    [[ "$sha" =~ $SHA_RE ]] || fail3 "compare ${latest_tag}...${cand}: bad commit sha '${sha}'"
    epoch "$committer_date" >/dev/null
    files="$(commit_files "$sha")"
    push_runs="$(get runs "repos/${REPO}/actions/workflows/ci.yml/runs?head_sha=${sha}&event=push")"
    from_commits="$(jq -c --arg s "$sha" --arg d "$committer_date" --argjson f "$files" --argjson r "$push_runs" '
      . + [{sha: $s, committer_date: $d, files: $f, files_truncated: false,
            push_time: ([$r.workflow_runs[].run_started_at | strings] | min)}]' <<<"$from_commits")"
  done < <(jq -r '.commits[] | [.sha, (.commit.committer.date // "")] | @tsv' <<<"$from_resp")
fi

facts="$(jq -n \
  --arg repo "$REPO" --arg tool "$TOOL" --arg now "$NOW" --arg trigger "$EVENT" \
  --arg latest_tag "$latest_tag" --arg latest_pub "$latest_pub" --arg latest_commit "$latest_commit" \
  --argjson releases "$releases" --argjson tags "$tags" \
  --argjson tag_runs "$tag_runs" --argjson tag_events "$tag_events" \
  --argjson docker_http "$docker_http" \
  --arg cand "$cand" --arg cand_source "$cand_source" \
  --arg tail_status "$tail_status" --argjson tail_commits "$tail_commits" \
  --arg from_status "$from_status" --argjson from_commits "$from_commits" \
  '{schema: 1, repo: $repo, tool: $tool, now: $now, trigger: $trigger,
    latest: {tag: $latest_tag, published_at: $latest_pub, tag_commit: $latest_commit},
    releases: $releases,
    tags: [$tags[] | {name, object_type}],
    tag_runs: $tag_runs,
    tag_events: $tag_events,
    docker: {tag: $latest_tag, http: $docker_http},
    candidate: {sha: $cand, source: $cand_source,
      tail_after_candidate: {status: $tail_status, commits: $tail_commits},
      from_latest: {status: $from_status, commits: $from_commits}}}')"
printf '%s\n' "$facts" > "$FACTS_OUT"
note "collect.sh: latest ${latest_tag}, candidate ${cand} (${cand_source}), ${from_status} by $(jq 'length' <<<"$from_commits") commits"
