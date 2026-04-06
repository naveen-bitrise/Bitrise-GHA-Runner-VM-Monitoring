# GitHub Actions Runner VM Monitoring

Monitor CPU, memory, load, and swap on Bitrise-hosted GitHub Actions Mac runners. Metrics are automatically collected during each job and sent to New Relic for dashboarding and alerting.

---

## Quick Start

### 1. Fork this repo

Fork `naveen-bitrise/Bitrise-GHA-Runner-VM-Monitoring` to your own GitHub account or org.

### 2. Get New Relic credentials

You need two values from New Relic:

**Ingest License Key**
→ New Relic → API Keys → Create key → Type: **Ingest - License**

**Account ID**
→ New Relic → (click your account name, top right) → Account ID (numeric)

### 3. Add the warmup script to your Bitrise Runner Pool

Copy the contents of `warmup_runner.sh` and paste it into your Bitrise Runner Pool warmup script configuration.

### 4. Replace the New Relic placeholders

In `warmup_runner.sh`, replace:

```bash
NR_LICENSE_KEY="NEW_RELIC_LICENSE_KEY_PLACEHOLDER"
NR_ACCOUNT_ID="NEW_RELIC_ACCOUNT_ID_PLACEHOLDER"
```

with your actual Ingest License Key and Account ID.

### 5. Run a GHA job on the Bitrise runner

Trigger any GitHub Actions workflow that runs on your Bitrise runner pool. When the job finishes, the runner hook automatically sends metrics to New Relic.

### 6. Import the dashboard

Go to **New Relic → Dashboards → Import dashboard**, paste the contents of `newrelic_dashboard.json`, and click Import.

The dashboard has two pages:
- **VM Metrics** — CPU, memory, load, swap time-series charts
- **Build Info** — build duration stats and breakdowns by machine type, vCPU count, workflow, branch, commit author

Six dropdown filters at the top apply to all widgets: repository, machine type, vCPU count, workflow, branch, commit author.

### 7. View data in New Relic Query Builder

```sql
-- VM time-series metrics
SELECT average(gha.vm.cpu.user_pct), average(gha.vm.cpu.system_pct)
FROM Metric SINCE 30 minutes ago TIMESERIES

-- Build info events
SELECT * FROM GHABuildInfo SINCE 30 minutes ago
```

---

## Dashboard Charts

All charts are available in New Relic as NRQL queries. Filterable by time, repository, machine type, vCPU count, workflow name, branch, and commit author.

### CPU Usage

Shows CPU usage as a percentage over time.

- **user** (`gha.vm.cpu.user_pct`) — CPU time spent running user-space processes (your build steps, compilers, test runners etc.)
- **system** (`gha.vm.cpu.system_pct`) — CPU time spent in the kernel (I/O, process management, system calls)

High `user` spikes indicate compute-heavy build steps. High `system` may indicate heavy file I/O or process spawning.

### Memory

Stacked area chart showing how physical RAM is distributed across the job.

- **used** (`gha.vm.memory.used_mb`) — memory actively in use by processes
- **cached** (`gha.vm.memory.cached_mb`) — cached/reclaimable memory (file cache, buffers) — macOS will reclaim this if needed
- **free** (`gha.vm.memory.free_mb`) — completely unused memory

A growing `used` band with shrinking `free` indicates memory pressure.

### Load Average

Shows the system load average over three rolling windows.

- **load1** (`gha.vm.load.1m`) — 1-minute load average (most responsive to sudden spikes)
- **load5** (`gha.vm.load.5m`) — 5-minute load average
- **load15** (`gha.vm.load.15m`) — 15-minute load average (smoothed long-term trend)

Load average represents the number of processes waiting for CPU time. On a 14-core runner, values below 14 generally indicate the system is not CPU-saturated.

### Swap

Shows swap space usage in MB.

- **used** (`gha.vm.swap.used_mb`) — how much swap is currently in use
- **free** (`gha.vm.swap.free_mb`) — remaining swap capacity

Swap usage indicates the system ran low on physical RAM and started paging to disk, which significantly slows builds. A flat line near 0 MB is ideal.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Bitrise VM Boot                                        │
│                                                         │
│  warmup_runner.sh runs:                                 │
│    1. Clones this repo                                  │
│    2. Installs collect_metrics.sh + monitor_daemon.sh   │
│       + newrelic_hook.sh + send_* scripts               │
│    3. Writes daemon.env (NR license key + account ID)   │
│    4. Registers newrelic_hook.sh as                     │
│       ACTIONS_RUNNER_HOOK_JOB_COMPLETED                 │
│    5. Starts monitor_daemon.sh in background            │
└───────────────────────┬─────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│  GHA Job Running                                        │
│                                                         │
│  monitor_daemon.sh polls every 5s for Runner.Worker     │
│    → detects job start                                  │
│    → starts collect_metrics.sh                          │
│    → collects CPU, memory, load, swap every 5s          │
│    → writes to /tmp/gha-monitoring/monitoring-*.csv     │
└───────────────────────┬─────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│  GHA Job Completes                                      │
│                                                         │
│  GHA runner invokes newrelic_hook.sh:                   │
│    → finds latest CSV in /tmp/gha-monitoring/           │
│    → send_metrics_to_newrelic.sh                        │
│        → batch-posts all CSV rows as gauges             │
│        → New Relic Metrics API                          │
│    → send_build_info_to_newrelic.sh                     │
│        → posts GHABuildInfo event                       │
│        → New Relic Events API                           │
│                                                         │
│  VM is then destroyed                                   │
└─────────────────────────────────────────────────────────┘
```

### Key Files

| File | Purpose |
|---|---|
| `warmup_runner.sh` | VM boot script — installs monitoring and starts the daemon |
| `install_on_runner.sh` | Copies scripts to `/usr/local/bin/gha-monitoring/` |
| `monitor_daemon.sh` | Background daemon — detects GHA jobs and starts/stops collection |
| `collect_metrics.sh` | Samples CPU, memory, load, swap every 5s and writes CSV |
| `newrelic_hook.sh` | GHA post-job hook — orchestrates sending data to New Relic |
| `send_metrics_to_newrelic.sh` | Posts CSV rows as batch gauges to NR Metrics API |
| `send_build_info_to_newrelic.sh` | Posts `GHABuildInfo` event to NR Events API |
| `newrelic_dashboard.json` | Importable NR dashboard (Dashboards → Import dashboard) |
| `metrics/<vm-name>/` | Historical CSV files (collected on `main` branch) |

---

## Requirements

### Runner (macOS or Linux)
- Bash 3.2+
- `curl` (for posting to New Relic)
- Standard macOS utilities: `iostat`, `vm_stat`, `sysctl`, `pagesize` (metric collection only)
- `python3` (for commit author detection from `GITHUB_EVENT_PATH`)

---

## Troubleshooting

**Metrics not being sent after job**
Check that `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` was written to `/Users/vagrant/actions-runner/.env`:
```bash
cat /Users/vagrant/actions-runner/.env
```

**Daemon not detecting jobs**
Check daemon logs on the runner:
```bash
tail -f /tmp/gha-monitoring/daemon.log
```

**New Relic not receiving data**
Check the hook log on the runner:
```bash
tail -f /tmp/gha-monitoring/newrelic.log
```

A successful send looks like:
```
[2026-03-26 13:05:00] send_metrics: HTTP 202 — 60 rows, 660 data points
[2026-03-26 13:05:01] send_build_info: HTTP 200 — build_duration=302s
```

**Credentials not found**
Verify `daemon.env` contains the NR keys:
```bash
cat /usr/local/bin/gha-monitoring/daemon.env
```
