#!/usr/bin/env bash
set -euo pipefail

# scan.sh: downloads and verifies the latest release's linux asset, builds the candidate
# and runs govulncheck on both -> scan.json (LLDD-A section 5 step 4; shape per 5.9).
# Usage: scan.sh <facts.json> [scan.json]
# Env: SOURCE_DIR (the candidate checkout, required); WORK_DIR (default work).
# Exit codes: 0 ok, 2 anomaly / invalid input (checksum or digest mismatch, missing digest,
# DB timestamps still different after the re-run), 3 tool failure (download, build, govulncheck).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.github/auto-release/lib.sh
source "${SCRIPT_DIR}/lib.sh"

fail3() {
  echo "::error::scan.sh: $*" >&2
  exit 3
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# govulncheck writes a stream of pretty-printed JSON documents: slurp it with jq -s.
db_last_modified() {
  jq -r -s '[.[] | objects | .config | objects | .db_last_modified | strings] | first // empty' "$1" 2>/dev/null
}

findings() {
  jq -c -s '[.[] | objects | .finding | objects | .osv | strings] | unique' "$1" 2>/dev/null
}

FACTS="${1:-}"
SCAN_OUT="${2:-scan.json}"
[[ -n "$FACTS" && -f "$FACTS" ]] || die "scan.sh: usage: scan.sh <facts.json> [scan.json]"
SRC="${SOURCE_DIR:-}"
[[ -n "$SRC" && -d "$SRC" ]] || die "scan.sh: SOURCE_DIR must name the candidate checkout ('${SRC}')"
WORK="${WORK_DIR:-work}"

repo="$(jq -r '.repo // empty' "$FACTS" 2>/dev/null)" || die "scan.sh: ${FACTS} is not JSON"
tool="$(jq -r '.tool // empty' "$FACTS")"
latest="$(jq -r '.latest.tag // empty' "$FACTS")"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$tool" == "${repo#*/}" ]] || die "scan.sh: bad repo/tool in ${FACTS}"
is_semver "$latest" || die "scan.sh: bad latest.tag '${latest}' in ${FACTS}"
asset_name="${tool}-linux"
digest="$(jq -r --arg t "$latest" --arg n "$asset_name" \
  '[.releases[]? | select(.tag == $t) | .assets[]? | select(.name == $n) | .digest][0] // empty' "$FACTS")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "scan.sh: API digest of ${asset_name} ${latest} missing or malformed ('${digest}')"

# Latest asset: sha256 must match its checksums.txt line AND the API digest.
mkdir -p "${WORK}/latest"
gh release download "$latest" -R "$repo" -p "$asset_name" -p checksums.txt -D "${WORK}/latest" \
  || fail3 "gh release download ${latest} failed"
asset="${WORK}/latest/${asset_name}"
[[ -f "$asset" && -f "${WORK}/latest/checksums.txt" ]] || fail3 "download of ${latest} is missing ${asset_name} or checksums.txt"
listed_sha="$(awk -v n="$asset_name" '$2 == n || $2 == "*" n { print $1 }' "${WORK}/latest/checksums.txt")"
[[ "$listed_sha" =~ ^[0-9a-f]{64}$ ]] || die "scan.sh: checksums.txt of ${latest} has no single sha256 line for ${asset_name}"
asset_sha="$(sha256_of "$asset")"
[[ "$asset_sha" == "$listed_sha" ]] || die "scan.sh: ${asset_name} ${latest} sha256 ${asset_sha} does not match checksums.txt ${listed_sha}"
[[ "$asset_sha" == "${digest#sha256:}" ]] || die "scan.sh: ${asset_name} ${latest} sha256 ${asset_sha} does not match the API digest ${digest}"

# Candidate binary, built like the release (static, trimmed paths).
cand_bin="$(cd "$WORK" && pwd)/cand"
( cd "$SRC" && CGO_ENABLED=0 go build -trimpath -o "$cand_bin" . ) || fail3 "go build of the candidate in ${SRC} failed"
[[ -s "$cand_bin" ]] || fail3 "go build produced no ${cand_bin}"

scan_both() {
  govulncheck -mode=binary -format=json "$asset" > "${WORK}/latest.json" || fail3 "govulncheck failed on ${asset_name} ${latest}"
  govulncheck -mode=binary -format=json "$cand_bin" > "${WORK}/cand.json" || fail3 "govulncheck failed on the candidate"
  db_latest="$(db_last_modified "${WORK}/latest.json")" || fail3 "govulncheck output for ${latest} is not a JSON stream"
  db_cand="$(db_last_modified "${WORK}/cand.json")" || fail3 "govulncheck output for the candidate is not a JSON stream"
  [[ -n "$db_latest" && -n "$db_cand" ]] || fail3 "govulncheck output has no config.db_last_modified"
}

db_latest=''
db_cand=''
db_rerun=false
scan_both
if [[ "$db_latest" != "$db_cand" ]]; then
  note "scan.sh: vuln DB changed between scans (${db_latest} vs ${db_cand}); re-running both once"
  db_rerun=true
  scan_both
  [[ "$db_latest" == "$db_cand" ]] || die "scan.sh: vuln DB timestamps still differ after re-run (${db_latest} vs ${db_cand})"
fi

f_latest="$(findings "${WORK}/latest.json")" || fail3 "cannot read findings for ${latest}"
f_cand="$(findings "${WORK}/cand.json")" || fail3 "cannot read findings for the candidate"

scan="$(jq -n --arg sha "$asset_sha" --argjson fl "$f_latest" --arg dl "$db_latest" \
  --argjson fc "$f_cand" --arg dc "$db_cand" --argjson rerun "$db_rerun" \
  '{schema: 1,
    latest: {asset_sha256: $sha, digest_ok: true, findings: $fl, db_last_modified: $dl},
    candidate: {findings: $fc, db_last_modified: $dc},
    db_rerun: $rerun}')"
printf '%s\n' "$scan" > "$SCAN_OUT"
# Public log: counts only, never the remaining finding ids.
note "scan.sh: ${latest} has $(jq length <<<"$f_latest") findings, candidate $(jq length <<<"$f_cand") (DB ${db_latest})"
