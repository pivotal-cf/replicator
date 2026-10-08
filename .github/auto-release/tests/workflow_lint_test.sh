#!/usr/bin/env bash
# jq programs and literal ${{ }} expressions sit inside single quotes on purpose.
# shellcheck disable=SC2016
set -euo pipefail

# workflow_lint_test.sh - static checks of auto-release.yml, auto-release-test.yml
# and ci.yml against LLDD-A sections 3.1, 4 and 7 (yq + jq over the real YAML).
# Usage: workflow_lint_test.sh [auto-release.yml] [auto-release-test.yml] [ci.yml]
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS="${SCRIPT_DIR}/../../workflows"
WF_FILE="${1:-${WORKFLOWS}/auto-release.yml}"
TEST_WF_FILE="${2:-${WORKFLOWS}/auto-release-test.yml}"
CI_FILE="${3:-${WORKFLOWS}/ci.yml}"

FAILED=0
TOTAL=0

# check <desc> <got> <want>
check() {
  TOTAL=$(( TOTAL + 1 ))
  if [[ "$2" == "$3" ]]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (got '$2', want '$3')"
    FAILED=$(( FAILED + 1 ))
  fi
}

to_json() {
  [[ -f "$1" ]] || { echo "::error::workflow_lint_test: $1 not found" >&2; exit 2; }
  yq -o=json '.' "$1" || { echo "::error::workflow_lint_test: yq cannot parse $1" >&2; exit 2; }
}

WF="$(to_json "$WF_FILE")"
TEST_WF="$(to_json "$TEST_WF_FILE")"
CI="$(to_json "$CI_FILE")"

# Objects are compared with sorted keys (-S).
wf() { jq -S -c "$@" <<<"$WF"; }
wfr() { jq -r "$@" <<<"$WF"; }

ALL_JOBS='["act-approve","act-auto","config","decide","finalize","notify"]'
check "jobs are exactly config, decide, notify, finalize, act-approve, act-auto" \
  "$(wf '.jobs | keys')" "$ALL_JOBS"

# --- Constants block (section 3.1) ---
CONSTANTS='["APPROVAL_STALE_HOURS","COOLDOWN_HOURS","GOVULNCHECK_VERSION","INTRODUCED_POLICY","MAX_CANDIDATE_WINDOW","MIN_FIXED_FINDINGS","MIN_RELEASE_INTERVAL_DAYS","RELEASE_MODE","STUCK_RELEASE_ALERT_HOURS","VERSION_BUMP"]'
begin_re='^# BEGIN CONSTANTS \(the only per-repo / per-owner edit point; changing behaviour = a reviewed commit\)$'
check "exactly one BEGIN CONSTANTS marker" "$(grep -cE "$begin_re" "$WF_FILE" || true)" "1"
check "exactly one END CONSTANTS marker" "$(grep -cx '# END CONSTANTS' "$WF_FILE" || true)" "1"
block="$(awk 'index($0, "# BEGIN CONSTANTS ") == 1 {on=1; next} $0 == "# END CONSTANTS" {on=0} on' "$WF_FILE")"
check "constants block starts with top-level env:" "$(head -n 1 <<<"$block")" "env:"
check "constants block defines exactly the section 3.1 constants" \
  "$(sed -nE 's/^  ([A-Z_]+):.*/\1/p' <<<"$block" | jq -R . | jq -s -c 'sort')" "$CONSTANTS"
check "every constant line in the block is a known key or a comment" \
  "$(grep -cvE '^(env:|  [A-Z_]+: [^ ].*|  #.*)$' <<<"$block" || true)" "0"
check "workflow-level env holds only the constants" "$(wf '.env | keys')" "$CONSTANTS"
check "workflow file starts with name: then the constants block" \
  "$(sed -n '1p;3p' "$WF_FILE" | grep -cE '^(name: auto-release|# BEGIN CONSTANTS .*)$' || true)" "2"

# --- Triggers ---
check "on.workflow_run: ci completed on master" \
  "$(wf '.on.workflow_run')" '{"branches":["master"],"types":["completed"],"workflows":["ci"]}'
check "on.schedule: daily 17 5 * * *" "$(wf '.on.schedule')" '[{"cron":"17 5 * * *"}]'
check "on.workflow_dispatch.mode_override: choice none|off|report|notify|approve, default none" \
  "$(wf '.on.workflow_dispatch.inputs.mode_override | {type, options, default}')" \
  '{"default":"none","options":["none","off","report","notify","approve"],"type":"choice"}'
check "only the three triggers" "$(wf '.on | keys')" '["schedule","workflow_dispatch","workflow_run"]'

# --- Permissions (section 4 table) ---
check "top-level permissions: {}" "$(wf '.permissions')" "{}"
check "no workflow-level concurrency" "$(wf 'has("concurrency")')" "false"
perm() { wf --arg j "$1" '.jobs[$j].permissions'; }
check "config permissions: contents read, actions write" "$(perm config)" '{"actions":"write","contents":"read"}'
check "decide permissions: contents read, actions read" "$(perm decide)" '{"actions":"read","contents":"read"}'
check "notify permissions: contents read, issues write" "$(perm notify)" '{"contents":"read","issues":"write"}'
check "finalize permissions: {}" "$(perm finalize)" "{}"
check "act-approve permissions: contents write, actions write" "$(perm act-approve)" '{"actions":"write","contents":"write"}'
check "act-auto permissions: contents write, actions write" "$(perm act-auto)" '{"actions":"write","contents":"write"}'
with_perm() { wf --arg k "$1" '[.jobs | to_entries[] | select(.value.permissions[$k]? == "write") | .key] | sort'; }
check "notify is the only job with issues: write" "$(with_perm issues)" '["notify"]'
check "only config and act-* have actions: write" "$(with_perm actions)" '["act-approve","act-auto","config"]'
check "only act-* have contents: write" "$(with_perm contents)" '["act-approve","act-auto"]'
check "every job declares permissions" "$(wf '[.jobs[] | select(has("permissions") | not)] | length')" "0"

# --- needs / if (section 4 table, exact) ---
needs() { wf --arg j "$1" '.jobs[$j].needs // [] | if type == "string" then [.] else . end'; }
check "config needs nothing" "$(needs config)" "[]"
check "decide needs config" "$(needs decide)" '["config"]'
check "notify needs config, decide" "$(needs notify)" '["config","decide"]'
check "finalize needs config, decide, notify" "$(needs finalize)" '["config","decide","notify"]'
check "act-approve needs config, decide" "$(needs act-approve)" '["config","decide"]'
check "act-auto needs config, decide" "$(needs act-auto)" '["config","decide"]'

jif() { wfr --arg j "$1" '.jobs[$j].if // ""'; }
check "config if" "$(jif config)" \
  "github.event_name != 'workflow_run' || (github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'push')"
check "decide if" "$(jif decide)" "needs.config.outputs.mode != 'off'"
check "notify if" "$(jif notify)" \
  "always() && needs.decide.result == 'success' && (needs.config.outputs.mode == 'notify' || needs.decide.outputs.issue_kind != '' || needs.decide.outputs.close_needed == 'true')"
check "finalize if" "$(jif finalize)" \
  "always() && needs.decide.result == 'success' && needs.decide.outputs.stuck == 'true'"
check "act-approve if" "$(jif act-approve)" \
  "needs.decide.result == 'success' && needs.decide.outputs.decision == 'RELEASE' && needs.config.outputs.mode == 'approve' && needs.decide.outputs.stuck != 'true'"
check "act-auto if" "$(jif act-auto)" \
  "needs.decide.result == 'success' && needs.decide.outputs.decision == 'RELEASE' && needs.config.outputs.mode == 'auto' && needs.decide.outputs.stuck != 'true'"

# The effective mode that selects the act job (and so the environment) comes only
# from needs.config.outputs: no job-level if/environment/concurrency reads env,
# inputs or vars, and every mode comparison is on needs.config.outputs.mode.
check "no job-level if/environment/concurrency reads env., inputs., vars. or event inputs" \
  "$(wf '[.jobs[] | (.if, .environment, .concurrency) | select(. != null) | tostring
          | select(test("(^|[^a-z_.])(env|inputs|vars)\\.|github\\.event\\.inputs"))] | length')" "0"
check "every mode comparison in job-level ifs uses needs.config.outputs.mode" \
  "$(wf '[.jobs[].if // "" | scan("[A-Za-z_.]*mode[A-Za-z_]*") | select(. != "needs.config.outputs.mode")] | length')" "0"
check "finalize has a single step that exits 1" \
  "$(wf '[.jobs.finalize.steps[] | .run // "" | test("(^|\n)exit 1\n?$")]')" "[true]"

# --- environment, concurrency, timeouts, runners ---
check "only act-approve has environment:" \
  "$(wf '[.jobs | to_entries[] | select(.value | has("environment")) | .key]')" '["act-approve"]'
check "act-approve environment is the literal release" "$(wf '.jobs["act-approve"].environment')" '"release"'
check "act-* concurrency: auto-release-act, no cancel; no other job has concurrency" \
  "$(wf '[.jobs | to_entries[] | select(.value | has("concurrency")) | {(.key): .value.concurrency}] | add')" \
  '{"act-approve":{"cancel-in-progress":false,"group":"auto-release-act"},"act-auto":{"cancel-in-progress":false,"group":"auto-release-act"}}'
check "timeout-minutes: decide 20, every other job 5" \
  "$(wf '.jobs | map_values(.["timeout-minutes"])')" \
  '{"act-approve":5,"act-auto":5,"config":5,"decide":20,"finalize":5,"notify":5}'
check "every job runs on ubuntu-latest" "$(wf '[.jobs[]["runs-on"]] | unique')" '["ubuntu-latest"]'

# --- Checkouts and script locations ---
checkouts() { wf --arg j "$1" '[.jobs[$j].steps[]? | select((.uses // "") | startswith("actions/checkout@")) | .with]'; }
TOOLS='{"path":"tools","persist-credentials":false,"ref":"${{ github.sha }}"}'
for j in config notify act-approve act-auto; do
  check "${j} checks out only tools/ at github.sha without credentials" "$(checkouts "$j")" "[${TOOLS}]"
done
check "decide checks out tools/ at github.sha and the candidate into src/, no credentials" \
  "$(checkouts decide)" \
  "[${TOOLS},{\"path\":\"src\",\"persist-credentials\":false,\"ref\":\"\${{ steps.candidate.outputs.sha }}\"}]"
check "finalize has no checkout" "$(checkouts finalize)" "[]"
check "every script runs from tools/.github/auto-release" \
  "$(wf '[.jobs[].steps[]? | .run // "" | scan("[^ ]*\\.github/auto-release/[^ ]*") | select(startswith("tools/.github/auto-release/") | not)] | length')" "0"
check "setup-go only in decide, reading src/go.mod" \
  "$(wf '[.jobs | to_entries[] | .key as $k | .value.steps[]? | select((.uses // "") | startswith("actions/setup-go@")) | {($k): .with["go-version-file"]}]')" \
  '[{"decide":"src/go.mod"}]'
check "govulncheck installed with go install at GOVULNCHECK_VERSION" \
  "$(wf '[.jobs.decide.steps[] | .run // "" | select(contains("go install \"golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}\""))] | length')" "1"

# CLI_RELEASE_WRITE=1 only in the janitor, notify and act steps.
check "CLI_RELEASE_WRITE set only on steps of config (janitor), notify, act-*" \
  "$(wf '[.jobs | to_entries[] | .key as $k | .value.steps[]? | select(.env.CLI_RELEASE_WRITE? != null)
          | {($k): ((.run // "") | capture("auto-release/(?<s>[a-z]+)\\.sh").s), v: .env.CLI_RELEASE_WRITE}]')" \
  '[{"config":"janitor","v":"1"},{"notify":"notify","v":"1"},{"act-approve":"act","v":"1"},{"act-auto":"act","v":"1"}]'
check "no job-level env" "$(wf '[.jobs[] | select(has("env"))] | length')" "0"

# --- Secrets, expressions in run:, action pins (both workflows) ---
for f in "$WF_FILE" "$TEST_WF_FILE"; do
  name="$(basename "$f")"
  check "${name}: no secrets references" \
    "$(grep -cE 'secrets(\.|\[|:)' "$f" || true)" "0"
done
# run_and_uses <name> <workflow json>
run_and_uses() {
  local name="$1" json="$2" u
  check "${name}: no \${{ inside any run: block" \
    "$(jq '[.. | objects | select(has("run")) | .run | strings | select(contains("${{"))] | length' <<<"$json")" "0"
  check "${name}: has at least one uses:" \
    "$(jq '[.. | objects | select(has("uses"))] | length > 0' <<<"$json")" "true"
  while IFS= read -r u; do
    check "${name}: uses '${u}' pinned by 40-hex SHA" \
      "$(grep -cE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$' <<<"$u" || true)" "1"
  done < <(jq -r '.. | objects | select(has("uses")) | .uses' <<<"$json")
}
run_and_uses "$(basename "$WF_FILE")" "$WF"
run_and_uses "$(basename "$TEST_WF_FILE")" "$TEST_WF"

# --- auto-release-test.yml ---
tj() { jq -c "$@" <<<"$TEST_WF"; }
PATHS='[".github/auto-release/**",".github/workflows/auto-release-test.yml",".github/workflows/auto-release.yml",".github/workflows/ci.yml"]'
check "test workflow: triggers are pull_request and push" "$(tj '.on | keys')" '["pull_request","push"]'
check "test workflow: pull_request paths" "$(tj '.on.pull_request.paths | sort')" "$PATHS"
check "test workflow: push paths" "$(tj '.on.push.paths | sort')" "$PATHS"
check "test workflow: permissions contents read" "$(tj '.permissions')" '{"contents":"read"}'
check "test workflow: every job runs on ubuntu-latest" "$(tj '[.jobs[]["runs-on"]] | unique')" '["ubuntu-latest"]'
check "test workflow: runs every tests/*_test.sh" \
  "$(tj '[.jobs[].steps[] | .run // "" | select(contains(".github/auto-release/tests/*_test.sh"))] | length')" "1"

# --- ci.yml: workflow_dispatch is enabled (act.sh dispatches it on the tag) ---
check "ci.yml: on.workflow_dispatch present" "$(jq -c '.on | has("workflow_dispatch")' <<<"$CI")" "true"
check "ci.yml: workflow name is ci" "$(jq -r '.name' <<<"$CI")" "ci"

echo "workflow_lint_test: ${TOTAL} tests, ${FAILED} failed"
(( FAILED == 0 ))
