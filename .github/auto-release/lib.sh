#!/usr/bin/env bash
set -euo pipefail

# lib.sh - Shared library for auto-release scripts
# Exit codes:
#   0 ok
#   2 invalid input/config/anomaly
#   3 transport/tool failure (collect.sh/scan.sh only)

die() {
  local msg="$*"
  echo "::error::${msg}" >&2
  exit 2
}

note() {
  local msg="$*"
  echo "::notice::${msg}"
}

warn() {
  local msg="$*"
  echo "::warning::${msg}"
}

is_semver() {
  local s="${1:-}"
  [[ "$s" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

semver_cmp() {
  local a="${1:-}"
  local b="${2:-}"
  if ! is_semver "$a" || ! is_semver "$b"; then
    die "semver_cmp: invalid semver: '$a' vs '$b'"
  fi

  local a_maj a_min a_patch
  local b_maj b_min b_patch
  IFS='.' read -r a_maj a_min a_patch <<< "$a"
  IFS='.' read -r b_maj b_min b_patch <<< "$b"

  if (( 10#$a_maj < 10#$b_maj )); then echo "-1"; return 0; fi
  if (( 10#$a_maj > 10#$b_maj )); then echo "1"; return 0; fi
  if (( 10#$a_min < 10#$b_min )); then echo "-1"; return 0; fi
  if (( 10#$a_min > 10#$b_min )); then echo "1"; return 0; fi
  if (( 10#$a_patch < 10#$b_patch )); then echo "-1"; return 0; fi
  if (( 10#$a_patch > 10#$b_patch )); then echo "1"; return 0; fi
  echo "0"
}

epoch() {
  local ts="${1:-}"
  if [[ -z "$ts" ]]; then
    die "epoch: missing timestamp"
  fi
  # Convert RFC3339 timestamp to epoch seconds using jq fromdateiso8601.
  # If fractional seconds are present (e.g. .000Z), strip them before passing to fromdateiso8601.
  local result
  result="$(jq -n --arg t "$ts" 'try ($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch empty' 2>/dev/null)" || true
  if [[ -z "$result" ]]; then
    die "epoch: invalid RFC3339 timestamp '$ts'"
  fi
  echo "$result"
}

iso_now() {
  if [[ -n "${NOW_OVERRIDE:-}" ]]; then
    echo "$NOW_OVERRIDE"
  else
    date -u +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

ghx() {
  # GET only: inspect all args and refuse write flags or methods other than GET
  local skip_next=0
  for arg in "$@"; do
    if (( skip_next )); then
      skip_next=0
      local up_arg
      up_arg="$(echo "$arg" | tr '[:lower:]' '[:upper:]')"
      if [[ "$up_arg" != "GET" ]]; then
        die "ghx: method other than GET not allowed: $arg"
      fi
      continue
    fi
    case "$arg" in
      -f|-F|--input|--field|--raw-field)
        die "ghx: write flag not allowed: $arg"
        ;;
      -f*|-F*|--input=*|--field=*|--raw-field=*)
        die "ghx: write flag not allowed: $arg"
        ;;
      -X|--method)
        skip_next=1
        ;;
      -X*|--method=*)
        local val="${arg#*=}"
        if [[ "$arg" == -X* && "$arg" != --* ]]; then
          val="${arg#-X}"
        fi
        val="$(echo "$val" | tr '[:lower:]' '[:upper:]')"
        if [[ "$val" != "GET" ]]; then
          die "ghx: method other than GET not allowed: $arg"
        fi
        ;;
    esac
  done

  if (( skip_next )); then
    die "ghx: missing argument after -X/--method"
  fi

  gh api --hostname github.com "$@"
}

require_write() {
  if [[ "${CLI_RELEASE_WRITE:-0}" != "1" ]]; then
    die "require_write: CLI_RELEASE_WRITE must be 1"
  fi
}

ghx_write() {
  require_write

  # Allowed operations:
  # 1. gh workflow run ...
  # 2. gh api POST to allowed endpoints:
  #    - repos/:owner/:repo/git/refs
  #    - repos/:owner/:repo/issues
  #    - repos/:owner/:repo/issues/:id (PATCH)
  #    - repos/:owner/:repo/issues/:id/comments
  #    - repos/:owner/:repo/labels
  #    - repos/:owner/:repo/actions/runs/:id/cancel
  if [[ "${1:-}" == "workflow" && "${2:-}" == "run" ]]; then
    gh "$@"
    return $?
  fi

  # Otherwise inspect the api call
  local endpoint=""
  local method="POST"
  local i=1
  while (( i <= $# )); do
    local arg="${!i}"
    case "$arg" in
      -X|--method)
        local next_i=$(( i + 1 ))
        if (( next_i <= $# )); then
          method="$(echo "${!next_i}" | tr '[:lower:]' '[:upper:]')"
          i=$next_i
        fi
        ;;
      -X*)
        method="$(echo "${arg#-X}" | tr '[:lower:]' '[:upper:]')"
        ;;
      --method=*)
        method="$(echo "${arg#--method=}" | tr '[:lower:]' '[:upper:]')"
        ;;
      api)
        # Skip literal 'api'
        ;;
      --hostname|--hostname=*)
        if [[ "$arg" == "--hostname" ]]; then
          i=$(( i + 1 ))
        fi
        ;;
      -f*|-F*|--field*|--raw-field*|--input*|-H*|--header*|-q*|--jq*|-t*|--template*)
        if [[ "$arg" =~ ^(-f|-F|--field|--raw-field|--input|-H|--header|-q|--jq|-t|--template)$ ]]; then
          i=$(( i + 1 ))
        fi
        ;;
      -*)
        # Other flags
        ;;
      *)
        if [[ -z "$endpoint" ]]; then
          endpoint="$arg"
        fi
        ;;
    esac
    (( i++ ))
  done

  # Validate endpoint against allowlist
  local allowed=0
  if [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/git/refs$ && "$method" == "POST" ]]; then
    allowed=1
  elif [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/issues$ && "$method" == "POST" ]]; then
    allowed=1
  elif [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/issues/[0-9]+$ && "$method" == "PATCH" ]]; then
    allowed=1
  elif [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/issues/[0-9]+/comments$ && "$method" == "POST" ]]; then
    allowed=1
  elif [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/labels$ && "$method" == "POST" ]]; then
    allowed=1
  elif [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/actions/runs/[0-9]+/cancel$ && "$method" == "POST" ]]; then
    allowed=1
  fi

  if (( ! allowed )); then
    die "ghx_write: endpoint '$endpoint' with method '$method' not allowed"
  fi

  gh api --hostname github.com "$@"
}

summary_append() {
  local line="$*"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "$line" >> "$GITHUB_STEP_SUMMARY"
  else
    echo "$line"
  fi
}

# json_get <file> <filter>
json_get() {
  local file="${1:-}"
  local filter="${2:-}"
  if [[ -z "$file" || -z "$filter" ]]; then
    die "json_get: missing file or filter arguments"
  fi
  if [[ ! -f "$file" ]]; then
    die "json_get: file not found: $file"
  fi
  jq -r "$filter" "$file" 2>/dev/null || die "json_get: jq filter failed on $file: $filter"
}
# get_all_pages <endpoint> [property]
# Fetch paginated GitHub API endpoint using --paginate.
# If property is provided (e.g. "workflow_runs"), expects JSON object per page containing that array,
# and returns a JSON object {"workflow_runs": [...]}.
# If property is omitted, expects JSON array per page and returns a merged JSON array.
# Fails closed (exit 2) on malformed page or missing array so callers never operate on partial success.
get_all_pages() {
  local endpoint="$1"
  local prop="${2:-}"
  local raw
  raw="$(ghx --paginate "$endpoint")" || return 1

  if [[ -z "${raw//[[:space:]]/}" ]]; then
    echo "::error::paginated API returned no JSON; refusing to guess" >&2
    return 2
  fi

  local result
  if [[ -n "$prop" ]]; then
    result="$(jq -c -s --arg p "$prop" '
      if length > 0 and all(.[]; (type == "object") and (.[$p] | type == "array")) then
        {($p): [.[][$p][]]}
      else
        error("malformed page response: not object with array property " + $p)
      end
    ' <<<"$raw" 2>/dev/null)" || return 2
  else
    result="$(jq -c -s '
      if length > 0 and all(.[]; type == "array") then
        [.[][]]
      else
        error("malformed page response: not JSON array")
      end
    ' <<<"$raw" 2>/dev/null)" || return 2
  fi

  echo "$result"
}
