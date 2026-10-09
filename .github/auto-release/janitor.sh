#!/usr/bin/env bash
set -euo pipefail

# janitor.sh - Cancel stale waiting runs of auto-release workflow
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
  die "janitor.sh: invalid or missing REPO '${REPO}' (must be pivotal-cf/replicator or pivotal-cf/winfs-injector)"
fi

APPROVAL_STALE_HOURS="${APPROVAL_STALE_HOURS:-24}"
if [[ ! "$APPROVAL_STALE_HOURS" =~ ^[0-9]+$ ]] || (( APPROVAL_STALE_HOURS < 1 || APPROVAL_STALE_HOURS > 720 )); then
  die "janitor.sh: invalid APPROVAL_STALE_HOURS '${APPROVAL_STALE_HOURS}' (must be integer 1..720)"
fi

# 3. List waiting runs across all pages
runs_json="$(get_all_pages "repos/$REPO/actions/runs?status=waiting&per_page=100" "workflow_runs")" || die "janitor.sh: failed to fetch waiting runs"

now_iso="$(iso_now)"
now_sec="$(epoch "$now_iso")"
max_age_sec=$(( APPROVAL_STALE_HOURS * 3600 ))

# 4. Filter runs: path == .github/workflows/auto-release.yml and age > APPROVAL_STALE_HOURS
cancelled_count=0
while IFS=$'\t' read -r run_id run_path run_created_at run_status; do
  [[ -z "$run_id" ]] && continue

  # Path filter
  if [[ "$run_path" != ".github/workflows/auto-release.yml" ]]; then
    continue
  fi

  # Status check
  if [[ "$run_status" != "waiting" ]]; then
    continue
  fi

  # Age filter
  run_sec="$(epoch "$run_created_at")"
  run_age=$(( now_sec - run_sec ))

  if (( run_age > max_age_sec )); then
    if ghx_write -X POST "repos/$REPO/actions/runs/$run_id/cancel" >/dev/null 2>&1; then
      summary_append "- Cancelled stale auto-release run #${run_id} (age: ${run_age}s)"
      cancelled_count=$(( cancelled_count + 1 ))
    else
      warn "janitor.sh: failed to cancel waiting run #${run_id}"
    fi
  fi
done < <(echo "$runs_json" | jq -r '
  .workflow_runs[]? |
  select(.path != null) |
  "\(.id)\t\(.path)\t\(.created_at // .run_started_at)\t\(.status)"
')

note "janitor.sh: cancelled ${cancelled_count} stale waiting run(s)"
exit 0
