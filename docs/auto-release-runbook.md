# Upstream Auto-Release Runbook: Operation and Semantics

This runbook documents the operational semantics, release modes, janitor behavior, tracking issue lifecycle, and recovery procedures for the `auto-release` workflow across `pivotal-cf/replicator` and `pivotal-cf/winfs-injector`.

## 1. Release Modes

The workflow release behavior is governed by the `RELEASE_MODE` constant in `.github/workflows/auto-release.yml` (or lowered per-run via `workflow_dispatch` `mode_override`):

| Mode | Evaluation & Scan | Tag & Release Dispatched | Waiting Run Janitor | Tracking Issues Maintained |
|---|---|---|---|---|
| `off` | Skipped (early exit) | No | Yes (stale runs cancelled) | No (no-op) |
| `report` | Full decision + job summary | No | Yes (stale runs cancelled) | Yes (`stuck` alerts + resolutions closed) |
| `notify` | Full decision + job summary | No (human tags) | Yes (stale runs cancelled) | Yes (`release` warranted + `stuck` alerts + resolutions closed) |
| `approve` | Full decision + approval gate | Yes (after reviewer approval) | Yes (stale runs cancelled) | Yes (`stuck` alerts + resolutions closed) |
| `auto` | Full decision + direct act | Yes (unattended) | Yes (stale runs cancelled) | Yes (`stuck` alerts + resolutions closed) |

### Off and Report Semantics

- **`off` mode**: The `config` job determines effective mode is `off`. All subsequent release evaluation steps are skipped. Operational cleanup (`janitor.sh`) still runs in `config` to clean up any abandoned waiting runs. `notify.sh` exits 0 cleanly without any write.
- **`report` mode**: Evaluates candidates, runs vulnerability scans, and records complete decision summaries in GitHub Actions step summaries. It creates **no git tags or GitHub releases**. However, `report` mode actively performs operational hygiene:
  1. `janitor.sh` cancels waiting runs older than `APPROVAL_STALE_HOURS` (24h).
  2. `notify.sh` creates/updates `stuck` release issue alerts if a tag has existed for `STUCK_RELEASE_ALERT_HOURS` (2h) without a published GitHub release.
  3. `notify.sh` closes resolved `auto-release` tracking issues when resolved.

## 2. Operational Invariants and Protections

- **Pagination & Fail-Closed**: All API listing endpoints in `janitor.sh` (waiting runs) and `notify.sh` (tracking issues) use `--paginate` via `get_all_pages`. Incomplete or malformed JSON pages fail closed (exit 2) immediately without executing partial cancellations, closures, or issue mutations.
- **Issue Deduplication**: `notify.sh` maintains at most one open tracking issue per exact title under label `auto-release`. If duplicate open issues are discovered across paginated responses, the primary issue is updated and duplicate issues are commented on and closed.
- **Waiting Run Janitor**: Only cancels runs of `.github/workflows/auto-release.yml` with status `waiting` whose age exceeds `APPROVAL_STALE_HOURS`. Active, queued, or completed runs are never touched.

## 3. Recovery Procedures

### Stuck Release Recovery
- A stuck release indicates a lightweight git tag was pushed or created, but no published GitHub release was generated within `STUCK_RELEASE_ALERT_HOURS`.
- Investigation:
  1. Inspect the Actions tab for `ci.yml` runs on the tag ref.
  2. If the CI run failed, fix the underlying build/test failure.
  3. Re-dispatch the release workflow on the tag:
     ```bash
     gh workflow run ci.yml -R pivotal-cf/<repo> --ref <tag>
     ```
  4. Once GoReleaser publishes the release assets and Docker Hub image, the next scheduled `auto-release` run will automatically resolve and close the stuck release tracking issue.
  5. Never move or delete git tags automatically.
