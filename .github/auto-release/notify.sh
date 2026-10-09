#!/usr/bin/env bash
set -euo pipefail

# notify.sh - Tracking issue management (create, update, close)
# Exit codes:
#   0 ok
#   2 invalid input/config/anomaly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/auto-release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# 1. Require CLI_RELEASE_WRITE=1
require_write

# 2. Validate inputs
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" || ! "$REPO" =~ ^pivotal-cf/(replicator|winfs-injector)$ ]]; then
  die "notify.sh: invalid or missing REPO '${REPO}' (must be pivotal-cf/replicator or pivotal-cf/winfs-injector)"
fi

ISSUE_KIND="${ISSUE_KIND:-}"
ISSUE_TITLE="${ISSUE_TITLE:-}"
ISSUE_BODY="${ISSUE_BODY:-}"
CLOSE_TITLES="${CLOSE_TITLES:-[]}"

MODE="${MODE:-${RELEASE_MODE:-}}"
if [[ -n "$MODE" ]]; then
  if [[ ! "$MODE" =~ ^(off|report|notify|approve|auto)$ ]]; then
    die "notify.sh: invalid MODE '${MODE}' (allowed: off, report, notify, approve, auto)"
  fi
  if [[ "$MODE" == "off" ]]; then
    note "notify.sh: mode is off; skipping (no-op)"
    exit 0
  fi
  if [[ "$ISSUE_KIND" == "release" && "$MODE" != "notify" ]]; then
    die "notify.sh: release issues are only permitted in notify mode (mode is '${MODE}')"
  fi
fi

if ! echo "$CLOSE_TITLES" | jq -e 'if type == "array" then true else false end' >/dev/null 2>&1; then
  die "notify.sh: CLOSE_TITLES must be a valid JSON array"
fi

# 3. Ensure label 'auto-release' exists (create if missing)
label_exists=0
ghx "repos/$REPO/labels/auto-release" >/dev/null 2>&1 || label_exists=$?
if (( label_exists != 0 )); then
  ghx_write "repos/$REPO/labels" \
    -f name="auto-release" \
    -f color="0366d6" \
    -f description="Auto-release tracking issues" >/dev/null 2>&1 || true
fi

# 4. Fetch open issues with label 'auto-release' across all pages
open_issues_json="$(get_all_pages "repos/$REPO/issues?state=open&labels=auto-release&per_page=100")" || die "notify.sh: failed to fetch issues"

# 5. Close open issues matching CLOSE_TITLES
closed_count=0
while IFS=$'\t' read -r issue_num issue_title; do
  [[ -z "$issue_num" ]] && continue
  should_close="$(jq -n --arg title "$issue_title" --argjson close_list "$CLOSE_TITLES" '($close_list // []) | index($title) != null')"
  if [[ "$should_close" == "true" ]]; then
    ghx_write "repos/$REPO/issues/$issue_num/comments" -f body="Closing auto-release issue: condition resolved." >/dev/null
    ghx_write "repos/$REPO/issues/$issue_num" -X PATCH -f state="closed" >/dev/null
    summary_append "- Closed auto-release issue #${issue_num}: \`${issue_title}\`"
    closed_count=$(( closed_count + 1 ))
  fi
done < <(echo "$open_issues_json" | jq -r '.[]? | "\(.number)\t\(.title)"')

# 6. Create or update issue for ISSUE_TITLE (if provided)
if [[ -n "$ISSUE_TITLE" ]]; then
  # Find open issues with this exact title that were not closed above
  matching_numbers=()
  while IFS= read -r num; do
    [[ -n "$num" ]] && matching_numbers+=("$num")
  done < <(echo "$open_issues_json" | jq -r --arg title "$ISSUE_TITLE" --argjson close_list "$CLOSE_TITLES" '
    .[]? | select(.title == $title and (($close_list // []) | index($title) == null)) | .number
  ')

  if [[ ${#matching_numbers[@]} -eq 0 ]]; then
    # Create new issue
    new_issue_json="$(ghx_write "repos/$REPO/issues" -f title="$ISSUE_TITLE" -f body="$ISSUE_BODY" -f "labels[]=auto-release")"
    new_num="$(echo "$new_issue_json" | jq -r '.number // empty')"
    summary_append "- Created auto-release issue #${new_num}: \`${ISSUE_TITLE}\`"
  else
    # Update first matching issue
    target_num="${matching_numbers[0]}"
    ghx_write "repos/$REPO/issues/$target_num" -X PATCH -f body="$ISSUE_BODY" >/dev/null
    summary_append "- Updated auto-release issue #${target_num}: \`${ISSUE_TITLE}\`"

    # Close any duplicates to maintain at most one open issue per exact title
    for (( i=1; i<${#matching_numbers[@]}; i++ )); do
      dup_num="${matching_numbers[i]}"
      ghx_write "repos/$REPO/issues/$dup_num/comments" -f body="Closing duplicate auto-release issue in favor of #${target_num}." >/dev/null
      ghx_write "repos/$REPO/issues/$dup_num" -X PATCH -f state="closed" >/dev/null
      summary_append "- Closed duplicate auto-release issue #${dup_num}: \`${ISSUE_TITLE}\`"
    done
  fi
fi

exit 0
