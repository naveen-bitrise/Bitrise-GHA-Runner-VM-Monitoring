# SPEC: Linux Metric Collection

**Status:** Draft
**Date:** 2026-04-05

---

## 1. Objective

Implement metric collection for Linux GHA runners, producing the **same 13-column CSV format** as the existing macOS `collect_metrics.sh`. All downstream scripts (`send_metrics_to_newrelic.sh`, `newrelic_hook.sh`, `send_build_info_to_newrelic.sh`) require zero changes — they consume the CSV without knowing the OS.

---

## 2. Approach

Two options:

**Option A: Separate script `collect_metrics_linux.sh`**
`monitor_daemon.sh` detects OS at startup and calls the appropriate script:
```bash
if [[ "$(uname)" == "Darwin" ]]; then
  MONITOR_SCRIPT="collect_metrics.sh"
else
  MONITOR_SCRIPT="collect_metrics_linux.sh"
fi
```

**Option B: Make `collect_metrics.sh` cross-platform**
Add `uname` guards inside the existing script — same file, platform-specific blocks for each metric.

→ **Option A is recommended.** Keeps macOS script unchanged and untouched; Linux implementation is isolated and independently testable.

---

## 3. CSV Format (unchanged — must match exactly)

```
timestamp,cpu_user,cpu_system,cpu_idle,cpu_nice,memory_used_mb,memory_free_mb,memory_cached_mb,load1,load5,load15,swap_used_mb,swap_free_mb
2026-04-05 10:00:00,12.5,3.2,84.3,0,8192,4096,2048,1.23,1.45,1.67,0,0
```

| Column | Type | Notes |
|---|---|---|
| `timestamp` | `YYYY-MM-DD HH:MM:SS` | Local time, same format as macOS script |
| `cpu_user` | float (%) | User-space CPU % |
| `cpu_system` | float (%) | Kernel CPU % |
| `cpu_idle` | float (%) | Idle CPU % |
| `cpu_nice` | float (%) | Nice CPU % (may be 0 on most runners) |
| `memory_used_mb` | integer (MB) | Active memory in use |
| `memory_free_mb` | integer (MB) | Free/available memory |
| `memory_cached_mb` | integer (MB) | Cached/reclaimable memory |
| `load1` | float | 1-min load average |
| `load5` | float | 5-min load average |
| `load15` | float | 15-min load average |
| `swap_used_mb` | integer (MB) | Swap used |
| `swap_free_mb` | integer (MB) | Swap free |

---

## 4. Linux Collection Commands

### CPU (`/proc/stat`)

`/proc/stat` first line: `cpu  user nice system idle iowait irq softirq steal`

```bash
read_cpu() {
  awk '/^cpu / {
    user=$2; nice=$3; system=$4; idle=$5
    total = user + nice + system + idle + $6 + $7 + $8 + $9
    print user, system, idle, nice, total
  }' /proc/stat
}
```

To get a percentage, take two samples 1 second apart and compute the delta:
```
cpu_user_pct   = (delta_user   / delta_total) * 100
cpu_system_pct = (delta_system / delta_total) * 100
cpu_idle_pct   = (delta_idle   / delta_total) * 100
cpu_nice_pct   = (delta_nice   / delta_total) * 100
```

> macOS `iostat` naturally outputs a 5-second average. Linux `/proc/stat` requires two reads with a sleep to compute a delta. Use `sleep 1` between reads at the start of each 5-second sample.

### Memory (`/proc/meminfo`)

```bash
read_memory() {
  awk '
    /^MemTotal:/     { total=$2 }
    /^MemFree:/      { free=$2 }
    /^Buffers:/      { buffers=$2 }
    /^Cached:/       { cached=$2 }
    /^SwapTotal:/    { swap_total=$2 }
    /^SwapFree:/     { swap_free=$2 }
    END {
      used    = total - free - buffers - cached
      cached_mb = int((buffers + cached) / 1024)
      used_mb   = int(used / 1024)
      free_mb   = int(free / 1024)
      swap_used_mb = int((swap_total - swap_free) / 1024)
      swap_free_mb = int(swap_free / 1024)
      print used_mb, free_mb, cached_mb, swap_used_mb, swap_free_mb
    }
  ' /proc/meminfo
}
```

`/proc/meminfo` values are in kB — divide by 1024 for MB.

### Load Average (`/proc/loadavg`)

```bash
read_load() {
  awk '{print $1, $2, $3}' /proc/loadavg
}
```

`/proc/loadavg` format: `load1 load5 load15 running/total last_pid`

### Swap (same as memory — from `/proc/meminfo`)

`SwapTotal` and `SwapFree` are already read in the memory block above.

---

## 5. Script Specification: `collect_metrics_linux.sh`

- **Same interface as `collect_metrics.sh`:**
  - `$1` — output CSV file path (default: `/tmp/gha-monitoring/monitoring-data.csv`)
  - Samples every 5 seconds
  - Writes CSV header on first run
  - Traps `SIGTERM`/`SIGINT` for graceful shutdown
  - Runs until killed by `monitor_daemon.sh`

- **CPU sampling:** two `/proc/stat` reads 1 second apart at the start of each loop iteration; remaining ~4 seconds spent sleeping

- **Dependencies:** `awk`, `bash` — both standard on all Linux distros; no additional tools required

- **No `iostat`, `vm_stat`, `sysctl`, or `pagesize`** — these are macOS-only and must not be used

---

## 6. Changes to `monitor_daemon.sh`

Add OS detection at startup to select the correct collection script:

```bash
if [[ "$(uname)" == "Darwin" ]]; then
  MONITOR_SCRIPT="${DAEMON_DIR}/collect_metrics.sh"
else
  MONITOR_SCRIPT="${DAEMON_DIR}/collect_metrics_linux.sh"
fi
```

Everything else in `monitor_daemon.sh` remains unchanged — it still starts/stops the script and passes the output file path as `$1`.

---

## 7. Changes to `install_on_runner.sh` and `warmup_runner.sh`

- `install_on_runner.sh`: copy `collect_metrics_linux.sh` to `$INSTALL_DIR` alongside the existing scripts
- `warmup_runner.sh`: copy `collect_metrics_linux.sh` during install step

---

## 8. Dependencies

| Tool | macOS | Linux | Notes |
|---|---|---|---|
| `awk` | ✅ | ✅ | Standard on all distros |
| `bash` | ✅ | ✅ | Standard on all distros |
| `/proc/stat` | ❌ | ✅ | Linux kernel virtual filesystem |
| `/proc/meminfo` | ❌ | ✅ | Linux kernel virtual filesystem |
| `/proc/loadavg` | ❌ | ✅ | Linux kernel virtual filesystem |
| `vm_stat` | ✅ | ❌ | macOS only |
| `iostat` (BSD) | ✅ | ❌ | macOS only (Linux `iostat` has different output) |
| `sysctl` (BSD) | ✅ | ❌ | Linux `sysctl` has different keys |

---

## 9. Testing

- Run `collect_metrics_linux.sh` on a Linux runner for 30 seconds
- Verify CSV has correct 13 columns and correct header
- Feed output CSV to `send_metrics_to_newrelic.sh` — verify data appears in NR Query Builder
- Compare metric values against `htop` / `free -m` / `cat /proc/loadavg` for sanity

---

## 10. Out of Scope

- `iostat`-style per-disk I/O metrics (not in current macOS CSV either)
- Per-CPU breakdown (aggregate only, matching macOS behaviour)
- Container/cgroup-aware memory reporting (use host-level `/proc/meminfo`)
