#!/usr/bin/env bash
# jq programs reference jq $variables inside single quotes on purpose.
# shellcheck disable=SC2016
set -euo pipefail

# decide.sh: the PURE decision core (LLDD-A sections 5 and 5.9).
#   decide.sh [facts.json [scan.json [constants [decision.json [summary.md]]]]]
# Env fallbacks: FACTS_JSON, SCAN_JSON, CONSTANTS_JSON (a file path or the JSON
# text itself, i.e. the config job's constants_json output), DECISION_JSON,
# SUMMARY_MD. No network: `now` comes from facts.json, so the result is
# deterministic. Writes decision.json and summary.md, appends summary.md to
# $GITHUB_STEP_SUMMARY and the job outputs to $GITHUB_OUTPUT when set.
# Exit codes: 0 for every decision, 2 for invalid input or an anomaly (a STOP
# for an anomaly still writes decision.json and summary.md before exiting 2).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/auto-release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
SHA_RE='^[0-9a-f]{40}$'
OUTPUT_LIMIT=4000
# Issue titles kept in close_issue_titles per kind (newest semver first), so
# the close_titles job output stays under 4 KB.
CLOSE_TITLES_PER_KIND=10

# load_json <label> <path-or-json>: prints the JSON object, dies otherwise.
load_json() {
  local label="$1" src="$2" text
  if [[ -f "$src" ]]; then
    text="$(cat "$src")"
  elif [[ "$src" == "{"* ]]; then
    text="$src"
  else
    die "decide.sh: ${label} not found: ${src}"
  fi
  jq -e -c 'if type == "object" then . else error("not an object") end' <<<"$text" 2>/dev/null \
    || die "decide.sh: ${label} is not a JSON object"
}

# const <name> <regex>: a constant from constants_json (string or number).
const() {
  local v
  v="$(jq -r --arg k "$1" '.[$k] | if type == "string" or type == "number" then tostring else "" end' <<<"$CONSTANTS")"
  [[ "$v" =~ $2 ]] || die "decide.sh: constant $1 missing or invalid: '${v}'"
  printf '%s\n' "$v"
}

fq() { jq -r "$@" <<<"$FACTS"; }
sq() { jq -r "$@" <<<"$SCAN"; }

# next_version <latest> <minor|patch> <tags json array>: dies if it exists.
next_version() {
  local latest="$1" bump="$2" tags="$3" major minor patch v
  is_semver "$latest" || die "decide.sh: latest '${latest}' is not semver"
  IFS='.' read -r major minor patch <<<"$latest"
  case "$bump" in
    minor) v="${major}.$(( 10#$minor + 1 )).0" ;;
    patch) v="${major}.${minor}.$(( 10#$patch + 1 ))" ;;
    *) die "decide.sh: unknown VERSION_BUMP '${bump}'" ;;
  esac
  if [[ "$(jq --arg v "$v" '[.[] | (.name? // .)] | index($v) != null' <<<"$tags")" == "true" ]]; then
    die "decide.sh: version ${v} already exists as a tag"
  fi
  printf '%s\n' "$v"
}

# tags_above_latest: semver tags above latest (no published release), ascending.
tags_above_latest() {
  local t
  while IFS= read -r t; do
    if [[ "$(semver_cmp "$t" "$LATEST")" == "1" ]]; then
      printf '%s\n' "$t"
    fi
  done < <(fq --arg re "$SEMVER_RE" '[.tags[].name | select(test($re))]
                | sort_by(split(".") | map(tonumber)) | .[]')
}

validate_inputs() {
  [[ "$(fq '.schema')" == "1" ]] || die "decide.sh: facts.json schema must be 1"
  [[ "$(sq '.schema')" == "1" ]] || die "decide.sh: scan.json schema must be 1"

  NOW="$(fq '.now // empty')"
  NOW_EPOCH="$(epoch "$NOW")"
  TOOL="$(fq '.tool // empty')"
  [[ "$TOOL" =~ ^[A-Za-z0-9._-]+$ ]] || die "decide.sh: facts.json tool invalid: '${TOOL}'"

  LATEST="$(fq '.latest.tag // empty')"
  is_semver "$LATEST" || die "decide.sh: latest tag '${LATEST}' is not semver"
  LATEST_PUBLISHED="$(fq '.latest.published_at // empty')"
  LATEST_PUBLISHED_EPOCH="$(epoch "$LATEST_PUBLISHED")"

  # latest must be the newest published semver release.
  local newest
  newest="$(fq --arg re "$SEMVER_RE" '[.releases[]? | select(.draft == false and .prerelease == false
              and ((.tag // "") | test($re))) | .tag] | sort_by(split(".") | map(tonumber)) | last // empty')"
  [[ "$newest" == "$LATEST" ]] || die "decide.sh: latest ${LATEST} is not the newest published release (${newest:-none})"

  # The latest release must carry every asset and a sha256 digest for the linux binary.
  local missing digest
  missing="$(fq --arg t "$LATEST" --arg tool "$TOOL" '
    [(.releases[] | select(.tag == $t) | [.assets[]?.name]) as $have
     | ($tool + "-linux", $tool + "-linux.tar.gz", $tool + "-darwin", $tool + "-darwin.tar.gz",
        $tool + "-windows.exe", $tool + "-windows.zip", "checksums.txt")
     | select(. as $n | $have | index($n) | not)] | join(" ")')"
  [[ -z "$missing" ]] || die "decide.sh: latest release ${LATEST} lacks assets: ${missing}"
  digest="$(fq --arg t "$LATEST" --arg n "${TOOL}-linux" \
    '[.releases[] | select(.tag == $t) | .assets[] | select(.name == $n) | .digest][0] // empty')"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "decide.sh: asset ${TOOL}-linux of ${LATEST} has no sha256 digest"

  [[ "$(fq '.tags | type')" == "array" ]] || die "decide.sh: facts.json tags missing"
  [[ "$(fq --arg t "$LATEST" '[.tags[].name] | index($t) != null')" == "true" ]] \
    || die "decide.sh: latest ${LATEST} has no tag"

  DOCKER_HTTP="$(fq '.docker.http // empty')"
  [[ "$DOCKER_HTTP" == "200" || "$DOCKER_HTTP" == "404" ]] || die "decide.sh: unexpected docker status '${DOCKER_HTTP}'"
  [[ "$(fq '.docker.tag // empty')" == "$LATEST" ]] || die "decide.sh: docker status is not for ${LATEST}"

  [[ "$(sq '.latest.digest_ok')" == "true" ]] || die "decide.sh: latest asset digest not verified by scan"
  [[ "sha256:$(sq '.latest.asset_sha256 // empty')" == "$digest" ]] \
    || die "decide.sh: scanned asset sha256 does not match the API digest of ${TOOL}-linux"
  [[ "$(sq '[.latest.findings, .candidate.findings] | all(type == "array" and all(.[]; type == "string"))')" == "true" ]] \
    || die "decide.sh: scan.json findings must be arrays of OSV ids"
  [[ "$(sq '.db_rerun | type')" == "boolean" ]] || die "decide.sh: scan.json db_rerun must be a boolean"
  local db_latest db_cand
  db_latest="$(sq '.latest.db_last_modified // empty')"
  db_cand="$(sq '.candidate.db_last_modified // empty')"
  [[ -n "$db_latest" && "$db_latest" == "$db_cand" ]] \
    || die "decide.sh: vuln DB timestamps differ (latest ${db_latest:-none}, candidate ${db_cand:-none}, db_rerun $(sq '.db_rerun'))"
}

# set_stuck <tag> <title> <reason>
set_stuck() {
  DECISION="STOP"
  STUCK="true"
  REASON="$3"
  ISSUE_KIND="stuck"
  ISSUE_TITLE="$2"
  ISSUE_BODY="$(printf '%s\n\n' "$3" \
    "Recovery: fix the cause and re-dispatch \`gh workflow run ci.yml -R $(fq '.repo') --ref $1\`; never delete or move a tag automatically.")"
}

# stop_anomaly <reason>: a STOP worth a human; recorded, then exit 2.
stop_anomaly() {
  DECISION="STOP"
  REASON="$1"
  ANOMALY="true"
}

# decide_flow: sets DECISION/REASON (+ version, pacing, issue) following section 5.
decide_flow() {
  local t threshold_sec=$(( 10#$STUCK_RELEASE_ALERT_HOURS * 3600 ))

  # 2. Every semver tag must be lightweight.
  t="$(fq --arg re "$SEMVER_RE" '[.tags[] | select((.name | test($re)) and .object_type != "commit") | .name] | join(" ")')"
  if [[ -n "$t" ]]; then
    stop_anomaly "semver tags that are not lightweight: ${t}"
    return
  fi

  # 1. Latest release incomplete (Docker image missing): in flight, aged from published_at.
  if [[ "$DOCKER_HTTP" == "404" ]]; then
    local age=$(( NOW_EPOCH - LATEST_PUBLISHED_EPOCH ))
    if (( age < threshold_sec )); then
      DECISION="STOP"
      REASON="latest release ${LATEST} has no Docker image yet (release in flight, $(( age / 60 )) min old)"
    else
      set_stuck "$LATEST" "[auto-release] stuck release ${LATEST} (image missing)" \
        "Release ${LATEST} has no Docker image pivotalcfreleng/${TOOL}:${LATEST} $(( age / 3600 )) h after publication (alert after ${STUCK_RELEASE_ALERT_HOURS} h)."
    fi
    return
  fi

  # 2. Semver tags above latest have no published release: in flight or stuck.
  local above
  above="$(tags_above_latest)"
  if [[ -n "$above" ]]; then
    for t in $above; do
      if [[ "$(fq --arg t "$t" '[(.tag_runs[$t] // [])[] | select(.status != "completed")] | length')" != "0" ]]; then
        DECISION="STOP"
        REASON="release in flight: tag ${t} has a running ci run"
        return
      fi
    done
    for t in $above; do
      local since since_epoch age
      since="$(fq --arg t "$t" '([(.tag_runs[$t] // [])[].created_at | strings] | min)
                 // (.tag_events[$t] | strings) // ([.tags[] | select(.name == $t) | .committer_date | strings][0]) // empty')"
      if [[ -z "$since" ]]; then
        set_stuck "$t" "[auto-release] stuck release ${t}" \
          "Tag ${t} has no published release and no ci run, CreateEvent or commit date to age it."
        return
      fi
      since_epoch="$(epoch "$since")"
      age=$(( NOW_EPOCH - since_epoch ))
      if (( age >= threshold_sec )); then
        set_stuck "$t" "[auto-release] stuck release ${t}" \
          "Tag ${t} has no published release $(( age / 3600 )) h after ${since} (alert after ${STUCK_RELEASE_ALERT_HOURS} h)."
        return
      fi
    done
    DECISION="STOP"
    REASON="release in flight: tag(s) ${above//$'\n'/ } without a published release, younger than ${STUCK_RELEASE_ALERT_HOURS} h"
    return
  fi

  # 3a. Every commit on master after the candidate must be a brew-only commit.
  CANDIDATE="$(fq '.candidate.sha // empty')"
  [[ "$CANDIDATE" =~ $SHA_RE ]] || die "decide.sh: candidate sha invalid: '${CANDIDATE}'"
  local status
  status="$(fq '.candidate.tail_after_candidate.status // empty')"
  case "$status" in
    identical) ;;
    ahead)
      [[ "$(fq '.candidate.tail_after_candidate.commits | type == "array" and length > 0')" == "true" ]] \
        || die "decide.sh: master is ahead of the candidate but no commits were listed"
      t="$(fq '[.candidate.tail_after_candidate.commits[]
                | select(.files_truncated != false or ((.files // []) | length) == 0
                         or any((.files // [])[]; test("^HomebrewFormula/[^/]+\\.rb$") | not))
                | .sha] | join(" ")')"
      if [[ -n "$t" ]]; then
        DECISION="NO_TAG"
        REASON="a newer non-brew commit exists on master (${t}); its own CI run will evaluate it"
        return
      fi
      ;;
    behind|diverged)
      DECISION="NO_TAG"
      REASON="master is ${status} relative to the candidate"
      return
      ;;
    *) die "decide.sh: unknown tail_after_candidate status '${status}'" ;;
  esac

  # 3b. The candidate must be a descendant of the latest tag commit.
  status="$(fq '.candidate.from_latest.status // empty')"
  case "$status" in
    ahead) ;;
    identical|behind)
      DECISION="NO_CHANGE"
      REASON="candidate is ${status} relative to ${LATEST} (already released or an old trigger)"
      return
      ;;
    diverged)
      stop_anomaly "candidate ${CANDIDATE} diverged from ${LATEST} (history anomaly)"
      return
      ;;
    *) die "decide.sh: unknown from_latest status '${status}'" ;;
  esac
  local n
  n="$(fq '.candidate.from_latest.commits | if type == "array" then length else -1 end')"
  (( n >= 0 )) || die "decide.sh: from_latest commits missing"
  (( n <= 10#$MAX_CANDIDATE_WINDOW )) || die "decide.sh: ${n} commits since ${LATEST} exceed MAX_CANDIDATE_WINDOW ${MAX_CANDIDATE_WINDOW}"
  if (( n == 0 )); then
    DECISION="NO_CHANGE"
    REASON="no commits between ${LATEST} and the candidate"
    return
  fi

  # 4-5. Signal and release rule.
  FIXED_IDS="$(sq -c '(.latest.findings | unique) - .candidate.findings')"
  FIXED_COUNT="$(jq 'length' <<<"$FIXED_IDS")"
  INTRODUCED_COUNT="$(sq '(.candidate.findings | unique) - .latest.findings | length')"
  if (( FIXED_COUNT < 10#$MIN_FIXED_FINDINGS )); then
    DECISION="NO_RELEASE"
    REASON="candidate fixes ${FIXED_COUNT} finding(s); MIN_FIXED_FINDINGS is ${MIN_FIXED_FINDINGS}"
    return
  fi
  if [[ "$INTRODUCED_POLICY" == "block" ]] && (( INTRODUCED_COUNT > 0 )); then
    DECISION="NO_RELEASE"
    REASON="candidate introduces ${INTRODUCED_COUNT} findings"
    return
  fi

  # 6. Pacing.
  [[ "$(fq '[.candidate.from_latest.commits[]
             | select(.files_truncated != false or (.files | type) != "array" or (.files | length) >= 300)]
            | length')" == "0" ]] \
    || die "decide.sh: a commit's file list is missing or truncated (>= 300 files)"
  # last_change: the newest shipped-input commit (every commit if none is
  # shipped), timed by its first ci push run, else its committer date.
  local push_epoch last_change eligible_epoch
  push_epoch="$(fq '
    def shipped: any(.files[]; test("^(go\\.mod|go\\.sum|Dockerfile|\\.goreleaser\\.yml)$")
                               or (test("\\.go$") and (test("_test\\.go$") | not)));
    .candidate.from_latest.commits as $c
    | ([$c[] | select(shipped)] | if length > 0 then . else $c end)
    | map((.push_time // .committer_date) | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) | max')" \
    || die "decide.sh: a commit in the window has no valid push_time or committer_date"
  last_change="$(jq -nr --argjson e "$push_epoch" '$e | todateiso8601')"
  eligible_epoch=$(( push_epoch + 10#$COOLDOWN_HOURS * 3600 ))
  if (( LATEST_PUBLISHED_EPOCH + 10#$MIN_RELEASE_INTERVAL_DAYS * 86400 > eligible_epoch )); then
    eligible_epoch=$(( LATEST_PUBLISHED_EPOCH + 10#$MIN_RELEASE_INTERVAL_DAYS * 86400 ))
  fi
  ELIGIBLE_AT="$(jq -nr --argjson e "$eligible_epoch" '$e | todateiso8601')"

  # 7. Version.
  VERSION="$(next_version "$LATEST" "$VERSION_BUMP" "$(fq -c '.tags')")"

  if (( NOW_EPOCH < eligible_epoch )); then
    DECISION="WAIT"
    REASON="candidate fixes ${FIXED_COUNT} finding(s); eligible at ${ELIGIBLE_AT} (cooldown ${COOLDOWN_HOURS} h after ${last_change}, minimum interval ${MIN_RELEASE_INTERVAL_DAYS} d after ${LATEST})"
    return
  fi
  DECISION="RELEASE"
  REASON="candidate fixes ${FIXED_COUNT} finding(s), introduces ${INTRODUCED_COUNT}; release ${VERSION}"
}

# close_titles: issues resolved by the current facts (JSON array).
close_titles() {
  fq -c --arg re "$SEMVER_RE" --argjson n "$CLOSE_TITLES_PER_KIND" --arg dec "$DECISION" --arg next "$1" '
    def newest: sort_by(split(".") | map(tonumber)) | reverse | .[:$n];
    ([.releases[] | select(.draft == false and .prerelease == false and ((.tag // "") | test($re))) | .tag]
      | newest) as $rel
    | ([.tags[].name | select(test($re))] | newest) as $tags
    | [ ($rel[] | "[auto-release] stuck release \(.)"),
        (if .docker.http == 200 then "[auto-release] stuck release \(.latest.tag) (image missing)" else empty end),
        ($tags[] | "[auto-release] release \(.) warranted"),
        (if $dec != "RELEASE" and $next != "" then "[auto-release] release \($next) warranted" else empty end) ]
    | unique'
}

write_outputs() {
  local close_json="$1" fixed_list
  fixed_list="$(jq -r 'if length == 0 then "none" else join(", ") end' <<<"$FIXED_IDS")"

  if [[ "$DECISION" == "RELEASE" && "$MODE" == "notify" ]]; then
    ISSUE_KIND="release"
    ISSUE_TITLE="[auto-release] release ${VERSION} warranted"
    ISSUE_BODY="$(printf '%s\n' \
      "Release ${VERSION} of ${TOOL} is warranted (latest ${LATEST})." "" \
      "- Candidate: ${CANDIDATE}" \
      "- Fixed findings: ${FIXED_COUNT} (${fixed_list})" \
      "- Introduced findings: ${INTRODUCED_COUNT}" \
      "- Eligible at: ${ELIGIBLE_AT}" \
      "- Run: ${GITHUB_SERVER_URL:-https://github.com}/$(fq '.repo')/actions/runs/${GITHUB_RUN_ID:-unknown}" "" \
      "A human tags ${VERSION} at ${CANDIDATE} (mode notify).")"
  fi
  close_json="$(jq -c --arg keep "$ISSUE_TITLE" 'map(select(. != $keep))' <<<"$close_json")"

  jq -n \
    --arg decision "$DECISION" --arg reason "$REASON" --arg mode "$MODE" --arg latest "$LATEST" \
    --arg cand "$CANDIDATE" --arg version "$VERSION" --arg eligible "$ELIGIBLE_AT" \
    --argjson fixed "$FIXED_IDS" --argjson fixed_count "$FIXED_COUNT" --argjson introduced "$INTRODUCED_COUNT" \
    --argjson stuck "$STUCK" --arg kind "$ISSUE_KIND" --arg title "$ISSUE_TITLE" --arg body "$ISSUE_BODY" \
    --argjson close "$close_json" '
    def nn: if . == "" then null else . end;
    {schema: 1, decision: $decision, reason: $reason, mode: $mode, latest: $latest,
     candidate_sha: ($cand | nn), version: ($version | nn), eligible_at: ($eligible | nn),
     fixed_ids: $fixed, fixed_count: $fixed_count, introduced_count: $introduced, stuck: $stuck,
     issue: (if $kind == "" then null else {kind: $kind, title: $title, body: $body} end),
     close_issue_titles: $close}' > "$DECISION_OUT"

  # Public-safe: versions, SHAs, counts, fixed ids, eligible_at, mode, constants.
  # Never the findings that remain in the latest or candidate binary.
  {
    printf '%s\n' "## auto-release decision: ${DECISION}" "" \
      "- Reason: ${REASON}" \
      "- Mode: ${MODE}" \
      "- Latest release: ${LATEST}" \
      "- Candidate: ${CANDIDATE:-none}" \
      "- Version: ${VERSION:-none}" \
      "- Eligible at: ${ELIGIBLE_AT:-n/a}" \
      "- Fixed findings: ${FIXED_COUNT} (${fixed_list})" \
      "- Introduced findings: ${INTRODUCED_COUNT}" \
      "- Stuck: ${STUCK}" \
      "- Issue: ${ISSUE_TITLE:-none}" "" \
      "| Constant | Value |" "|---|---|"
    jq -r 'to_entries[] | select(.key | test("^[A-Z_]+$")) | "| \(.key) | `\(.value)` |"' <<<"$CONSTANTS"
  } > "$SUMMARY_OUT"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat "$SUMMARY_OUT" >> "$GITHUB_STEP_SUMMARY"
  fi

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    local body="${ISSUE_BODY:0:$OUTPUT_LIMIT}" delim="DECIDE_ISSUE_BODY_EOF" stuck_out="" close_needed=""
    (( ${#close_json} <= OUTPUT_LIMIT )) || die "decide.sh: close_titles exceeds ${OUTPUT_LIMIT} bytes"
    [[ "$body" != *"$delim"* ]] || die "decide.sh: issue body contains the output delimiter"
    [[ "$STUCK" == "true" ]] && stuck_out="true"
    [[ "$close_json" != "[]" ]] && close_needed="true"
    printf '%s\n' "decision=${DECISION}" "version=${VERSION}" "candidate_sha=${CANDIDATE}" \
      "eligible_at=${ELIGIBLE_AT}" "latest=${LATEST}" "issue_kind=${ISSUE_KIND}" \
      "issue_title=${ISSUE_TITLE:0:$OUTPUT_LIMIT}" "issue_body<<${delim}" "$body" "$delim" \
      "close_titles=${close_json}" "close_needed=${close_needed}" "stuck=${stuck_out}" \
      "decision_started_at=${NOW}" "fixed_count=${FIXED_COUNT}" >> "$GITHUB_OUTPUT"
  fi
}

main() {
  FACTS="$(load_json facts.json "${1:-${FACTS_JSON:-facts.json}}")"
  SCAN="$(load_json scan.json "${2:-${SCAN_JSON:-scan.json}}")"
  CONSTANTS="$(load_json constants_json "${3:-${CONSTANTS_JSON:-}}")"
  DECISION_OUT="${4:-${DECISION_JSON:-decision.json}}"
  SUMMARY_OUT="${5:-${SUMMARY_MD:-summary.md}}"

  MODE="$(const mode '^(report|notify|approve|auto)$')"
  COOLDOWN_HOURS="$(const COOLDOWN_HOURS '^[0-9]+$')"
  MIN_RELEASE_INTERVAL_DAYS="$(const MIN_RELEASE_INTERVAL_DAYS '^[0-9]+$')"
  VERSION_BUMP="$(const VERSION_BUMP '^(minor|patch)$')"
  INTRODUCED_POLICY="$(const INTRODUCED_POLICY '^(block|allow)$')"
  MIN_FIXED_FINDINGS="$(const MIN_FIXED_FINDINGS '^[0-9]+$')"
  STUCK_RELEASE_ALERT_HOURS="$(const STUCK_RELEASE_ALERT_HOURS '^[0-9]+$')"
  MAX_CANDIDATE_WINDOW="$(const MAX_CANDIDATE_WINDOW '^[0-9]+$')"

  validate_inputs

  DECISION="" REASON="" CANDIDATE="" VERSION="" ELIGIBLE_AT="" STUCK="false" ANOMALY="false"
  FIXED_IDS="[]" FIXED_COUNT=0 INTRODUCED_COUNT=0 ISSUE_KIND="" ISSUE_TITLE="" ISSUE_BODY=""
  decide_flow
  CANDIDATE="${CANDIDATE:-$(fq '.candidate.sha // empty')}"
  [[ "$CANDIDATE" =~ $SHA_RE ]] || CANDIDATE=""

  # The release issue a STOP/NO_* decision makes obsolete: the version the
  # current latest would get (empty while a tag above latest exists).
  local obsolete=""
  if [[ -z "$(tags_above_latest)" ]]; then
    obsolete="$(next_version "$LATEST" "$VERSION_BUMP" "$(fq -c '.tags')")"
  fi
  write_outputs "$(close_titles "$obsolete")"

  if [[ "$ANOMALY" == "true" ]]; then
    die "decide.sh: STOP: ${REASON}"
  fi
  note "decide.sh: ${DECISION}: ${REASON}"
}

# decide.sh exits only 0 or 2: any other failure (e.g. jq on a malformed
# facts.json) is invalid input.
on_exit() {
  local rc=$?
  if (( rc != 0 && rc != 2 )); then
    echo "::error::decide.sh: invalid input (exit ${rc})" >&2
    exit 2
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap on_exit EXIT
  main "$@"
fi
