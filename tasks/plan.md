# Implementation Plan: SPEC-VM-HOOK.md

## Context

Replace `push_metrics_hook.sh` (GitHub CSV push) with a New Relic integration on the `new-relic` branch. At job completion, the runner posts VM time-series metrics (NR Metrics API) and a build info event (NR Events API). `collect_metrics.sh` and `monitor_daemon.sh` are untouched.

## Dependency Graph

```
[1] new-relic branch
      ↓
[2] send_metrics_to_newrelic.sh     [3] send_build_info_to_newrelic.sh
      ↓                                        ↓
             [4] newrelic_hook.sh (calls 2 + 3)
                        ↓
      [5] warmup_runner.sh    [6] install_on_runner.sh
                        ↓
           [7] README.md    [7a] newrelic_dashboard.json
                        ↓
                  [8] Smoke test
                        ↓
                  [9] Configure NR Alerts
```

Tasks 2 and 3 are independent and can be written in parallel. Task 7a (dashboard JSON) can be done in parallel with Task 7 (README).

---

## Task 1 — Create `new-relic` branch

**Action:** `git checkout -b new-relic`

**Acceptance criteria:**
- Branch exists and is checked out
- All existing files present

---

## Task 2 — Create `send_metrics_to_newrelic.sh`

**File:** `send_metrics_to_newrelic.sh`

**What it does:**
- Takes CSV path as `$1`
- Sources `/usr/local/bin/gha-monitoring/daemon.env` for `NEW_RELIC_LICENSE_KEY`
- Reads `common.attributes` from env vars (`$RUNNER_NAME`, `$RUNNER_ARCH`, `$GITHUB_RUN_ID`, `$GITHUB_JOB`, `$GITHUB_WORKFLOW`, `$GITHUB_REPOSITORY`, `$GITHUB_REF_NAME`) + detects `runner.os` via `uname` and `runner.cpu_count` via `sysctl`/`nproc`
- Skips header row; iterates all CSV data rows
- For each row: converts `timestamp` column (`YYYY-MM-DD HH:MM:SS`) to Unix epoch ms using platform-appropriate `date` command
- Builds single JSON payload: `[{ "common": { "attributes": {...} }, "metrics": [...] }]`
- Each row contributes 11 gauge data points (one per metric column)
- POSTs with `curl --silent --max-time 30 -X POST -H "Api-Key: $NEW_RELIC_LICENSE_KEY" -H "Content-Type: application/json"` to `https://metric-api.newrelic.com/metric/v1`
- Logs HTTP response code and any errors to `/tmp/gha-monitoring/newrelic.log`
- Exits 0 always — wraps all logic in a subshell or trap

**Key implementation notes:**
- JSON built via heredoc — no `jq`
- Timestamp conversion: `date -j -f "%Y-%m-%d %H:%M:%S" "$ts" "+%s"` (macOS) / `date -d "$ts" "+%s"` (Linux)
- CSV columns (0-indexed): `timestamp(0), cpu_user(1), cpu_system(2), cpu_idle(3), cpu_nice(4), memory_used_mb(5), memory_free_mb(6), memory_cached_mb(7), load1(8), load5(9), load15(10), swap_used_mb(11), swap_free_mb(12)`
- Metric names map: column → `gha.vm.cpu.user_pct`, `gha.vm.cpu.system_pct`, `gha.vm.cpu.idle_pct`, `gha.vm.memory.used_mb`, `gha.vm.memory.free_mb`, `gha.vm.memory.cached_mb`, `gha.vm.load.1m`, `gha.vm.load.5m`, `gha.vm.load.15m`, `gha.vm.swap.used_mb`, `gha.vm.swap.free_mb`

**Acceptance criteria:**
- Script exits 0 when run against `metrics/` sample CSV with real NR credentials
- Data appears in NR: `SELECT average(gha.vm.cpu.user_pct) FROM Metric SINCE 10 minutes ago`
- Script exits 0 when CSV is missing (logs warning, does not crash)
- Script exits 0 when NR returns non-2xx (logs error)

---

## Task 3 — Create `send_build_info_to_newrelic.sh`

**File:** `send_build_info_to_newrelic.sh`

**What it does:**
- Takes CSV path as `$1`
- Sources `daemon.env` for `NEW_RELIC_LICENSE_KEY` + `NEW_RELIC_ACCOUNT_ID`
- Detects `runner_os` via `uname`; `cpu_count` via `sysctl -n hw.logicalcpu` / `nproc`
- Parses `commit_author` from `$GITHUB_EVENT_PATH` using `python3`; falls back to `$GITHUB_ACTOR`
- Computes `build_duration_seconds` from first and last `timestamp` in CSV
- Builds `GHABuildInfo` JSON event with all fields from spec section 3b
- POSTs with `curl --silent --max-time 10` to `https://insights-collector.newrelic.com/v1/accounts/${NR_ACCOUNT_ID}/events`
- Logs response to `newrelic.log`; exits 0 always

**Key implementation notes:**
- Timestamp of first/last row: `awk -F',' 'NR==2{first=$1} {last=$1} END{print first, last}' "$CSV"`
- Convert to epoch seconds then subtract for duration
- JSON event is a single-element array: `[{ "eventType": "GHABuildInfo", ... }]`
- `build_duration_seconds` = 0 if CSV has fewer than 2 data rows

**Acceptance criteria:**
- Script exits 0 against sample CSV with real NR credentials
- Event appears in NR: `SELECT * FROM GHABuildInfo SINCE 10 minutes ago`
- All 17 fields present in the NR event
- `commit_author` falls back to `$GITHUB_ACTOR` when `$GITHUB_EVENT_PATH` is unset or absent

---

## Task 4 — Create `newrelic_hook.sh`

**File:** `newrelic_hook.sh`

**What it does:**
- Finds latest CSV: `ls -t /tmp/gha-monitoring/monitoring-*.csv 2>/dev/null | head -1`
- Logs to `/tmp/gha-monitoring/newrelic.log`
- If no CSV found: logs warning, exits 0
- Calls `INSTALL_DIR/send_metrics_to_newrelic.sh "$CSV"`
- Calls `INSTALL_DIR/send_build_info_to_newrelic.sh "$CSV"`
- Exits 0 always — wraps calls so failures don't propagate

**Acceptance criteria:**
- Script exits 0 when no CSV exists
- Script exits 0 when both send scripts succeed
- Script exits 0 when both send scripts fail (NR down / wrong key)

---

## Task 5 — Modify `warmup_runner.sh`

**Changes to existing file:**

Remove:
```bash
METRICS_REPO, METRICS_TOKEN in daemon.env block
cp push_metrics_hook.sh line
HOOK_SCRIPT pointing to push_metrics_hook.sh
```

Add:
```bash
NR_LICENSE_KEY="NEW_RELIC_LICENSE_KEY_PLACEHOLDER"
NR_ACCOUNT_ID="NEW_RELIC_ACCOUNT_ID_PLACEHOLDER"
```
Write to `daemon.env`:
```bash
export NEW_RELIC_LICENSE_KEY="${NR_LICENSE_KEY}"
export NEW_RELIC_ACCOUNT_ID="${NR_ACCOUNT_ID}"
```

Change hook registration to point at `newrelic_hook.sh` instead of `push_metrics_hook.sh`.

**Acceptance criteria:**
- `daemon.env` contains `NEW_RELIC_LICENSE_KEY` and `NEW_RELIC_ACCOUNT_ID`
- `daemon.env` does NOT contain `METRICS_REPO` or `METRICS_TOKEN`
- `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` points to `newrelic_hook.sh`

---

## Task 6 — Modify `install_on_runner.sh`

**Changes:**
- Add copy lines for 3 new scripts:
  ```bash
  cp newrelic_hook.sh "$INSTALL_DIR/"
  cp send_metrics_to_newrelic.sh "$INSTALL_DIR/"
  cp send_build_info_to_newrelic.sh "$INSTALL_DIR/"
  ```
- Remove copy of `push_metrics_hook.sh` (not present in `install_on_runner.sh` currently — it is copied in `warmup_runner.sh` directly, so no change needed here beyond adding the new scripts)

**Acceptance criteria:**
- All 3 new scripts present in `$INSTALL_DIR` after running `install_on_runner.sh`
- Scripts are executable (`chmod +x`)

---

## Task 7 — Update `README.md`

**Changes:**
- Replace "Create a Fine-Grained PAT" section with "Get New Relic credentials" (Ingest License Key + Account ID)
- Replace steps 3–4 (PAT setup, repo URL) with: replace `NEW_RELIC_LICENSE_KEY_PLACEHOLDER` and `NEW_RELIC_ACCOUNT_ID_PLACEHOLDER` in `warmup_runner.sh`
- Remove steps 6–8 (pull metrics, start webapp) — no longer needed
- Update architecture diagram
- Keep dashboard chart descriptions — update to reference New Relic instead of local webapp

**Acceptance criteria:**
- README contains no references to GitHub PAT, `METRICS_TOKEN`, or CSV push
- Setup steps are accurate for the New Relic flow

---

## Task 9 — Configure NR Alerts

No new files. Manual NR UI setup following SPEC-VM-HOOK.md section 8.

**Depends on:** Task 8 (smoke test) — `runner.os` and `runner.cpu_count` must be confirmed present in real NR data before thresholds can be set accurately.

**What to do:**
1. NR → Alerts → Alert Policies → Create policy: `GHA Runner Pool Saturation`
2. Add NRQL alert condition — macOS:
   ```sql
   SELECT uniqueCount(github.run_id) * latest(runner.cpu_count) AS total_vcpus_in_use
   FROM Metric
   WHERE runner.os = 'macOS'
   FACET runner.os
   TIMESERIES 5 minutes
   ```
   Threshold: `total_vcpus_in_use > VCPU_ALERT_THRESHOLD_MACOS` — replace with actual macOS pool vCPU capacity (e.g. 10 × 14-core = 140)
3. Add NRQL alert condition — Linux: same query with `WHERE runner.os = 'Linux'` and `VCPU_ALERT_THRESHOLD_LINUX`
4. NR → Alerts → Notification channels → Create Email destination (team distribution list)
5. NR → Alerts → Notification channels → Create Slack destination (workspace + channel)
6. Attach both destinations to the `GHA Runner Pool Saturation` policy

**Acceptance criteria:**
- Alert policy `GHA Runner Pool Saturation` exists in NR with two conditions (macOS + Linux)
- Both threshold placeholders replaced with actual pool vCPU capacity values
- Email + Slack destinations attached to the policy
- Verified: temporarily lower threshold below current `uniqueCount` value → confirm notifications received on both channels → restore threshold

---

## Task 7a — Create `newrelic_dashboard.json`

**File:** `newrelic_dashboard.json`

**What it does:**
- Importable NR dashboard JSON (Dashboard → Import dashboard in NR UI)
- Two pages: **VM Metrics** (time-series from `FROM Metric`) and **Build Info** (`FROM GHABuildInfo`)
- Six template variables as dropdowns (apply to all widgets): `repository`, `machine_type`, `cpu_count`, `workflow_name`, `branch`, `commit_author`
- Uses `YOUR_ACCOUNT_ID` as placeholder (replaced automatically on import or manually)

**VM Metrics page widgets:**
| Widget | Type | NRQL |
|---|---|---|
| CPU Usage Over Time | Line | `SELECT average(gha.vm.cpu.user_pct), average(gha.vm.cpu.system_pct) FROM Metric TIMESERIES` |
| Memory Over Time | Area | `SELECT average(gha.vm.memory.used_mb), average(gha.vm.memory.cached_mb), average(gha.vm.memory.free_mb) FROM Metric TIMESERIES` |
| Load Average Over Time | Line | `SELECT average(gha.vm.load.1m), average(gha.vm.load.5m), average(gha.vm.load.15m) FROM Metric TIMESERIES` |
| Swap Over Time | Area | `SELECT average(gha.vm.swap.used_mb), average(gha.vm.swap.free_mb) FROM Metric TIMESERIES` |

**Build Info page widgets:**
| Widget | Type | NRQL |
|---|---|---|
| Build Count | Billboard | `SELECT count(*) FROM GHABuildInfo` |
| Build Duration p50/p90 | Billboard | `SELECT percentile(build_duration_seconds, 50, 90) FROM GHABuildInfo` |
| Build Duration Over Time | Line | `SELECT percentile(build_duration_seconds, 50, 90) FROM GHABuildInfo TIMESERIES 1 hour` |
| By Machine Type | Bar | `SELECT average(build_duration_seconds) FROM GHABuildInfo FACET runner_os` |
| By vCPU Count | Bar | `SELECT average(build_duration_seconds) FROM GHABuildInfo FACET cpu_count` |
| By Workflow | Bar | `SELECT average(build_duration_seconds) FROM GHABuildInfo FACET workflow_name` |
| By Branch | Bar | `SELECT average(build_duration_seconds) FROM GHABuildInfo FACET branch` |
| By Commit Author | Bar | `SELECT average(build_duration_seconds) FROM GHABuildInfo FACET commit_author` |

**Acceptance criteria:**
- File is valid JSON
- Imports cleanly into NR via Dashboard → Import dashboard
- All widgets render after smoke test data lands in NR
- Template variable dropdowns populate from real data

---

## Task 8 — Smoke Test

Run locally against a real sample CSV from `metrics/` folder:

```bash
# Set fake env vars to simulate hook context
export GITHUB_RUN_ID=99999
export GITHUB_JOB=build
export GITHUB_WORKFLOW="Test CI"
export GITHUB_REPOSITORY=org/repo
export GITHUB_REF_NAME=main
export GITHUB_SHA=abc123
export GITHUB_EVENT_NAME=push
export GITHUB_ACTOR=naveen
export RUNNER_NAME=test-runner
export RUNNER_ARCH=ARM64

# Run send scripts against a real CSV
bash send_metrics_to_newrelic.sh metrics/vm-pool-g2-mac-m4pro-14c-54g-d45acf5-918105ff-dbf9/monitoring-20260326_125858.csv
bash send_build_info_to_newrelic.sh metrics/vm-pool-g2-mac-m4pro-14c-54g-d45acf5-918105ff-dbf9/monitoring-20260326_125858.csv
```

**Verify in NR Query Builder:**
```sql
SELECT average(gha.vm.cpu.user_pct) FROM Metric SINCE 30 minutes ago TIMESERIES
SELECT * FROM GHABuildInfo SINCE 30 minutes ago
```

**Acceptance criteria:**
- Both NR queries return data
- VM metrics timestamps match CSV timestamps (not current time)
- `GHABuildInfo` event has all expected fields
- `newrelic.log` shows `HTTP 200` for both calls
