#!/usr/bin/env bash
set -euo pipefail

# act.sh - Tag creation, ci.yml dispatch, and verification
# Exit codes:
#   0 ok (or clean no-op)
#   2 invalid input/config/anomaly/timeout (fail closed)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/auto-release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# 1. Require CLI_RELEASE_WRITE=1
require_write

# 2. Validate inputs
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" || ! "$REPO" =~ ^pivotal-cf/(replicator|winfs-injector)$ ]]; then
  die "act.sh: invalid or missing REPO '${REPO}' (must be pivotal-cf/replicator or pivotal-cf/winfs-injector)"
fi

VERSION="${VERSION:-}"
if ! is_semver "$VERSION"; then
  die "act.sh: invalid VERSION '${VERSION}' (must match ^[0-9]+\\.[0-9]+\\.[0-9]+$)"
fi

SHA="${SHA:-${CANDIDATE_SHA:-}}"
if [[ ! "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  die "act.sh: invalid SHA '${SHA}' (must be 40-char hex)"
fi

DECISION_STARTED_AT="${DECISION_STARTED_AT:-}"
if [[ -z "$DECISION_STARTED_AT" ]]; then
  die "act.sh: missing DECISION_STARTED_AT"
fi
_start_epoch="$(epoch "$DECISION_STARTED_AT")"

APPROVAL_STALE_HOURS="${APPROVAL_STALE_HOURS:-24}"
if [[ ! "$APPROVAL_STALE_HOURS" =~ ^[0-9]+$ ]] || (( APPROVAL_STALE_HOURS < 1 || APPROVAL_STALE_HOURS > 720 )); then
  die "act.sh: invalid APPROVAL_STALE_HOURS '${APPROVAL_STALE_HOURS}' (must be integer 1..720)"
fi

# Re-derive effective mode from constants + INPUT_MODE_OVERRIDE (never trusts a passed mode)
RELEASE_MODE="${RELEASE_MODE:-}"
INPUT_MODE_OVERRIDE="${INPUT_MODE_OVERRIDE:-none}"

mode_rank() {
  case "$1" in
    off) echo 0 ;;
    report) echo 1 ;;
    notify) echo 2 ;;
    approve) echo 3 ;;
    auto) echo 4 ;;
    *) echo -1 ;;
  esac
}

rel_rank="$(mode_rank "$RELEASE_MODE")"
if (( rel_rank < 0 )); then
  die "act.sh: invalid RELEASE_MODE '${RELEASE_MODE}'"
fi

if [[ "$INPUT_MODE_OVERRIDE" == "none" ]]; then
  effective_mode="$RELEASE_MODE"
else
  ovr_rank="$(mode_rank "$INPUT_MODE_OVERRIDE")"
  if (( ovr_rank < 0 )) || [[ "$INPUT_MODE_OVERRIDE" == "auto" ]]; then
    die "act.sh: invalid INPUT_MODE_OVERRIDE '${INPUT_MODE_OVERRIDE}'"
  fi
  if (( ovr_rank < rel_rank )); then
    effective_mode="$INPUT_MODE_OVERRIDE"
  else
    effective_mode="$RELEASE_MODE"
  fi
fi

if [[ "$effective_mode" != "approve" && "$effective_mode" != "auto" ]]; then
  die "act.sh: effective mode '${effective_mode}' is not approve or auto"
fi

# 3. Runtime approvals guard in approve mode
GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-}"

if [[ "$effective_mode" == "approve" ]]; then
  if [[ "$GITHUB_RUN_ATTEMPT" != "1" ]]; then
    die "act.sh: GITHUB_RUN_ATTEMPT must be 1 (got ${GITHUB_RUN_ATTEMPT})"
  fi
  if [[ -z "$GITHUB_RUN_ID" ]]; then
    die "act.sh: GITHUB_RUN_ID is required in approve mode"
  fi

  approvals_json="$(ghx "repos/$REPO/actions/runs/$GITHUB_RUN_ID/approvals")" || die "act.sh: failed to fetch approvals"

  approved_count="$(echo "$approvals_json" | jq -r '
    if type == "array" then
      [ .[] | select(
          .state == "approved" and
          ((.user.login // "") | length > 0) and
          any(.environments[]?; .name == "release")
        )
      ] | length
    else
      0
    end
  ' 2>/dev/null || echo 0)"
  if (( approved_count < 1 )); then
    die "act.sh: runtime approvals guard failed: no valid approval for environment 'release'"
  fi
fi

# 4. Re-validation (mandatory before any tag creation)
# 4a. Re-list tags: no-op if version exists or a higher semver tag exists.
# Tag immutability: existing tags must never be overwritten, retagged, or blindly
# dispatched. If a tag already exists but its release failed or was interrupted,
# act.sh exits 0 (clean no-op) to preserve immutability. Automated stuck detection
# in decide.sh/notify.sh monitors tags lacking published releases older than
# STUCK_RELEASE_ALERT_HOURS and opens/updates a tracking issue. Manual stuck recovery
# requires an operator to investigate failure logs and manually dispatch ci.yml:
#   gh workflow run ci.yml -R "$REPO" --ref "$VERSION"
tags_json="$(ghx "repos/$REPO/git/matching-refs/tags")" || die "act.sh: failed to list tags"
tag_refs="$(echo "$tags_json" | jq -r '.[].ref // empty')"

for ref in $tag_refs; do
  tag_name="${ref#refs/tags/}"
  if [[ "$tag_name" == "$VERSION" ]]; then
    note "act.sh: tag '${VERSION}' already exists; skipping (no-op)"
    exit 0
  fi
  if is_semver "$tag_name"; then
    if [[ "$(semver_cmp "$tag_name" "$VERSION")" == "1" ]]; then
      note "act.sh: higher semver tag '${tag_name}' exists; skipping (no-op)"
      exit 0
    fi
  fi
done

# 4b. Re-validate candidate relative to master:
# Candidate must be identical to master, or ahead only by verifiably HomebrewFormula/*.rb-only commits.
# Divergent or behind history, or substantive master advancement, is a clean no-op (skipping).
# API errors, unparseable data, empty/missing data, or truncation fail closed (exit 2).
compare_json="$(ghx "repos/$REPO/compare/$SHA...master")" || die "act.sh: failed to compare ${SHA}...master"

if [[ -z "$compare_json" ]] || ! jq -e 'type == "object"' <<<"$compare_json" >/dev/null 2>&1; then
  die "act.sh: compare ${SHA}...master response is empty or not a JSON object"
fi

cmp_status="$(jq -r '.status // empty' <<<"$compare_json" 2>/dev/null)" || cmp_status=""
case "$cmp_status" in
  identical|ahead|behind|diverged) ;;
  *) die "act.sh: unexpected or missing compare status '${cmp_status}' for ${SHA}...master" ;;
esac

if [[ "$cmp_status" == "behind" || "$cmp_status" == "diverged" ]]; then
  note "act.sh: sha ${SHA} status relative to master is '${cmp_status}'; skipping (no-op)"
  exit 0
fi

if [[ "$cmp_status" == "ahead" ]]; then
  total="$(jq -r '.total_commits // empty' <<<"$compare_json" 2>/dev/null)" || total=""
  if [[ ! "$total" =~ ^[0-9]+$ ]]; then
    die "act.sh: compare ${SHA}...master response missing or invalid total_commits"
  fi
  commits_len="$(jq -r '.commits | if type == "array" then length else -1 end' <<<"$compare_json" 2>/dev/null)" || commits_len=-1
  if (( commits_len < 0 )); then
    die "act.sh: compare ${SHA}...master response missing commits array"
  fi
  if (( total != commits_len )); then
    die "act.sh: compare ${SHA}...master lists ${commits_len} of ${total} commits (truncated)"
  fi
  if (( commits_len == 0 )); then
    die "act.sh: compare ${SHA}...master has status ahead but commits array is empty"
  fi

  commit_shas="$(jq -r '.commits[].sha // empty' <<<"$compare_json" 2>/dev/null)" || commit_shas=""
  sha_count="$(jq -r '[.commits[].sha // empty] | length' <<<"$compare_json" 2>/dev/null)" || sha_count=0
  if (( sha_count != commits_len )); then
    die "act.sh: compare ${SHA}...master has commit missing sha"
  fi

  while IFS= read -r c_sha; do
    [[ -n "$c_sha" ]] || continue
    if [[ ! "$c_sha" =~ ^[0-9a-f]{40}$ ]]; then
      die "act.sh: invalid commit sha '${c_sha}' in compare ${SHA}...master"
    fi

    commit_json="$(ghx "repos/$REPO/commits/$c_sha")" || die "act.sh: failed to fetch commit ${c_sha}"
    if [[ -z "$commit_json" ]] || ! jq -e 'type == "object"' <<<"$commit_json" >/dev/null 2>&1; then
      die "act.sh: commit ${c_sha} response is empty or not a JSON object"
    fi

    files_len="$(jq -r 'if (.files | type) == "array" and all(.files[]; (.filename | type) == "string") then .files | length else -1 end' <<<"$commit_json" 2>/dev/null)" || files_len=-1
    if (( files_len < 0 )); then
      die "act.sh: commit ${c_sha} missing or invalid files array"
    fi
    if (( files_len >= 300 )); then
      die "act.sh: commit ${c_sha} lists ${files_len} files (truncated at 300)"
    fi

    non_brew="$(jq -r '
      if (.files | length) == 0 then
        "<empty commit>"
      else
        [ .files[] | (.filename, (.previous_filename // empty)) | select(test("^HomebrewFormula/[^/]+\\.rb$") | not) ][0] // empty
      end
    ' <<<"$commit_json" 2>/dev/null)" || non_brew="<parse error>"

    if [[ -n "$non_brew" ]]; then
      note "act.sh: master has advanced beyond candidate ${SHA} with non-brew commit ${c_sha} (${non_brew}); skipping (no-op)"
      exit 0
    fi
  done <<< "$commit_shas"

  note "act.sh: master is ahead of candidate ${SHA} by ${commits_len} commit(s), all verifiably HomebrewFormula/*.rb-only; proceeding"
fi

# 4c. Master-push ci run for sha still success
ci_runs_json="$(ghx "repos/$REPO/actions/workflows/ci.yml/runs?head_sha=$SHA&event=push&branch=master")" || die "act.sh: failed to fetch master ci runs"
success_count="$(echo "$ci_runs_json" | jq -r '
  [ .workflow_runs[]? | select(.event == "push" and .head_branch == "master" and .conclusion == "success") ] | length
')"
if (( success_count < 1 )); then
  note "act.sh: master-push ci run for sha ${SHA} is not success; skipping (no-op)"
  exit 0
fi

# 4d. Decision age <= APPROVAL_STALE_HOURS from DECISION_STARTED_AT env
now_iso="$(iso_now)"
now_sec="$(epoch "$now_iso")"
age_sec=$(( now_sec - _start_epoch ))
max_age_sec=$(( APPROVAL_STALE_HOURS * 3600 ))
if (( age_sec > max_age_sec || age_sec < 0 )); then
  note "act.sh: decision is stale (age ${age_sec}s > max ${max_age_sec}s); skipping (no-op)"
  exit 0
fi

# 5. POST git/refs (422 Reference already exists => notice exit 0)
# If a race occurred and the tag was created concurrently, preserve immutability
# and exit 0 (no-op) rather than blindly dispatching. Stuck releases are handled
# via manual recovery per runbook (gh workflow run ci.yml -R "$REPO" --ref "$VERSION").
ref_err=""
ref_rc=0
ref_err="$(ghx_write "repos/$REPO/git/refs" -f ref="refs/tags/$VERSION" -f sha="$SHA" 2>&1)" || ref_rc=$?

if (( ref_rc != 0 )); then
  if echo "$ref_err" | grep -qi "Reference already exists"; then
    note "act.sh: tag ref 'refs/tags/${VERSION}' already exists (422); exiting (no-op)"
    exit 0
  fi
  die "act.sh: POST git/refs failed (${ref_rc}): ${ref_err}"
fi

# 6. Dispatch ci.yml on the new tag
# Capture dispatch timestamp and filter boundary to distinguish any prior runs from the current dispatch.
# Allow a small 10s buffer for clock skew between runner and GitHub API servers.
dispatch_started_at="$(iso_now)"
dispatch_started_epoch="$(epoch "$dispatch_started_at")"
dispatch_filter_epoch=$(( dispatch_started_epoch - 10 ))
dispatch_created_filter="$(jq -nr --argjson ep "$dispatch_filter_epoch" 'try ($ep | todateiso8601) catch empty' 2>/dev/null || true)"
if [[ -z "$dispatch_created_filter" ]]; then
  dispatch_created_filter="$dispatch_started_at"
fi

ghx_write workflow run ci.yml -R "$REPO" --ref "$VERSION"

# 7. Poll up to 120s (injectable) for workflow_dispatch run on that tag, failing if none.
# Uses API-supported timestamp filter (created=>=...) to exclude historical runs,
# and strictly validates event, tag/ref, candidate SHA, and creation timestamp.
# Unchecked workflow_runs[0] fallback is forbidden.
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-120}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"

poll_elapsed=0
step_interval="$POLL_INTERVAL_SECONDS"
if (( step_interval <= 0 )); then
  step_interval=1
fi

dispatched_run_id=""
while (( poll_elapsed <= POLL_TIMEOUT_SECONDS )); do
  dispatch_runs_json="$(ghx "repos/$REPO/actions/workflows/ci.yml/runs?event=workflow_dispatch&branch=$VERSION&created=>=$dispatch_created_filter")" || true
  dispatched_run_id="$(echo "$dispatch_runs_json" | jq -r \
    --arg v "$VERSION" \
    --arg sha "$SHA" \
    --argjson min_epoch "$dispatch_filter_epoch" '
    if type == "object" and (.workflow_runs | type == "array") then
      [ .workflow_runs[] | select(
          .event == "workflow_dispatch" and
          (.head_branch == $v or .head_branch == ("refs/tags/" + $v)) and
          .head_sha == $sha and
          (
            ((.created_at // "") | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0) >= $min_epoch
          )
        )
      ] | sort_by(.created_at) | reverse | .[0].id // empty
    else
      empty
    end
  ' 2>/dev/null || echo "")"

  if [[ -n "$dispatched_run_id" ]]; then
    break
  fi

  if (( poll_elapsed >= POLL_TIMEOUT_SECONDS )); then
    break
  fi

  if (( POLL_INTERVAL_SECONDS > 0 )); then
    sleep "$POLL_INTERVAL_SECONDS" 2>/dev/null || true
  fi
  poll_elapsed=$(( poll_elapsed + step_interval ))
done

if [[ -z "$dispatched_run_id" ]]; then
  die "act.sh: no workflow_dispatch run observed for tag '${VERSION}' within ${POLL_TIMEOUT_SECONDS}s"
fi

run_url="https://github.com/$REPO/actions/runs/$dispatched_run_id"
summary_append "### Release Act Succeeded"
summary_append "- **Version**: \`${VERSION}\`"
summary_append "- **Candidate SHA**: \`${SHA}\`"
summary_append "- **Mode**: \`${effective_mode}\`"
summary_append "- **Dispatched CI Run**: [${dispatched_run_id}](${run_url})"

exit 0
