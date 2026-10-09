#!/usr/bin/env bash
set -euo pipefail

# scan_test.sh - Offline tests for scan.sh (fake gh, go and govulncheck on PATH)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="${SCRIPT_DIR}/../scan.sh"
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

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/src"
FAKE_LOG="$TEST_TMP/calls.log"
FAKE_STATE="$TEST_TMP/state"
FAKE_ASSET_CONTENT="replicator 0.22.0 linux binary"
printf '%s' "$FAKE_ASSET_CONTENT" > "$TEST_TMP/asset"
ASSET_SHA="$(sha256_of "$TEST_TMP/asset")"
export TESTDATA_DIR FAKE_LOG FAKE_STATE FAKE_ASSET_CONTENT

# Fake gh: only `gh release download 0.22.0 -R pivotal-cf/replicator -p replicator-linux
# -p checksums.txt -D <dir>`. FAKE_CHECKSUMS=ok|mismatch|missing shapes checksums.txt.
cat << 'EOF' > "$TEST_TMP/bin/gh"
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >> "$FAKE_LOG"
if (( $# != 11 )) || [[ "$1 $2 $3 $4 $5 $6 $7 $8 $9 ${10}" != "release download 0.22.0 -R pivotal-cf/replicator -p replicator-linux -p checksums.txt -D" ]]; then
  echo "fake gh: unexpected call: $*" >&2
  exit 64
fi
dir="${11}"
if [[ -n "${FAKE_DOWNLOAD_FAIL:-}" ]]; then
  echo "HTTP 404: Not Found" >&2
  exit 1
fi
[[ -d "$dir" ]] || { echo "fake gh: -D dir missing" >&2; exit 1; }
if [[ -z "${FAKE_DOWNLOAD_PARTIAL:-}" ]]; then
  printf '%s' "$FAKE_ASSET_CONTENT" > "$dir/replicator-linux"
fi
if command -v sha256sum >/dev/null 2>&1; then
  sha="$(printf '%s' "$FAKE_ASSET_CONTENT" | sha256sum | cut -d' ' -f1)"
else
  sha="$(printf '%s' "$FAKE_ASSET_CONTENT" | shasum -a 256 | cut -d' ' -f1)"
fi
other="1111111111111111111111111111111111111111111111111111111111111111"
{
  echo "${other}  replicator-darwin"
  echo "${other}  replicator-linux.tar.gz"
  case "${FAKE_CHECKSUMS:-ok}" in
    ok) echo "${sha}  replicator-linux" ;;
    mismatch) echo "0000000000000000000000000000000000000000000000000000000000000000  replicator-linux" ;;
    missing) ;;
  esac
  echo "${other}  replicator-windows.exe"
} > "$dir/checksums.txt"
EOF

# Fake go: only `go build -trimpath -o <abs path> .` with CGO_ENABLED=0; writes the output file.
cat << 'EOF' > "$TEST_TMP/bin/go"
#!/usr/bin/env bash
set -euo pipefail
echo "go $* cwd=$PWD CGO_ENABLED=${CGO_ENABLED:-unset}" >> "$FAKE_LOG"
if (( $# != 5 )) || [[ "$1 $2 $3" != "build -trimpath -o" || "$5" != "." || "$4" != /* ]]; then
  echo "fake go: unexpected call: $*" >&2
  exit 64
fi
[[ "${CGO_ENABLED:-}" == "0" ]] || { echo "fake go: CGO_ENABLED must be 0" >&2; exit 64; }
if [[ -n "${FAKE_GO_FAIL:-}" ]]; then
  echo "main.go:1: syntax error" >&2
  exit 1
fi
[[ -n "${FAKE_GO_NOOUT:-}" ]] || printf 'candidate binary' > "$4"
EOF

# Fake govulncheck: only `govulncheck -mode=binary -format=json <binary>`; prints the fixture
# for that binary (basename cand = candidate). FAKE_GV_CAND_FIRST serves the first cand scan.
cat << 'EOF' > "$TEST_TMP/bin/govulncheck"
#!/usr/bin/env bash
set -euo pipefail
echo "govulncheck $*" >> "$FAKE_LOG"
if (( $# != 3 )) || [[ "$1 $2" != "-mode=binary -format=json" ]]; then
  echo "fake govulncheck: unexpected call: $*" >&2
  exit 64
fi
[[ -f "$3" ]] || { echo "fake govulncheck: no binary $3" >&2; exit 1; }
fx() { if [[ "$1" == /* ]]; then echo "$1"; else echo "$TESTDATA_DIR/$1"; fi; }
if [[ "$(basename "$3")" == "cand" ]]; then
  n=$(( $(cat "$FAKE_STATE/cand" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$FAKE_STATE/cand"
  [[ -z "${FAKE_GV_FAIL:-}" ]] || { echo "govulncheck: loading packages failed" >&2; exit 1; }
  if (( n == 1 )) && [[ -n "${FAKE_GV_CAND_FIRST:-}" ]]; then
    cat "$(fx "$FAKE_GV_CAND_FIRST")"
  else
    cat "$(fx "${FAKE_GV_CAND:-govulncheck_cand.json}")"
  fi
else
  cat "$(fx "${FAKE_GV_LATEST:-govulncheck_latest.json}")"
fi
EOF
chmod +x "$TEST_TMP/bin/gh" "$TEST_TMP/bin/go" "$TEST_TMP/bin/govulncheck"
export PATH="$TEST_TMP/bin:$PATH"

# make_facts <path> <digest JSON value>: the facts.json fields scan.sh reads.
make_facts() {
  jq -n --argjson d "$2" '{schema: 1, repo: "pivotal-cf/replicator", tool: "replicator",
    latest: {tag: "0.22.0", published_at: "2026-06-09T21:27:09Z", tag_commit: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    releases: [{tag: "0.22.0", draft: false, prerelease: false, published_at: "2026-06-09T21:27:09Z",
      assets: [{name: "replicator-linux.tar.gz", digest: "sha256:1111111111111111111111111111111111111111111111111111111111111111"},
               {name: "replicator-linux", digest: $d}]}]}' > "$1"
}
FACTS="$TEST_TMP/facts.json"
make_facts "$FACTS" "\"sha256:${ASSET_SHA}\""

# scan_case <desc> <want exit> [FACTS_ARG=<facts.json>] [VAR=value...]: run scan.sh in a fresh
# work dir ($TEST_TMP/work); scan.json lands in $TEST_TMP/scan.json.
scan_case() {
  local desc="$1" want="$2" rc=0 facts="$FACTS" arg
  shift 2
  for arg in "$@"; do
    if [[ "$arg" == FACTS_ARG=* ]]; then
      facts="${arg#FACTS_ARG=}"
    fi
  done
  rm -rf "$FAKE_STATE" "$TEST_TMP/work" "$TEST_TMP/scan.json"
  mkdir -p "$FAKE_STATE"
  : > "$FAKE_LOG"
  env SOURCE_DIR="$TEST_TMP/src" WORK_DIR="$TEST_TMP/work" "$@" \
    bash "$SCAN" "$facts" "$TEST_TMP/scan.json" > "$TEST_TMP/stdout" 2> "$TEST_TMP/stderr" || rc=$?
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
q() { jq -c "$1" "$TEST_TMP/scan.json" 2>/dev/null; }

echo "=== happy path ==="
scan_case "verified asset, built candidate, matching DB timestamps" 0
assert "scan.json matches the 5.9 contract exactly" \
  "[[ \$(q .) == '{\"schema\":1,\"latest\":{\"asset_sha256\":\"$ASSET_SHA\",\"digest_ok\":true,\"findings\":[\"GO-2026-4970\",\"GO-2026-5026\",\"GO-2026-6443\"],\"db_last_modified\":\"2026-10-07T14:10:51Z\"},\"candidate\":{\"findings\":[\"GO-2026-4970\"],\"db_last_modified\":\"2026-10-07T14:10:51Z\"},\"db_rerun\":false}' ]]"
assert "latest asset and checksums.txt downloaded with gh release download into work/latest" \
  "[[ \$(calls 'gh release download 0.22.0 -R pivotal-cf/replicator -p replicator-linux -p checksums.txt -D $TEST_TMP/work/latest') == 1 ]]"
assert "candidate built in SOURCE_DIR with CGO_ENABLED=0 go build -trimpath -o work/cand ." \
  "[[ \$(calls 'go build -trimpath -o $TEST_TMP/work/cand . cwd=$TEST_TMP/src CGO_ENABLED=0') == 1 ]]"
assert "govulncheck ran once on each binary in binary/json mode" \
  "[[ \$(calls 'govulncheck -mode=binary -format=json $TEST_TMP/work/latest/replicator-linux') == 1 && \$(calls 'govulncheck -mode=binary -format=json $TEST_TMP/work/cand') == 1 ]]"
assert "raw govulncheck streams kept as work/latest.json and work/cand.json" \
  "[[ -s '$TEST_TMP/work/latest.json' && -s '$TEST_TMP/work/cand.json' ]]"
assert "public log has counts but no finding ids" \
  "grep -q 'has 3 findings, candidate 1' '$TEST_TMP/stdout' && ! grep -q 'GO-20' '$TEST_TMP/stdout' '$TEST_TMP/stderr'"

echo "=== asset verification (exit 2) ==="
scan_case "sha256 differs from checksums.txt" 2 FAKE_CHECKSUMS=mismatch
assert "mismatch is reported against checksums.txt" "grep -q 'does not match checksums.txt' '$TEST_TMP/stderr'"
scan_case "checksums.txt has no line for replicator-linux" 2 FAKE_CHECKSUMS=missing
make_facts "$TEST_TMP/facts_other.json" '"sha256:2222222222222222222222222222222222222222222222222222222222222222"'
scan_case "sha256 differs from the API digest" 2 FACTS_ARG="$TEST_TMP/facts_other.json"
assert "mismatch is reported against the API digest" "grep -q 'does not match the API digest' '$TEST_TMP/stderr'"
make_facts "$TEST_TMP/facts_null.json" 'null'
scan_case "API digest missing (null)" 2 FACTS_ARG="$TEST_TMP/facts_null.json"
assert "nothing downloaded when the digest is missing" "[[ \$(calls 'gh ') == 0 ]]"
make_facts "$TEST_TMP/facts_bad.json" '"md5:0123"'
scan_case "API digest malformed" 2 FACTS_ARG="$TEST_TMP/facts_bad.json"
jq 'del(.releases[0].assets[1])' "$FACTS" > "$TEST_TMP/facts_noasset.json"
scan_case "release has no replicator-linux asset" 2 FACTS_ARG="$TEST_TMP/facts_noasset.json"
assert "no scan.json written on failure" "[[ ! -e '$TEST_TMP/scan.json' ]]"

echo "=== vuln DB timestamps ==="
scan_case "candidate DB newer, re-run of both matches" 0 FAKE_GV_CAND_FIRST=govulncheck_cand_mismatch.json
assert "db_rerun is true and timestamps agree" \
  "[[ \$(q '[.db_rerun, .latest.db_last_modified, .candidate.db_last_modified]') == '[true,\"2026-10-07T14:10:51Z\",\"2026-10-07T14:10:51Z\"]' ]]"
assert "both binaries scanned twice" \
  "[[ \$(calls 'govulncheck -mode=binary -format=json $TEST_TMP/work/latest/replicator-linux') == 2 && \$(calls 'govulncheck -mode=binary -format=json $TEST_TMP/work/cand') == 2 ]]"
scan_case "timestamps still differ after the re-run" 2 FAKE_GV_CAND=govulncheck_cand_mismatch.json
assert "re-ran exactly once (4 scans)" "[[ \$(calls 'govulncheck ') == 4 ]]"
assert "no scan.json written on failure" "[[ ! -e '$TEST_TMP/scan.json' ]]"

echo "=== tool failures (exit 3) ==="
scan_case "gh release download fails" 3 FAKE_DOWNLOAD_FAIL=1
scan_case "download lacks the asset" 3 FAKE_DOWNLOAD_PARTIAL=1
scan_case "go build fails" 3 FAKE_GO_FAIL=1
scan_case "go build writes no binary" 3 FAKE_GO_NOOUT=1
scan_case "govulncheck exits non-zero" 3 FAKE_GV_FAIL=1
printf 'not json\n' > "$TEST_TMP/garbage.json"
scan_case "govulncheck output is not a JSON stream" 3 FAKE_GV_CAND="$TEST_TMP/garbage.json"
scan_case "govulncheck output has no config.db_last_modified" 3 FAKE_GV_LATEST=govulncheck_noconfig.json

echo "=== inputs (exit 2) ==="
scan_case "SOURCE_DIR unset" 2 SOURCE_DIR=
scan_case "SOURCE_DIR does not exist" 2 SOURCE_DIR="$TEST_TMP/nope"
scan_case "facts.json missing" 2 FACTS_ARG="$TEST_TMP/nope.json"
jq '.latest.tag = "v0.22.0"' "$FACTS" > "$TEST_TMP/facts_tag.json"
scan_case "latest.tag not semver" 2 FACTS_ARG="$TEST_TMP/facts_tag.json"
jq '.tool = "winfs-injector"' "$FACTS" > "$TEST_TMP/facts_tool.json"
scan_case "tool does not match repo" 2 FACTS_ARG="$TEST_TMP/facts_tool.json"

echo ""
echo "scan_test: $TOTAL tests, $FAILED failed"
if (( FAILED > 0 )); then
  exit 1
fi
exit 0
