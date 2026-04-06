# SPEC: VM Hook — New Relic Integration (`new-relic` branch)

**Status:** Draft
**Date:** 2026-04-05

---

## 1. Objective

Extend the existing GHA Runner VM Hook to send two types of telemetry to New Relic at job completion:

1. **VM Time-Series Metrics** — CPU, memory, load, swap sampled every 5s (batch-posted from CSV at job end)
2. **Build Info Event** — one event per job with accurate machine metadata and build duration (no job conclusion — see SPEC-GHA.md for that)

The GitHub repo push (`push_metrics_hook.sh`) is removed entirely. New Relic is the sole data destination.

**Target users:** Bitrise platform engineers monitoring GHA Mac runner VM performance.

---

## 2. Architecture

### Current Flow
```
VM Boot → warmup_runner.sh → monitor_daemon.sh (5s polling)
GHA Job Running → collect_metrics.sh → /tmp/gha-monitoring/monitoring-*.csv
GHA Job Completes → push_metrics_hook.sh → CSV pushed to GitHub repo
VM destroyed
```

### New Flow (`new-relic` branch)
```
VM Boot → warmup_runner.sh → monitor_daemon.sh (5s polling)
GHA Job Running → collect_metrics.sh → /tmp/gha-monitoring/monitoring-*.csv  [unchanged]
GHA Job Completes → newrelic_hook.sh
                      → send_metrics_to_newrelic.sh    → NR Metrics API (batch, full CSV)
                      → send_build_info_to_newrelic.sh → NR Events API (GHABuildInfo)
VM destroyed
```

`collect_metrics.sh` and `monitor_daemon.sh` are **unchanged**.

### New Relic APIs

| API | Purpose | Endpoint |
|---|---|---|
| Metrics API | Time-series VM gauges (batch, all rows) | `https://metric-api.newrelic.com/metric/v1` |
| Events API | One `GHABuildInfo` event per job | `https://insights-collector.newrelic.com/v1/accounts/{ACCOUNT_ID}/events` |

Both available on New Relic free tier (100 GB/month ingest, 30-day retention).

---

## 3. Data Model

### 3a. VM Metrics (Metrics API — gauge type)

All CSV rows posted as a single batch. One data point per row per metric.

| Metric Name | Unit | CSV Column | Description |
|---|---|---|---|
| `gha.vm.cpu.user_pct` | % | `cpu_user` | CPU user-space % |
| `gha.vm.cpu.system_pct` | % | `cpu_system` | CPU kernel % |
| `gha.vm.cpu.idle_pct` | % | `cpu_idle` | CPU idle % |
| `gha.vm.memory.used_mb` | MB | `memory_used_mb` | Active + wired memory |
| `gha.vm.memory.free_mb` | MB | `memory_free_mb` | Free pages |
| `gha.vm.memory.cached_mb` | MB | `memory_cached_mb` | Cached/reclaimable memory |
| `gha.vm.load.1m` | float | `load1` | 1-min load average |
| `gha.vm.load.5m` | float | `load5` | 5-min load average |
| `gha.vm.load.15m` | float | `load15` | 15-min load average |
| `gha.vm.swap.used_mb` | MB | `swap_used_mb` | Swap used |
| `gha.vm.swap.free_mb` | MB | `swap_free_mb` | Swap free |

**Common attributes** on every metric (NR `common.attributes` block):

| Attribute | Source | Example |
|---|---|---|
| `runner.name` | `$RUNNER_NAME` | `vm-pool-g2-mac-m4pro-14c-54g-...` |
| `runner.os` | `uname` (not env var — accurate) | `macOS` |
| `runner.arch` | `$RUNNER_ARCH` | `ARM64` |
| `runner.cpu_count` | `sysctl -n hw.logicalcpu` / `nproc` | `14` |
| `github.run_id` | `$GITHUB_RUN_ID` | `12345678` |
| `github.job` | `$GITHUB_JOB` | `build` |
| `github.workflow` | `$GITHUB_WORKFLOW` | `CI` |
| `github.repository` | `$GITHUB_REPOSITORY` | `org/repo` |
| `github.branch` | `$GITHUB_REF_NAME` | `main` |

**Timestamp:** Each data point uses the timestamp parsed from the CSV `timestamp` column, converted to Unix epoch milliseconds.

### 3b. Build Info Event (Events API)

Custom event type: `GHABuildInfo`

> **Note:** `conclusion` (success/failure) is NOT available in `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`.
> That is provided by the scheduled GHA workflow (see SPEC-GHA.md).
> The two datasets are **independent** — each serves different dashboard widgets. No join is needed or expected.

| Attribute | Source | Example |
|---|---|---|
| `eventType` | hardcoded | `GHABuildInfo` |
| `run_id` | `$GITHUB_RUN_ID` | `12345678` |
| `run_number` | `$GITHUB_RUN_NUMBER` | `42` |
| `run_attempt` | `$GITHUB_RUN_ATTEMPT` | `1` |
| `job_name` | `$GITHUB_JOB` | `build` |
| `workflow_name` | `$GITHUB_WORKFLOW` | `CI` |
| `repository` | `$GITHUB_REPOSITORY` | `org/repo` |
| `branch` | `$GITHUB_REF_NAME` | `main` |
| `sha` | `$GITHUB_SHA` | `abc123...` |
| `event_name` | `$GITHUB_EVENT_NAME` | `push` |
| `actor` | `$GITHUB_ACTOR` | `naveen` |
| `commit_author` | `head_commit.author.username` from `$GITHUB_EVENT_PATH` (push/PR events); falls back to `$GITHUB_ACTOR` for `schedule`/`workflow_dispatch` | `naveen` |
| `runner_name` | `$RUNNER_NAME` | `vm-pool-g2-mac-m4pro-14c-...` |
| `runner_os` | `uname` (accurate) | `macOS` |
| `runner_arch` | `$RUNNER_ARCH` | `ARM64` |
| `cpu_count` | `sysctl -n hw.logicalcpu` / `nproc` (accurate) | `14` |
| `build_duration_seconds` | last CSV timestamp − first CSV timestamp | `342` |
| `timestamp` | Unix epoch ms at hook execution | `1712345678000` |

---

## 4. Files

### New Files

| File | Purpose |
|---|---|
| `newrelic_hook.sh` | Registered as `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`; finds CSV, calls the two send scripts |
| `send_metrics_to_newrelic.sh` | Reads full CSV → builds batch gauge JSON → posts to NR Metrics API |
| `send_build_info_to_newrelic.sh` | Reads CSV timestamps + env vars → posts `GHABuildInfo` event |

### Modified Files

| File | Change |
|---|---|
| `warmup_runner.sh` | Remove GitHub PAT block; add `NR_LICENSE_KEY` + `NR_ACCOUNT_ID` placeholders; write to `daemon.env`; register `newrelic_hook.sh` as hook |
| `install_on_runner.sh` | Copy new scripts to `/usr/local/bin/gha-monitoring/`; remove `push_metrics_hook.sh` copy |
| `README.md` | Replace GitHub push setup with New Relic credentials setup |

### Unchanged Files

| File | Reason |
|---|---|
| `collect_metrics.sh` | Writes CSV as before — no changes |
| `monitor_daemon.sh` | Detects job start/stop — no changes |

### Removed

| File | Reason |
|---|---|
| `push_metrics_hook.sh` | Replaced by `newrelic_hook.sh` |

---

## 5. Script Specifications

### `newrelic_hook.sh`
- Registered as `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`
- Finds latest CSV: `ls -t /tmp/gha-monitoring/monitoring-*.csv 2>/dev/null | head -1`
- Calls `send_metrics_to_newrelic.sh "$CSV_PATH"`
- Calls `send_build_info_to_newrelic.sh "$CSV_PATH"`
- Exits 0 always — never fails a build

### `send_metrics_to_newrelic.sh`
- **Input:** CSV file path (`$1`)
- **Reads:** `daemon.env` for `NEW_RELIC_LICENSE_KEY`
- **Builds:** JSON with `common.attributes` block + array of gauge data points (all CSV rows × 11 metrics)
- **Timestamp conversion:** CSV `timestamp` column (`YYYY-MM-DD HH:MM:SS`) → Unix ms
  - macOS: `date -j -f "%Y-%m-%d %H:%M:%S" "$ts" "+%s"`
  - Linux: `date -d "$ts" "+%s"`
- **Posts:** `curl --max-time 30 --silent -X POST https://metric-api.newrelic.com/metric/v1`
- **Payload limit:** NR allows 1 MB / 10k data points per request. Typical build (60 rows × 11 metrics = 660 points) is well within limits
- **Logs errors** to `/tmp/gha-monitoring/newrelic.log`; exits 0 always

### `send_build_info_to_newrelic.sh`
- **Input:** CSV file path (`$1`)
- **Reads:** `daemon.env` for `NEW_RELIC_LICENSE_KEY` + `NEW_RELIC_ACCOUNT_ID`
- **Computes:** `build_duration_seconds` from first and last `timestamp` in CSV
- **Detects:** `runner_os` via `uname`; `cpu_count` via `sysctl -n hw.logicalcpu` or `nproc`
- **Builds:** `GHABuildInfo` JSON event from env vars + computed values
- **Posts:** `curl --max-time 10 --silent -X POST https://insights-collector.newrelic.com/v1/accounts/${NR_ACCOUNT_ID}/events`
- **Logs errors** to `/tmp/gha-monitoring/newrelic.log`; exits 0 always

### Commit Author Detection
```bash
COMMIT_AUTHOR=$(python3 -c "
import json, sys
try:
  d = json.load(open('$GITHUB_EVENT_PATH'))
  print(d.get('head_commit', {}).get('author', {}).get('username') or
        d.get('head_commit', {}).get('author', {}).get('name') or '')
except: print('')
" 2>/dev/null)
COMMIT_AUTHOR="${COMMIT_AUTHOR:-$GITHUB_ACTOR}"
```

`username` is the GitHub login; `name` is the git config name. `username` preferred — falls back to `name` — falls back to `$GITHUB_ACTOR` for event types without `head_commit` (`schedule`, `workflow_dispatch`, etc.).

### CPU / OS Detection (cross-platform)
```bash
if [[ "$(uname)" == "Darwin" ]]; then
  RUNNER_OS_ACTUAL="macOS"
  CPU_COUNT=$(sysctl -n hw.logicalcpu)
else
  RUNNER_OS_ACTUAL="Linux"
  CPU_COUNT=$(nproc)
fi
```

---

## 6. Credentials

`daemon.env` written by `warmup_runner.sh` — GitHub PAT entries removed:

```bash
NEW_RELIC_LICENSE_KEY=<ingest license key>
NEW_RELIC_ACCOUNT_ID=<numeric account id>
```

Placeholders in `warmup_runner.sh`:
```bash
NR_LICENSE_KEY="NEW_RELIC_LICENSE_KEY_PLACEHOLDER"
NR_ACCOUNT_ID="NEW_RELIC_ACCOUNT_ID_PLACEHOLDER"
```

License key type: **Ingest - License** (not user API key).
Found at: New Relic → API Keys → Create key → Type: Ingest - License.

---

## 7. NR Dashboard Widgets (VM data)

### Dashboard Filters (apply to all widgets)

New Relic template variables added to the dashboard. Each renders as a dropdown filter:

| Variable | Filters on | NR attribute |
|---|---|---|
| Time picker | All widgets | Built-in NR time picker |
| Repository | VM metrics + GHABuildInfo | `github.repository` / `repository` |
| Machine type | VM metrics + GHABuildInfo | `runner.os` / `runner_os` |
| vCPU count | VM metrics + GHABuildInfo | `runner.cpu_count` / `cpu_count` |
| Workflow name | VM metrics + GHABuildInfo | `github.workflow` / `workflow_name` |
| Branch | VM metrics + GHABuildInfo | `github.branch` / `branch` |
| Commit author | GHABuildInfo | `commit_author` |

All NRQL queries include `WHERE {{machine_type_var}} AND {{cpu_count_var}} AND {{workflow_var}} AND {{branch_var}}` via template variable injection (NR handles this automatically when variables are configured).

### Widgets

| Widget | Type | NRQL sketch |
|---|---|---|
| CPU usage over time | Line | `SELECT average(gha.vm.cpu.user_pct), average(gha.vm.cpu.system_pct) FROM Metric TIMESERIES` |
| Memory over time | Stacked area | `SELECT average(gha.vm.memory.used_mb), average(gha.vm.memory.cached_mb), average(gha.vm.memory.free_mb) FROM Metric TIMESERIES` |
| Load average over time | Line | `SELECT average(gha.vm.load.1m), average(gha.vm.load.5m), average(gha.vm.load.15m) FROM Metric TIMESERIES` |
| Swap over time | Stacked area | `SELECT average(gha.vm.swap.used_mb), average(gha.vm.swap.free_mb) FROM Metric TIMESERIES` |
| Build duration p50/p90 | Billboard | `SELECT percentile(build_duration_seconds, 50, 90) FROM GHABuildInfo` |
| Build count | Billboard | `SELECT count(*) FROM GHABuildInfo` |
| Build duration by machine type | Bar | `SELECT average(build_duration_seconds) FROM GHABuildInfo FACET runner_os` |
| Build duration by vCPU count | Bar | `SELECT average(build_duration_seconds) FROM GHABuildInfo FACET cpu_count` |
| Build duration by workflow | Bar | `SELECT average(build_duration_seconds) FROM GHABuildInfo FACET workflow_name` |
| Build duration by branch | Bar | `SELECT average(build_duration_seconds) FROM GHABuildInfo FACET branch` |
| Build duration by commit author | Bar | `SELECT average(build_duration_seconds) FROM GHABuildInfo FACET commit_author` |
| Build duration over time | Line | `SELECT percentile(build_duration_seconds, 50, 90) FROM GHABuildInfo TIMESERIES 1 hour` |

---

## 8. NR Alerts

### Overview

Alert on **pool saturation** — the total number of vCPUs in use across all concurrently running jobs on a given machine type exceeds a fixed threshold. This signals the runner pool is near or at capacity and new jobs may queue.

### How It Works

Each batch of VM metrics posted to the NR Metrics API includes `runner.cpu_count` and `github.run_id` in the `common.attributes` block. Crucially, each data point carries the **actual timestamp from the CSV** — spanning from job start time to job end time. Even though metrics are batch-posted at job completion, the data points are distributed across the build window in NR's time-series store.

This means `uniqueCount(github.run_id)` over a given time window accurately counts jobs that were **running** during that window (their metric data points overlap it). Multiplying by `runner.cpu_count` gives total vCPUs in use for that machine type at that time.

### Alert Condition (NRQL)

```sql
SELECT uniqueCount(github.run_id) * latest(runner.cpu_count) AS total_vcpus_in_use
FROM Metric
FACET runner.os
TIMESERIES 5 minutes
```

**Alert type:** Static threshold
**Evaluation window:** `TIMESERIES 5 minutes` — NR aggregates data into 5-minute buckets and evaluates the threshold against each bucket. The alert fires when the bucket value breaches the threshold for the configured number of consecutive windows.
**Alert priority:** Warning

### One Condition Per Machine Type

Machine types are `macOS` and `Linux` only — no sub-type breakdown by vCPU count. Each condition has its own threshold.

| Alert condition name | WHERE filter | Threshold | Notes |
|---|---|---|---|
| macOS pool saturation | `runner.os = 'macOS'` | `> VCPU_ALERT_THRESHOLD_MACOS` | Set to total macOS pool vCPU capacity (e.g. 10 × 14-core = 140) |
| Linux pool saturation | `runner.os = 'Linux'` | `> VCPU_ALERT_THRESHOLD_LINUX` | Set to total Linux pool vCPU capacity |

Both thresholds are placeholders — replace with actual values when configuring. A typical warning level is 80% of pool capacity.

### Notification Channels

| Channel | Configuration |
|---|---|
| Email | NR → Alerts → Notification channels → Email destination → team distribution list |
| Slack | NR → Alerts → Notification channels → Slack destination → select workspace + channel |

Both channels attached to the same alert policy. NR notifies all configured channels simultaneously on trigger and on resolution.

### Setup Steps

1. **NR → Alerts → Alert Policies → Create policy** — name: `GHA Runner Pool Saturation`
2. **Add NRQL alert condition** using the query above (one per machine type)
3. **Set threshold**: `total_vcpus_in_use > VCPU_ALERT_THRESHOLD` for 5 consecutive data windows
4. **Create notification destinations** under Alerts → Notification channels: Email + Slack
5. **Attach destinations** to the `GHA Runner Pool Saturation` policy

---

## 9. Code Style

- Shell scripts — consistent with existing codebase
- `#!/bin/bash` + `set -euo pipefail`
- 2-space indent
- JSON via heredoc with variable interpolation — no `jq`, no external tools
- All NR calls: `curl --silent --max-time N` — never blocking
- Log file: `/tmp/gha-monitoring/newrelic.log`

---

## 10. Boundaries

### Always do
- Exit 0 from all NR scripts — never fail a build
- Log curl errors and non-2xx responses to `newrelic.log`
- Detect OS/CPU from the system (`uname`, `sysctl`) — not from env vars or labels

### Never do
- Let NR failures propagate to the hook exit code
- Commit credential values to the repo
- Push to GitHub — no git, no PAT
- Modify `collect_metrics.sh` or `monitor_daemon.sh`

---

## 11. Out of Scope

- Job conclusion / failure rate — covered in SPEC-GHA.md
- Wait time (queue → start) — only available from GitHub API, covered in SPEC-GHA.md
- Per-step metrics
- Linux runner support for `collect_metrics.sh` — it uses macOS-specific tools (`vm_stat`, `sysctl`, BSD `iostat`) and would need a separate Linux implementation
- The new NR hook scripts (`newrelic_hook.sh`, `send_metrics_to_newrelic.sh`, `send_build_info_to_newrelic.sh`) are written to be cross-platform via `uname` guards — Linux support is an implementation detail, not a spec change
