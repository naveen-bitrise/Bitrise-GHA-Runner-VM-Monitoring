# SPEC: Supabase Integration + Webapp Build Dashboard

**Status:** Draft
**Date:** 2026-04-06

---

## 1. Objective

Replace New Relic as the data store with Supabase (PostgreSQL), and extend the existing
Sinatra webapp to show two views:

1. **VM Metrics** — CPU, memory, load, swap charts for a selected build run, loaded from
   Supabase (replacing CSV file reads).
2. **Builds Dashboard** — build analytics view modelled on `Supabase-Build-Dashoard-Ref.png`:
   summary stats (p90, p50, build count, total duration), a p90 trend line chart over time,
   and a per-workflow breakdown chart.

**Target users:** Bitrise platform engineers monitoring GHA Mac runner VM performance and
build duration trends.

---

## 2. Architecture

### Current Flow (new-relic branch)
```
VM Boot → warmup_runner.sh → monitor_daemon.sh (5s polling)
GHA Job Running → collect_metrics.sh → /tmp/gha-monitoring/monitoring-*.csv
GHA Job Completes → newrelic_hook.sh
                      → send_metrics_to_newrelic.sh    → NR Metrics API
                      → send_build_info_to_newrelic.sh → NR Events API
VM destroyed
```

### New Flow (supabase branch)
```
VM Boot → warmup_runner.sh → monitor_daemon.sh (5s polling)
GHA Job Running → collect_metrics.sh → /tmp/gha-monitoring/monitoring-*.csv  [unchanged]
GHA Job Completes → supabase_hook.sh
                      → send_metrics_to_supabase.sh    → Supabase metrics table (batch)
                      → send_build_info_to_supabase.sh → Supabase builds table (one row)
VM destroyed

Webapp (Sinatra) → Supabase REST API → renders VM Metrics + Builds pages
```

CSV commits to `metrics/` in git are **removed** — Supabase is the sole data store.
NR scripts are **removed** from the warmup path.

---

## 3. Supabase Schema

### Table: `metrics`

Stores one row per 5-second sample. Created with:

```sql
create table metrics (
  id            bigserial primary key,
  run_id        text not null,
  vm_name       text not null,
  sampled_at    timestamptz not null,
  cpu_user      numeric(6,2),
  cpu_system    numeric(6,2),
  cpu_idle      numeric(6,2),
  cpu_nice      numeric(6,2),
  memory_used_mb   numeric(10,2),
  memory_free_mb   numeric(10,2),
  memory_cached_mb numeric(10,2),
  load1         numeric(8,2),
  load5         numeric(8,2),
  load15        numeric(8,2),
  swap_used_mb  numeric(10,2),
  swap_free_mb  numeric(10,2)
);

create index metrics_run_id_idx on metrics (run_id);
create index metrics_vm_name_idx on metrics (vm_name);
create index metrics_sampled_at_idx on metrics (sampled_at desc);
```

### Table: `builds`

Stores one row per completed GHA job. Created with:

```sql
create table builds (
  id                     bigserial primary key,
  run_id                 text not null,
  run_number             text,
  run_attempt            text,
  vm_name                text not null,
  workflow_name          text,
  repository             text,
  branch                 text,
  sha                    text,
  event_name             text,
  actor                  text,
  commit_author          text,
  runner_os              text,
  runner_arch            text,
  cpu_count              integer,
  build_duration_seconds integer,
  started_at             timestamptz,
  completed_at           timestamptz
);

alter table builds add constraint builds_run_id_attempt_key unique (run_id, run_attempt);
create index builds_vm_name_idx   on builds (vm_name);
create index builds_workflow_idx  on builds (workflow_name);
create index builds_completed_idx on builds (completed_at desc);
```

### Table: `job_conclusions`

Stores one row per completed GHA job, written by the Supabase Edge Function receiving the
GitHub `workflow_job` webhook. Provides `conclusion` (failure rate) and `wait_time_seconds`
(queue time) — fields not available in the runner hook.

```sql
create table job_conclusions (
  id                     bigserial primary key,
  job_id                 bigint not null unique,   -- workflow_job.id (numeric, always unique)
  run_id                 text not null,
  run_attempt            integer,
  job_name               text,
  workflow_name          text,
  repository             text,
  branch                 text,
  sha                    text,
  conclusion             text,                     -- success/failure/cancelled/timed_out/skipped
  runner_name            text,
  runner_group_name      text,
  machine_os             text,                     -- parsed from labels
  machine_arch           text,                     -- parsed from labels
  cpu_count              integer,                  -- parsed from labels
  runner_type            text,                     -- self-hosted or github-hosted
  actor                  text,                     -- sender.login (commit pusher)
  wait_time_seconds      integer,                  -- started_at − created_at
  build_duration_seconds integer,                  -- completed_at − started_at
  created_at             timestamptz,              -- when job was queued
  started_at             timestamptz,              -- when job started running
  completed_at           timestamptz
);

create index job_conclusions_run_id_idx     on job_conclusions (run_id);
create index job_conclusions_runner_idx     on job_conclusions (runner_name);
create index job_conclusions_completed_idx  on job_conclusions (completed_at desc);
create index job_conclusions_conclusion_idx on job_conclusions (conclusion);
```

**Matching to `builds`:** `job_conclusions` is populated independently from `builds`. For
display purposes, they can be joined on `run_id + runner_name` (= `vm_name`). This is exact
for ephemeral runners. For non-ephemeral runners running matrix jobs, `started_at` proximity
can disambiguate when `run_id + runner_name` returns multiple candidates. The two tables are
usable independently — failure rate and queue time dashboards query `job_conclusions` directly;
VM metrics charts query `metrics` via `builds`.

**Row-Level Security:** Enable RLS. Allow `anon` role INSERT only (no SELECT from public).
Webapp uses the secret key (server-side, never exposed to browser).

---

## 3a. Data Model — Source Mapping

Documents which runner hook env vars and CSV columns map to which Supabase columns.

### `metrics` table — source: CSV rows via `send_metrics_to_supabase.sh`

| Column | Source | Notes |
|---|---|---|
| `run_id` | `$GITHUB_RUN_ID` | Set once per batch |
| `vm_name` | `$RUNNER_NAME` | Set once per batch |
| `sampled_at` | CSV `timestamp` column | Parsed `YYYY-MM-DD HH:MM:SS` → timestamptz |
| `cpu_user` | CSV `cpu_user` | % |
| `cpu_system` | CSV `cpu_system` | % |
| `cpu_idle` | CSV `cpu_idle` | % |
| `cpu_nice` | CSV `cpu_nice` | % |
| `memory_used_mb` | CSV `memory_used_mb` | MB |
| `memory_free_mb` | CSV `memory_free_mb` | MB |
| `memory_cached_mb` | CSV `memory_cached_mb` | MB |
| `load1` | CSV `load1` | 1-min load average |
| `load5` | CSV `load5` | 5-min load average |
| `load15` | CSV `load15` | 15-min load average |
| `swap_used_mb` | CSV `swap_used_mb` | MB |
| `swap_free_mb` | CSV `swap_free_mb` | MB |

### `builds` table — source: runner hook env vars + CSV via `send_build_info_to_supabase.sh`

| Column | Source | Notes |
|---|---|---|
| `run_id` | `$GITHUB_RUN_ID` | |
| `run_number` | `$GITHUB_RUN_NUMBER` | |
| `run_attempt` | `$GITHUB_RUN_ATTEMPT` | |
| `vm_name` | `$RUNNER_NAME` | |
| `workflow_name` | `$GITHUB_WORKFLOW` | |
| `repository` | `$GITHUB_REPOSITORY` | |
| `branch` | `$GITHUB_REF_NAME` | |
| `sha` | `$GITHUB_SHA` | |
| `event_name` | `$GITHUB_EVENT_NAME` | |
| `actor` | `$GITHUB_ACTOR` | |
| `commit_author` | `head_commit.author.username` from `$GITHUB_EVENT_PATH`; falls back to `$GITHUB_ACTOR` | Same logic as SPEC-VM-HOOK.md §5 |
| `runner_os` | `uname` (not `$RUNNER_OS` — accurate) | `macOS` or `Linux` |
| `runner_arch` | `$RUNNER_ARCH` | |
| `cpu_count` | `sysctl -n hw.logicalcpu` (macOS) / `nproc` (Linux) | |
| `build_duration_seconds` | last CSV timestamp − first CSV timestamp | |
| `started_at` | first CSV `timestamp` | |
| `completed_at` | `now` at hook execution | |

### `job_conclusions` table — source: GitHub `workflow_job` webhook via Supabase Edge Function

| Column | Webhook field | Notes |
|---|---|---|
| `job_id` | `workflow_job.id` | Numeric, always unique |
| `run_id` | `workflow_job.run_id` | |
| `run_attempt` | `workflow_job.run_attempt` | |
| `job_name` | `workflow_job.name` | May include matrix values e.g. `build (ubuntu, 18)` |
| `workflow_name` | `workflow_job.workflow_name` | |
| `repository` | `repository.full_name` | |
| `branch` | `workflow_job.head_branch` | |
| `sha` | `workflow_job.head_sha` | |
| `conclusion` | `workflow_job.conclusion` | `success`/`failure`/`cancelled`/`timed_out`/`skipped` |
| `runner_name` | `workflow_job.runner_name` | |
| `runner_group_name` | `workflow_job.runner_group_name` | |
| `machine_os` | parsed from `workflow_job.labels` | First of `macOS`/`Linux`/`Windows` |
| `machine_arch` | parsed from `workflow_job.labels` | First of `arm64`/`x64`/`ARM64`/`X64` |
| `cpu_count` | parsed from `workflow_job.labels` | First label matching `\d+core` |
| `runner_type` | parsed from `workflow_job.labels` | `self-hosted` if label present, else `github-hosted` |
| `actor` | `sender.login` | Commit pusher; proxy for commit author on push-based workflows |
| `wait_time_seconds` | `started_at − created_at` | Queue time |
| `build_duration_seconds` | `completed_at − started_at` | |
| `created_at` | `workflow_job.created_at` | When job was queued |
| `started_at` | `workflow_job.started_at` | When runner picked up the job |
| `completed_at` | `workflow_job.completed_at` | |

---

## 4. Shell Scripts

### 4.1 `scripts/send_metrics_to_supabase.sh`

- Reads the CSV line by line (skip header)
- Batches rows into JSON arrays of up to 500 rows
- POSTs to `https://<project>.supabase.co/rest/v1/metrics` with `apikey` and
  `Authorization: Bearer <secret_key>` headers
- Uses `Content-Type: application/json` and `Prefer: return=minimal`
- Reads `SUPABASE_PROJECT_ID` and `SUPABASE_SECRET_KEY` from `daemon.env`; derives `SUPABASE_URL="https://${SUPABASE_PROJECT_ID}.supabase.co"`
- Requires `GITHUB_RUN_ID` and `RUNNER_NAME` env vars (set by GHA)
- Logs to `/tmp/gha-monitoring/supabase.log`

### 4.2 `scripts/send_build_info_to_supabase.sh`

- Computes `started_at` from first CSV timestamp, `completed_at` = now
- Builds a single JSON object with all `builds` columns
- POSTs to `https://<project>.supabase.co/rest/v1/builds` (plain INSERT — each `run_id` is unique per job completion)
- Same auth as above
- Logs to `/tmp/gha-monitoring/supabase.log`

### 4.3 `scripts/supabase_hook.sh`

- Entry point registered as `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`
- Sources `daemon.env`
- Finds the latest CSV in `/tmp/gha-monitoring/`
- Calls `send_metrics_to_supabase.sh <csv>` then `send_build_info_to_supabase.sh <csv>`
- Mirrors the structure of the existing `newrelic_hook.sh`

### 4.4 `scripts/warmup_runner.sh` (updated)

- Clones repo, installs scripts as before
- Writes `daemon.env` with `SUPABASE_PROJECT_ID`, `SUPABASE_SECRET_KEY`, `SUPABASE_PUBLISHABLE_KEY`; `SUPABASE_URL` is derived from `SUPABASE_PROJECT_ID` in scripts
- Registers `supabase_hook.sh` as `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`
- NR placeholders removed

### 4.5 Supabase Edge Function: `gha-webhook`

Receives the GitHub `workflow_job` webhook and writes to `job_conclusions`. This is a
**Supabase Edge Function** (Deno/TypeScript), deployed within the same Supabase project.

**Why Edge Function instead of Cloudflare Worker:** same project as the database — no separate
deployment pipeline or account. The function has direct access to the Supabase client and
`service_role` key via the built-in `Deno.env`.

**Logic:**
1. Receive `POST` from GitHub
2. Validate `X-Hub-Signature-256` (HMAC-SHA256 using `GITHUB_WEBHOOK_SECRET`)
3. Parse JSON body; ignore if `action != "completed"`
4. Filter: skip if `workflow_job.runner_name` does not start with `RUNNER_NAME_PREFIX`
5. Parse `workflow_job.labels` → `machine_os`, `machine_arch`, `cpu_count`, `runner_type`
6. Compute `wait_time_seconds` = `started_at − created_at`, `build_duration_seconds` = `completed_at − started_at`
7. Insert into `job_conclusions` (upsert on `job_id` to handle webhook retries)
8. Return `200` always — even on insert failure, to prevent GitHub from retrying

**Environment variables (set as Supabase secrets):**
- `GITHUB_WEBHOOK_SECRET` — webhook secret configured in GitHub
- `RUNNER_NAME_PREFIX` — filter prefix e.g. `vm-pool`

**GitHub webhook setup — see Section 4.6 below.**

### 4.6 GitHub Webhook Setup

#### Org-level vs per-repo

| | Org-level | Per-repo |
|---|---|---|
| Where | Org → Settings → Webhooks | Repo → Settings → Webhooks |
| Access required | **Org owner** | Repo admin |
| Coverage | All current and future repos in the org automatically | One repo only |
| Recommended | **Yes** — one webhook covers every repo that uses Bitrise runners | Only if org-level access is unavailable |

**Use org-level.** Since the Edge Function filters by `runner_name` prefix anyway, jobs from
repos that don't use Bitrise runners are silently skipped — no noise, no cost.

#### Webhook URL

The Edge Function URL is automatically assigned by Supabase when the function is deployed.
No custom domain or DNS setup required — it is included in all Supabase plans:

```
https://<project-id>.supabase.co/functions/v1/gha-webhook
```

`<project-id>` is the unique ID shown in your Supabase dashboard project URL.

#### Steps (org-level)

1. Go to **GitHub → Your Org → Settings → Webhooks → Add webhook**
2. Set **Payload URL**: `https://<project-id>.supabase.co/functions/v1/gha-webhook`
3. Set **Content type**: `application/json`
4. Set **Secret**: choose a random string — this becomes `GITHUB_WEBHOOK_SECRET` in the Edge Function
5. Under **Which events**, choose **Let me select individual events** → tick **Workflow jobs** only (uncheck Push)
6. Ensure **Active** is checked → click **Add webhook**
7. In Supabase dashboard → Edge Functions → `gha-webhook` → Secrets, add:
   - `GITHUB_WEBHOOK_SECRET` = the secret from step 4
   - `RUNNER_NAME_PREFIX` = e.g. `vm-pool`

GitHub will immediately send a ping event; the function returns `200` (ping is ignored in the
handler logic).

---

## 5. Webapp

The existing Sinatra app (`webapp/app.rb` + `webapp/views/index.erb`) is extended with a
second page. The file structure becomes:

```
webapp/
  app.rb
  views/
    index.erb       — VM Metrics page (updated: loads from Supabase)
    builds.erb      — Builds dashboard page (new)
  config.ru
  Gemfile
```

### 5.1 Environment

The webapp reads two env vars:
```
SUPABASE_PROJECT_ID=<project-id>        # e.g. abcdefghijklmnop
SUPABASE_SECRET_KEY=sb_secret_...
```

`SUPABASE_URL` is derived at startup: `"https://#{ENV['SUPABASE_PROJECT_ID']}.supabase.co"`.
The project reference is visible in the Supabase dashboard URL
(Settings → General → Project ID, e.g. `xoqxeoaydgwqacvgqhvc`).

All Supabase calls are server-side (Ruby → Supabase REST). The secret key is never sent to
the browser.

### 5.2 VM Metrics page (`/`)

**Layout:**

```
[Started At: from ____  to ____]  [Workflow ▼]  [Branch ▼]  [Repository ▼]
[Machine Type ▼]  [vCPU Count ▼]
                                              ↓ narrow the selector below ↓
[VM selector: vm_name — run_id — workflow — started_at  ▼]  (10 items, desc by started_at)

──────────────────────────────────────────────────────────
  Job started: 2026-03-26 12:58:58 GMT   Duration: 302s
──────────────────────────────────────────────────────────
  [CPU]      [Memory]
  [Load avg] [Swap]
```

**Filter behaviour:**

All six filters (`started_at` range, `workflow_name`, `branch`, `repository`, `runner_os`,
`cpu_count`) are optional. Each time any filter changes, the VM selector is repopulated via
`GET /api/vm_runs`. Filters are applied server-side.

The VM selector shows at most **10 results**, ordered by `started_at desc`. Each option
displays as: `vm_name — run_id — workflow_name — started_at`.

Selecting a VM run loads its metrics via `GET /api/metrics/:run_id`.

**API endpoints:**

- `GET /api/vm_runs` — accepts query params:
  `started_from`, `started_to` (ISO8601), `workflow_name`, `branch`, `repository`,
  `runner_os`, `cpu_count`. Returns top 10 matching rows ordered by `started_at desc`.
  Each row: `{ run_id, vm_name, workflow_name, branch, started_at, build_duration_seconds }`.

- `GET /api/metrics/:run_id` — returns all metric rows for that run as JSON arrays:
  `{ timestamps, cpu: { user, system, idle }, memory: { used, free, cached, total },
     load: { load1, load5, load15 }, swap: { used, free }, job_start, duration_seconds }`.
  Replaces CSV file parsing.

- `GET /api/vm_filters` — returns distinct values for all six filter dropdowns, used to
  populate the dropdown options on page load.

Chart rendering is unchanged (Chart.js, same 4 charts, relative MM:SS time labels).

### 5.3 Builds Dashboard page (`/builds`)

Modelled on `Supabase-Build-Dashoard-Ref.png`.

**Layout:**

```
[Builds]                                         [Time range: Last 12 weeks ▼]

[Workflow ▼]  [Branch ▼]  [Machine Type ▼]  [vCPU Count ▼ — only if Machine Type is set]

[● p90      ] [ p50      ] [ Build count ] [ Total duration ] [ Failure rate ] [ Queue p90 ] [ Queue p50 ]
[  2m 52s   ] [   33s    ] [     278     ] [  5h 55m 45s   ] [    1.2%      ] [   45s     ] [   12s     ]
      ↑ active tab — selected metric drives both charts below

──────────────────────────────────────────────────────────────
  <selected metric> over time  (single line chart, weekly buckets)
──────────────────────────────────────────────────────────────

[Breakdown ──────────────────────────────────────] [Related builds]

  Breakdown tabs — only shown if their filter is NOT set:
  [● Workflow] [Branch] [Machine Type] [vCPU Count — only if Machine Type is set]

  <selected breakdown> per <dimension>
  (multi-line chart, one line per distinct value of the breakdown dimension)
```

No "Related builds" tab — the breakdown section contains only the dimension breakdown chart.

**Metric tabs:**

Each tab is a clickable card showing its current aggregate value for the selected filters
and time range. Clicking a tab switches both the main chart and the breakdown chart to
display that metric. Tabs:

| Tab | Aggregate shown on card | Chart Y-axis | Source table |
|-----|------------------------|--------------|--------------|
| p90 | `percentile(build_duration_seconds, 0.9)` formatted as `Xm Ys` | seconds | `builds` |
| p50 | `percentile(build_duration_seconds, 0.5)` formatted as `Xm Ys` | seconds | `builds` |
| Build count | `count(*)` | count | `builds` |
| Total duration | `sum(build_duration_seconds)` formatted as `Xh Ym Zs` | seconds | `builds` |
| Failure rate | `round(100.0 * count(*) filter (where conclusion != 'success') / count(*), 1)` shown as `X%` | percent | `job_conclusions` |
| Queue time (p90) | `percentile(wait_time_seconds, 0.9)` formatted as `Xm Ys` | seconds | `job_conclusions` |
| Queue time (p50) | `percentile(wait_time_seconds, 0.5)` formatted as `Xm Ys` | seconds | `job_conclusions` |

Default active tab: **p90**.

Tabs sourced from `job_conclusions` show `—` until Stream D (Edge Function) is live and
`job_conclusions` has data. The remaining tabs are unaffected.

**Top filters:**

Always shown: Workflow, Branch, Machine Type.
`vCPU Count` filter appears **only when Machine Type is set** (narrows within a machine type).

**Breakdown tabs — visibility rules:**

| Breakdown tab | Shown when |
|---|---|
| Workflow | `workflow` filter is **not** set |
| Branch | `branch` filter is **not** set |
| Machine Type | `runner_os` filter is **not** set |
| vCPU Count | `runner_os` filter **is** set (and `cpu_count` filter is not set) |

Default active breakdown tab: first visible tab (left to right).
If all filters are clear, default is **Workflow**.

**API endpoints:**

- `GET /api/builds/stats?weeks=12&workflow=&branch=&runner_os=&cpu_count=`
  Returns: `{ p90_seconds, p50_seconds, count, total_duration_seconds, failure_rate, queue_time_p90, queue_time_p50 }`
  Merges results from two Supabase RPCs: `builds_stats` (p90/p50/count/total) and
  `job_stats` (failure_rate/queue_time_p90/queue_time_p50). `job_stats` result is merged
  gracefully — missing or error returns `{}` so the endpoint works before Stream D is live.
  Used to populate all seven metric tab card values.

- `GET /api/builds/trend?weeks=12&metric=p90&workflow=&branch=&runner_os=&cpu_count=`
  `metric`: `p90`, `p50`, `count`, `total_duration`, `failure_rate`, `queue_time_p90`, `queue_time_p50`.
  Metrics from `builds` table → RPC `builds_trend`.
  Metrics from `job_conclusions` table (`failure_rate`, `queue_time_p90`, `queue_time_p50`) → RPC `job_trend`.
  Returns weekly buckets: `[{ week: "2026-01-04", value }, ...]`
  Used for the main trend line chart. Re-fetched on metric tab or filter change.

- `GET /api/builds/breakdown?weeks=12&metric=p90&dimension=workflow&workflow=&branch=&runner_os=&cpu_count=`
  `dimension`: `workflow`, `branch`, `runner_os`, `cpu_count`.
  Metrics from `builds` → RPC `builds_breakdown`. Metrics from `job_conclusions` → RPC `job_breakdown`.
  Returns one series per distinct dimension value:
  `{ "main": [{ week, value }, ...], "ci": [...] }`
  Used for the breakdown chart. Re-fetched on metric tab, breakdown tab, or filter change.
  Filters for the chosen dimension are ignored in this query (e.g. if `dimension=workflow`,
  the `workflow` filter param is not applied so all workflows appear as separate lines).

- `GET /api/builds/filters` — returns distinct values for all filter dropdowns:
  `{ workflows, branches, runner_os_values, cpu_counts }`.

**Time range:** dropdown with options:

| Option | Behaviour |
|---|---|
| Last week | `completed_at >= now - 7 days` |
| Last 4 weeks | `completed_at >= now - 28 days` |
| Last 12 weeks | `completed_at >= now - 84 days` — **default** |
| Last 6 months | `completed_at >= now - 180 days` |
| Custom | Reveals two date inputs: `from [date]  to [date]`. Applies `completed_at >= from AND completed_at <= to`. |

All trend/breakdown queries accept `from` and `to` ISO8601 date params instead of `weeks`
when Custom is active.

---

## 6. Code Style

- Ruby: follow existing Sinatra conventions in `app.rb`; helpers for Supabase HTTP calls
  in a `supabase_client` helper method (not a separate file — keep it simple)
- Shell scripts: `set -euo pipefail`, consistent with existing scripts in `scripts/`
- No ORMs, no additional Ruby gems beyond `sinatra`, `json`, `net/http` (stdlib)
- JavaScript: vanilla JS + Chart.js (no frameworks), same pattern as existing `index.erb`
- SQL queries: written inline as PostgREST query params or raw SQL via the
  Supabase `/rpc` endpoint for aggregations

---

## 7. Testing Strategy

- **Manual smoke test** after each script: run the hook against a real CSV, verify row
  appears in Supabase table
- **Edge Function smoke test**: send a test `workflow_job` webhook payload via `curl` to the
  deployed function URL; verify row appears in `job_conclusions` table editor
- **Webapp**: load `/` and `/builds` in browser, verify charts render and dropdowns
  populate
- No automated tests (mirrors existing project convention — no test suite)

---

## 8. Boundaries

### Always do
- Keep `daemon.env` permissions at `600`
- Use secret key (`SUPABASE_SECRET_KEY`) only server-side; never embed in frontend JS
- Log all Supabase HTTP responses (status + body on error) to `/tmp/gha-monitoring/supabase.log`
- Handle missing/empty CSV gracefully (skip send, log warning)
- Return `200` from the Edge Function even on insert failure — prevents GitHub webhook retries
- Validate `X-Hub-Signature-256` in the Edge Function before processing

### Ask before doing
- Adding new Supabase tables beyond `metrics`, `builds`, and `job_conclusions`
- Changing the Supabase RLS policy
- Modifying `collect_metrics.sh` or `monitor_daemon.sh`

### Never do
- Expose secret key (`SUPABASE_SECRET_KEY`) in browser-rendered HTML or JavaScript
- Commit `daemon.env` or any file containing real credentials
- Delete rows from Supabase tables (append-only)
- Make GitHub API calls from the Edge Function — the webhook payload contains everything needed

---

## 9. Out of Scope

- Authentication/login for the webapp
- Alerting (deferred)
- Historical CSV data migration to Supabase
- `event_name` (push/PR/schedule) in `job_conclusions` — not in the webhook payload without an API call
- Per-step metrics
