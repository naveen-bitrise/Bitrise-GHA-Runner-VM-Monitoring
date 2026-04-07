# GitHub Actions Runner VM Monitoring

Monitor build and VM metrics on Bitrise-hosted GitHub Actions runners. Metrics are collected during each job, stored in Supabase, and visualised in a web dashboard with two views:

- **VM Metrics** — per-job time-series charts (CPU, memory, load average, swap)
- **Builds Dashboard** — aggregated trends across all jobs (build duration, failure rate, queue time)

---

## Table of Contents

- [Metrics Tracked](#metrics-tracked)
- [Architecture](#architecture)
- [Setup](#setup)
  - [1. Create a Supabase project](#1-create-a-supabase-project)
  - [2. Run the database setup SQL](#2-run-the-database-setup-sql)
  - [3. Deploy the GitHub webhook Edge Function](#3-deploy-the-github-webhook-edge-function)
  - [4. Configure the GitHub webhook](#4-configure-the-github-webhook)
  - [5. Configure the runner warmup script](#5-configure-the-runner-warmup-script)
  - [6. Add the warmup script to your Bitrise Runner Pool](#6-add-the-warmup-script-to-your-bitrise-runner-pool)
  - [7. Start the web app](#7-start-the-web-app)
- [Key Files](#key-files)
- [Dashboard](#dashboard)
- [Requirements](#requirements)
- [Troubleshooting](#troubleshooting)

---

## Metrics Tracked

<table><tr>
<td><img src="docs/Build Metrics.png" alt="Build Metrics" width="100%"></td>
<td><img src="docs/VM Metrics.png" alt="VM Metrics" width="100%"></td>
</tr></table>


### Build Metrics

Aggregated across all jobs and displayed on the Builds Dashboard (`/builds`). Sourced from two places:

| Metric | Description | Source |
|---|---|---|
| **Build duration (p90)** | 90th-percentile job duration — the upper bound most jobs stay under | `builds` table, populated by runner hook |
| **Build duration (p50)** | Median job duration — typical build time | `builds` table, populated by runner hook |
| **Build count** | Number of jobs completed in the selected period | `builds` table, populated by runner hook |
| **Total duration** | Total compute time consumed across all jobs | `builds` table, populated by runner hook |
| **Failure rate** | Percentage of jobs that did not complete with `success` conclusion | `job_conclusions` table, populated by GitHub webhook |
| **Queue time (p90)** | 90th-percentile wait from job queued to job started — indicates runner pool saturation | `job_conclusions` table, populated by GitHub webhook |
| **Queue time (p50)** | Median wait from job queued to job started | `job_conclusions` table, populated by GitHub webhook |

#### Breakdown

Each metric can be broken down by one of the following dimensions to identify which slice is driving a trend:

| Dimension | Description |
|---|---|
| **Workflow** | The GitHub Actions workflow name |
| **Branch** | The git branch the job ran on |
| **Repository** | The repository the job ran against |
| **Machine type** | Runner OS (macOS, Linux) |
| **vCPU count** | Number of vCPUs on the runner (only available when a machine type is selected) |

---

### VM Metrics

Time-series samples collected every 5 seconds during a job and displayed on the VM Metrics page (`/`). Sourced from the `metrics` table, populated by the runner hook at job end.

| Metric | Description | Source |
|---|---|---|
| **CPU user %** | CPU time spent running user-space processes (build steps, compilers, test runners) | `iostat` (macOS) / `/proc/stat` (Linux) |
| **CPU system %** | CPU time spent in the kernel (I/O, system calls, process management) | `iostat` (macOS) / `/proc/stat` (Linux) |
| **Memory used** | RAM actively in use by processes (GB) | `vm_stat` (macOS) / `/proc/meminfo` (Linux) |
| **Memory reclaimable** | File cache and buffers — can be freed under memory pressure (GB) | `vm_stat` (macOS) / `/proc/meminfo` (Linux) |
| **Memory free** | Completely unallocated RAM (GB) | `vm_stat` (macOS) / `/proc/meminfo` (Linux) |
| **Load average (1m)** | Average number of processes waiting for CPU over the last 1 minute | `sysctl` (macOS) / `/proc/loadavg` (Linux) |
| **Load average (5m)** | Same, smoothed over 5 minutes | `sysctl` (macOS) / `/proc/loadavg` (Linux) |
| **Load average (15m)** | Same, smoothed over 15 minutes — long-term trend | `sysctl` (macOS) / `/proc/loadavg` (Linux) |
| **Swap used** | Swap space currently in use — non-zero indicates memory pressure (GB) | `vm_stat` (macOS) / `/proc/meminfo` (Linux) |
| **Swap free** | Remaining swap capacity (GB) | `vm_stat` (macOS) / `/proc/meminfo` (Linux) |

Metrics are retained for **7 days** and then automatically deleted by a pg_cron job.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Bitrise Runner Warmup Script                           │
│                                                         │
│  warmup_runner.sh runs:                                 │
│    1. Clones this repo                                  │
│    2. Installs scripts to /usr/local/bin/gha-monitoring │
│    3. Writes daemon.env (Supabase credentials)          │
│    4. Registers supabase_hook.sh as                     │
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
│    → samples CPU, memory, load, swap every 5s           │
│    → writes to /tmp/gha-monitoring/monitoring-*.csv     │
└───────────────────────┬─────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│  GHA Job Completes                                      │
│                                                         │
│  GHA runner invokes supabase_hook.sh:                   │
│    → send_metrics_to_supabase.sh   — uploads CSV rows   │
│      to `metrics` table (CPU, memory, load, swap)       │
│    → send_build_info_to_supabase.sh — uploads build     │
│      metadata to `builds` table (workflow, branch,      │
│      duration, OS, vCPU count)                          │
└───────────────────────┬─────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│  GitHub Webhook → Supabase Edge Function (gha-webhook)  │
│                                                         │
│  GitHub fires a workflow_job webhook on every           │
│  job completion (configured at org or repo level).      │
│  The Edge Function validates the HMAC signature and     │
│  upserts a row into `job_conclusions`:                  │
│    → conclusion (success / failure / cancelled)         │
│    → queue time  — created_at to started_at             │
│    → build duration — started_at to completed_at        │
│    → runner labels — machine OS, arch, vCPU count       │
│                                                         │
│  This is what powers failure rate and queue time        │
│  on the Builds Dashboard.                               │
└───────────────────────┬─────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────┐
│  Web Dashboard  (http://localhost:4567)                 │
│                                                         │
│  Sinatra app reads from Supabase via REST API           │
│    /            → VM Metrics (per-job charts)           │
│    /builds      → Builds Dashboard (trends + breakdown) │
└─────────────────────────────────────────────────────────┘
```

---

## Setup

### 1. Create a Supabase project

Go to [supabase.com](https://supabase.com) and create a new project — a free tier account should be sufficient. Once created, collect the following credentials from **Settings → API** — you will need them in later steps:

| Key | Where to find | Used in |
|---|---|---|
| `SUPABASE_PROJECT_ID` | Project Settings → General → Project ID | `warmup_runner.sh` (runner), webapp |
| `SUPABASE_PUBLISHABLE_KEY` | Settings → API keys → Publishable and secret API Keys → Publishable Key | `warmup_runner.sh` (runner uploads metrics) |
| `SUPABASE_SECRET_KEY` | Settings → API keys → Publishable and secret API Keys → Secret Key | Webapp only — keep this secret |

### 2. Run the database setup SQL

In the Supabase dashboard, go to **SQL Editor** and run the contents of [`supabase/setup.sql`](supabase/setup.sql).

This creates:
- `metrics` table — time-series VM samples
- `builds` table — per-job build metadata
- `job_conclusions` table — job outcomes from GitHub webhook
- Row Level Security policies (anon: insert only; service role: full access)
- RPC functions for the Builds Dashboard aggregations
- A pg_cron job that deletes metrics older than 7 days daily at 02:00 UTC

### 3. Deploy the GitHub webhook Edge Function

The Edge Function in [`supabase/functions/gha-webhook/index.ts`](supabase/functions/gha-webhook/index.ts) receives GitHub `workflow_job` webhook events and records job conclusions (queue time, failure rate) into Supabase.

**Deploy via the Supabase dashboard:**

1. Go to **Edge Functions** → **Deploy a new function** → **via Editor**
2. Name it `gha-webhook` (bottom right of the page)
3. Paste the contents of `supabase/functions/gha-webhook/index.ts`
4. Deploy

**Set environment variables** (Edge Functions → Secrets):

| Variable | Value |
|---|---|
| `GITHUB_WEBHOOK_SECRET` | A secret string you choose — set any alphanumeric value and use the same value when configuring the GitHub webhook in the next step |
| `RUNNER_NAME_PREFIX` | Set to `vm-pool` — only jobs from runners whose name starts with this prefix are processed. Bitrise runners use `vm-pool` as the name prefix |

**Disable JWT verification** for this function (it uses HMAC instead): Edge Functions → `gha-webhook` → Settings → uncheck "Verify JWT".

### 4. Configure the GitHub webhook

In your GitHub organisation (or repository): **Settings → Webhooks → Add webhook**

| Field | Value |
|---|---|
| Payload URL | `https://<your-project-id>.supabase.co/functions/v1/gha-webhook` |
| Content type | `application/json` |
| Secret | The `GITHUB_WEBHOOK_SECRET` value from step 3 |
| Events | Select **individual events** → tick **Workflow jobs** only |

### 5. Configure the runner warmup script

Copy the contents of `scripts/warmup_runner.sh` to a text editor and replace the two placeholders with the credentials from step 1:

```bash
SUPABASE_PROJECT_ID="SUPABASE_PROJECT_ID_PLACEHOLDER"
SUPABASE_PUBLISHABLE_KEY="SUPABASE_PUBLISHABLE_KEY_PLACEHOLDER"
```

### 6. Add the warmup script to your Bitrise Runner Pool

Copy the updated script from the step above and paste it into your Bitrise Runner Pool warmup script configuration. The script will:
- Clone this repo onto each VM at boot
- Install the monitoring scripts
- Start the background daemon
- Register the post-job hook that uploads metrics to Supabase

### 7. Start the web app

Clone this repo and check out the `supabase` branch:

```bash
git clone https://github.com/naveen-bitrise/Bitrise-GHA-Runner-VM-Monitoring.git
cd Bitrise-GHA-Runner-VM-Monitoring
git checkout supabase
```

The webapp requires Ruby and the `SUPABASE_PROJECT_ID` and `SUPABASE_SECRET_KEY` from step 1.

**Install Ruby** (if not already installed — check with `ruby -v`):
```bash
# macOS (via Homebrew)
brew install ruby

# or use a version manager
brew install rbenv && rbenv install 3.3.0 && rbenv global 3.3.0
```

**Install dependencies:**
```bash
cd webapp
gem install bundler
bundle install
```

**Run the app:**
```bash
cd webapp
SUPABASE_PROJECT_ID=your_project_id \
SUPABASE_SECRET_KEY=your_service_role_key \
bundle exec ruby app.rb
```

Or export them first:

```bash
export SUPABASE_PROJECT_ID=your_project_id
export SUPABASE_SECRET_KEY=your_service_role_key
cd webapp && bundle exec ruby app.rb
```

Open [http://localhost:4567](http://localhost:4567) in your browser.

Optionally, you can host the app on a service such as [Render](https://render.com), [Fly.io](https://fly.io), or [Railway](https://railway.app) to make the dashboard accessible without running it locally.

---

## Key Files

| File | Purpose |
|---|---|
| `scripts/warmup_runner.sh` | VM boot script — installs monitoring and starts the daemon |
| `scripts/install_on_runner.sh` | Copies scripts to `/usr/local/bin/gha-monitoring/` |
| `scripts/monitor_daemon.sh` | Background daemon — detects GHA jobs and starts/stops collection |
| `scripts/collect_metrics.sh` | Samples CPU, memory, load, swap every 5s |
| `scripts/supabase_hook.sh` | GHA post-job hook — calls the two upload scripts below |
| `scripts/send_metrics_to_supabase.sh` | Uploads CSV rows to the `metrics` table |
| `scripts/send_build_info_to_supabase.sh` | Uploads job metadata to the `builds` table |
| `supabase/setup.sql` | Full database setup — tables, RLS, RPC functions, pg_cron |
| `supabase/functions/gha-webhook/index.ts` | Edge Function — receives GitHub webhook, records job conclusions |
| `webapp/app.rb` | Sinatra web app — serves the dashboard via Supabase REST API |
| `webapp/views/index.erb` | VM Metrics dashboard (per-job time-series charts) |
| `webapp/views/builds.erb` | Builds Dashboard (aggregated trends and breakdown) |

---

## Dashboard

### VM Metrics (`/`)

Shows four time-series charts for a selected job run. The x-axis shows elapsed time (MM:SS) from job start.

- **CPU Total** — user and system CPU usage as a percentage over time
- **Memory** — stacked: used / reclaimable cache / free (GB)
- **Load Average** — 1, 5, and 15-minute load averages with a reference line at the vCPU count
- **Swap** — swap used and free (GB)

Use the filters to narrow by date, workflow, branch, repository, machine type, or vCPU count.

### Builds Dashboard (`/builds`)

Aggregates data across all jobs. Click a metric card to switch the trend chart.

- **Top build time (p90)** — 90th-percentile build duration per week
- **Typical build time (p50)** — median build duration per week
- **Build count** — number of builds per week
- **Total duration** — total compute time consumed per week
- **Failure rate** — % of jobs that did not complete successfully
- **Queue time (p90 / p50)** — time from job queued to job started

The breakdown chart shows the selected metric sliced by workflow, branch, repository, machine type, or vCPU count.

---

## Requirements

### Runner (macOS / Linux)
- Bash 3.2+
- `curl` (for Supabase uploads)
- macOS: `iostat`, `vm_stat`, `sysctl`, `pagesize`
- Linux: `/proc/stat`, `/proc/meminfo`

### Web app
- Ruby 2.7+
- Bundler (`gem install bundler`)
- Supabase project with `SUPABASE_PROJECT_ID` and `SUPABASE_SECRET_KEY` (service role key)

---

## Troubleshooting

**Metrics not appearing in the dashboard**
Check the hook ran on the runner:
```bash
cat /tmp/gha-monitoring/daemon.log
```

**Hook not firing after job**
Verify `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` is set in the runner `.env`:
```bash
cat ~/actions-runner/.env
```

**Supabase upload errors**
Check `SUPABASE_PROJECT_ID` and `SUPABASE_PUBLISHABLE_KEY` in `/usr/local/bin/gha-monitoring/daemon.env`.

**Job conclusions not recording (failure rate / queue time empty)**
Confirm the GitHub webhook is delivering events: GitHub → Settings → Webhooks → Recent Deliveries. Check that the Edge Function is deployed and JWT verification is disabled.

**Web app fails to start**
Ensure `SUPABASE_PROJECT_ID` and `SUPABASE_SECRET_KEY` are exported before running `app.rb`. The secret key is the **service role** key (not the anon/publishable key).
