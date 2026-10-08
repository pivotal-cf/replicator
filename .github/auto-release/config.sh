#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/auto-release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Validate integer range
validate_int() {
  local name="$1"
  local val="${2:-}"
  local min="$3"
  local max="$4"

  if [[ -z "$val" || "$val" =~ [[:space:]] || ! "$val" =~ ^[0-9]+$ ]]; then
    die "Invalid ${name}: '${val}' (must be integer between ${min} and ${max})"
  fi

  local num=$(( 10#$val ))
  if (( num < min || num > max )); then
    die "Invalid ${name}: '${val}' (must be integer between ${min} and ${max})"
  fi
}

# Validate enum value
validate_enum() {
  local name="$1"
  local val="${2:-}"
  shift 2
  if [[ -z "$val" || "$val" =~ [[:space:]] ]]; then
    die "Invalid ${name}: empty or whitespace"
  fi
  local valid=0
  for opt in "$@"; do
    if [[ "$val" == "$opt" ]]; then
      valid=1
      break
    fi
  done
  if (( ! valid )); then
    die "Invalid ${name}: '${val}' (allowed: $*)"
  fi
}

# Check existence and validate EVERY value per section 3.1
RELEASE_MODE="${RELEASE_MODE:-}"
validate_enum "RELEASE_MODE" "$RELEASE_MODE" off report notify approve auto

COOLDOWN_HOURS="${COOLDOWN_HOURS:-}"
validate_int "COOLDOWN_HOURS" "$COOLDOWN_HOURS" 0 720

MIN_RELEASE_INTERVAL_DAYS="${MIN_RELEASE_INTERVAL_DAYS:-}"
validate_int "MIN_RELEASE_INTERVAL_DAYS" "$MIN_RELEASE_INTERVAL_DAYS" 0 90

VERSION_BUMP="${VERSION_BUMP:-}"
validate_enum "VERSION_BUMP" "$VERSION_BUMP" minor patch

INTRODUCED_POLICY="${INTRODUCED_POLICY:-}"
validate_enum "INTRODUCED_POLICY" "$INTRODUCED_POLICY" block allow

MIN_FIXED_FINDINGS="${MIN_FIXED_FINDINGS:-}"
validate_int "MIN_FIXED_FINDINGS" "$MIN_FIXED_FINDINGS" 1 50

STUCK_RELEASE_ALERT_HOURS="${STUCK_RELEASE_ALERT_HOURS:-}"
validate_int "STUCK_RELEASE_ALERT_HOURS" "$STUCK_RELEASE_ALERT_HOURS" 1 168

APPROVAL_STALE_HOURS="${APPROVAL_STALE_HOURS:-}"
validate_int "APPROVAL_STALE_HOURS" "$APPROVAL_STALE_HOURS" 1 720

GOVULNCHECK_VERSION="${GOVULNCHECK_VERSION:-}"
if [[ -z "$GOVULNCHECK_VERSION" || "$GOVULNCHECK_VERSION" =~ [[:space:]] || ! "$GOVULNCHECK_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  die "Invalid GOVULNCHECK_VERSION: '${GOVULNCHECK_VERSION}' (must match ^v[0-9]+\\.[0-9]+\\.[0-9]+$)"
fi

MAX_CANDIDATE_WINDOW="${MAX_CANDIDATE_WINDOW:-}"
validate_int "MAX_CANDIDATE_WINDOW" "$MAX_CANDIDATE_WINDOW" 1 250

INPUT_MODE_OVERRIDE="${INPUT_MODE_OVERRIDE:-}"
validate_enum "INPUT_MODE_OVERRIDE" "$INPUT_MODE_OVERRIDE" none off report notify approve

EVENT_NAME="${EVENT_NAME:-}"
if [[ -z "$EVENT_NAME" || "$EVENT_NAME" =~ ^[[:space:]]+$ ]]; then
  die "Invalid EVENT_NAME: missing or whitespace"
fi

# Mode hierarchy: auto > approve > notify > report > off
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

# Effective mode calculation:
# Override can only LOWER along auto > approve > notify > report > off; 'none' = no override.
if [[ "$INPUT_MODE_OVERRIDE" == "none" ]]; then
  effective_mode="$RELEASE_MODE"
else
  release_rank="$(mode_rank "$RELEASE_MODE")"
  override_rank="$(mode_rank "$INPUT_MODE_OVERRIDE")"
  if (( override_rank < release_rank )); then
    effective_mode="$INPUT_MODE_OVERRIDE"
  else
    effective_mode="$RELEASE_MODE"
  fi
fi

# Build constants_json
constants_json="$(jq -c -n \
  --arg RELEASE_MODE "$RELEASE_MODE" \
  --arg COOLDOWN_HOURS "$COOLDOWN_HOURS" \
  --arg MIN_RELEASE_INTERVAL_DAYS "$MIN_RELEASE_INTERVAL_DAYS" \
  --arg VERSION_BUMP "$VERSION_BUMP" \
  --arg INTRODUCED_POLICY "$INTRODUCED_POLICY" \
  --arg MIN_FIXED_FINDINGS "$MIN_FIXED_FINDINGS" \
  --arg STUCK_RELEASE_ALERT_HOURS "$STUCK_RELEASE_ALERT_HOURS" \
  --arg APPROVAL_STALE_HOURS "$APPROVAL_STALE_HOURS" \
  --arg GOVULNCHECK_VERSION "$GOVULNCHECK_VERSION" \
  --arg MAX_CANDIDATE_WINDOW "$MAX_CANDIDATE_WINDOW" \
  --arg INPUT_MODE_OVERRIDE "$INPUT_MODE_OVERRIDE" \
  --arg EVENT_NAME "$EVENT_NAME" \
  --arg mode "$effective_mode" \
  '$ARGS.named')"

# Output to GITHUB_OUTPUT or stdout
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "mode=${effective_mode}" >> "$GITHUB_OUTPUT"
  echo "constants_json=${constants_json}" >> "$GITHUB_OUTPUT"
else
  echo "mode=${effective_mode}"
  echo "constants_json=${constants_json}"
fi

# Write to Step Summary
summary_append "### Auto-Release Configuration"
summary_append ""
summary_append "- **Effective Mode**: \`${effective_mode}\`"
summary_append "- **Configured Mode**: \`${RELEASE_MODE}\`"
summary_append "- **Mode Override**: \`${INPUT_MODE_OVERRIDE}\`"
summary_append "- **Event**: \`${EVENT_NAME}\`"
summary_append ""
summary_append "| Constant | Value |"
summary_append "|---|---|"
summary_append "| COOLDOWN_HOURS | \`${COOLDOWN_HOURS}\` |"
summary_append "| MIN_RELEASE_INTERVAL_DAYS | \`${MIN_RELEASE_INTERVAL_DAYS}\` |"
summary_append "| VERSION_BUMP | \`${VERSION_BUMP}\` |"
summary_append "| INTRODUCED_POLICY | \`${INTRODUCED_POLICY}\` |"
summary_append "| MIN_FIXED_FINDINGS | \`${MIN_FIXED_FINDINGS}\` |"
summary_append "| STUCK_RELEASE_ALERT_HOURS | \`${STUCK_RELEASE_ALERT_HOURS}\` |"
summary_append "| APPROVAL_STALE_HOURS | \`${APPROVAL_STALE_HOURS}\` |"
summary_append "| GOVULNCHECK_VERSION | \`${GOVULNCHECK_VERSION}\` |"
summary_append "| MAX_CANDIDATE_WINDOW | \`${MAX_CANDIDATE_WINDOW}\` |"
