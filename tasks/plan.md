# Implementation Plan: SPEC-SUPABASE.md

**Branch:** `supabase` (create from `main`)
**Date:** 2026-04-06

---

## Dependency Graph

```
[MANUAL] Supabase project setup (metrics + builds + job_conclusions tables, RLS, env vars)
              │
              ├─────────────────────────────────────────────────────────────┐
              ▼                                                              ▼
┌─────────────────────────────────────────────────────────┐   ┌────────────────────────────┐
│  Stream A — Runner Scripts                               │   │  Stream D — Edge Function  │
│                                                          │   │                            │
│  A1: send_metrics_to_supabase.sh                         │   │  D1: supabase/functions/   │
│  A2: send_build_info_to_supabase.sh                      │   │      gha-webhook/index.ts  │
│        (A1 and A2 independent — build in parallel)       │   │              │             │
│              │                                           │   │              ▼             │
│              ▼                                           │   │  D2: Deploy function +     │
│  A3: supabase_hook.sh  (calls A1 + A2)                   │   │      set Supabase secrets  │
│              │                                           │   │              │             │
│              ▼                                           │   │              ▼             │
│  A4: warmup_runner.sh update                             │   │  D3: Configure GitHub      │
│              │                                           │   │      org webhook           │
│              ▼                                           │   │              │             │
│  CHECKPOINT A — smoke test: runner posts data to         │   │              ▼             │
│  Supabase, rows visible in table editor                  │   │  CHECKPOINT D — send test  │
└─────────────────────────────────────────────────────────┘   │  payload, row appears in   │
              │                                                │  job_conclusions           │
              │  (Stream B and C both require CHECKPOINT A)    └────────────────────────────┘
              │   (Stream D is independent of A, B, C)
    ┌─────────┴──────────┐
    ▼                    ▼
┌─────────────┐    ┌──────────────────────────────────────┐
│  Stream B   │    │  Stream C                             │
│  VM Metrics │    │  Builds Dashboard                     │
│  page       │    │                                       │
│             │    │  C1: /api/builds/* endpoints          │
│  B1: Restore│    │        (stats, trend, breakdown,      │
│  webapp     │    │         filters)                      │
│  skeleton   │    │              │                        │
│  from git   │    │              ▼                        │
│      │      │    │  C2: builds.erb frontend              │
│      ▼      │    │        (metric tabs, charts,          │
│  B2: Supabase│   │         breakdown tabs, time range    │
│  client     │    │         selector)                     │
│  helper +   │    │                                       │
│  /api/vm_*  │    │  CHECKPOINT C — /builds loads,        │
│  endpoints  │    │  all 4 tabs render, trend + breakdown │
│      │      │    │  charts repopulate on filter change   │
│      ▼      │    └──────────────────────────────────────┘
│  B3: index.erb  │
│  update     │
│  (filters + │
│  API calls) │
│             │
│  CHECKPOINT │
│  B — / loads│
│  6 filters  │
│  populate,  │
│  charts     │
│  render     │
└─────────────┘

F1: Nav links (after both B and C checkpoints pass)
```

Stream A and Stream D are both unblocked after Pre-work and can proceed in parallel.
Stream D is fully independent — it populates `job_conclusions` via GitHub webhook.
Stream B and Stream C can proceed in parallel after Checkpoint A.
Within each stream, tasks are sequential.

---

## Pre-work: Supabase Manual Setup

**Not a code task — document only.**

### What to do
1. Create a Supabase project at https://supabase.com.
2. Run the following SQL in the Supabase SQL editor:

```sql
-- metrics table
create table metrics (
  id               bigserial primary key,
  run_id           text not null,
  vm_name          text not null,
  sampled_at       timestamptz not null,
  cpu_user         numeric(6,2),
  cpu_system       numeric(6,2),
  cpu_idle         numeric(6,2),
  cpu_nice         numeric(6,2),
  memory_used_mb   numeric(10,2),
  memory_free_mb   numeric(10,2),
  memory_cached_mb numeric(10,2),
  load1            numeric(8,2),
  load5            numeric(8,2),
  load15           numeric(8,2),
  swap_used_mb     numeric(10,2),
  swap_free_mb     numeric(10,2)
);
create index metrics_run_id_idx     on metrics (run_id);
create index metrics_vm_name_idx    on metrics (vm_name);
create index metrics_sampled_at_idx on metrics (sampled_at desc);

-- builds table
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
-- indexes: row lookups
alter table builds add constraint builds_run_id_attempt_key unique (run_id, run_attempt);
create index builds_vm_name_idx   on builds (vm_name);
create index builds_workflow_idx  on builds (workflow_name);
create index builds_completed_idx on builds (completed_at desc);
-- indexes: aggregation filters (branch, runner_os, cpu_count not covered above)
create index builds_branch_idx    on builds (branch);
create index builds_runner_os_idx on builds (runner_os);
create index builds_cpu_count_idx on builds (cpu_count);

-- job_conclusions table (populated by Edge Function via GitHub workflow_job webhook)
create table job_conclusions (
  id                     bigserial primary key,
  job_id                 bigint not null unique,
  run_id                 text not null,
  run_attempt            integer,
  job_name               text,
  workflow_name          text,
  repository             text,
  branch                 text,
  sha                    text,
  conclusion             text,
  runner_name            text,
  runner_group_name      text,
  machine_os             text,
  machine_arch           text,
  cpu_count              integer,
  runner_type            text,
  actor                  text,
  wait_time_seconds      integer,
  build_duration_seconds integer,
  created_at             timestamptz,
  started_at             timestamptz,
  completed_at           timestamptz
);
create index job_conclusions_run_id_idx     on job_conclusions (run_id);
create index job_conclusions_runner_idx     on job_conclusions (runner_name);
create index job_conclusions_completed_idx  on job_conclusions (completed_at desc);
create index job_conclusions_conclusion_idx on job_conclusions (conclusion);

-- RLS: allow anon INSERT only; webapp uses service_role (bypasses RLS)
alter table metrics          enable row level security;
alter table builds           enable row level security;
alter table job_conclusions  enable row level security;
create policy "anon insert metrics"         on metrics         for insert to anon with check (true);
create policy "anon insert builds"          on builds          for insert to anon with check (true);
create policy "anon insert job_conclusions" on job_conclusions for insert to anon with check (true);

-- aggregation helper: shared time range expression
-- (used inline in each function below)

-- builds_stats: p90, p50, count, total for the filtered set
create or replace function builds_stats(
  p_weeks     int     default 12,
  p_workflow  text    default null,
  p_branch    text    default null,
  p_runner_os text    default null,
  p_cpu_count int     default null,
  p_from      date    default null,
  p_to        date    default null
)
returns json
language sql
security definer
as $$
  select json_build_object(
    'p90_seconds',            percentile_cont(0.9) within group (order by build_duration_seconds),
    'p50_seconds',            percentile_cont(0.5) within group (order by build_duration_seconds),
    'count',                  count(*),
    'total_duration_seconds', coalesce(sum(build_duration_seconds), 0)
  )
  from builds
  where
    (p_workflow   is null or workflow_name = p_workflow)
    and (p_branch     is null or branch       = p_branch)
    and (p_runner_os  is null or runner_os    = p_runner_os)
    and (p_cpu_count  is null or cpu_count    = p_cpu_count)
    and completed_at >= coalesce(p_from::timestamptz, (current_date - (p_weeks * 7))::timestamptz)
    and completed_at <  coalesce((p_to  + 1)::timestamptz, now() + interval '1 second')
$$;

-- builds_trend: weekly buckets for a single metric
create or replace function builds_trend(
  p_weeks     int     default 12,
  p_metric    text    default 'p90',
  p_workflow  text    default null,
  p_branch    text    default null,
  p_runner_os text    default null,
  p_cpu_count int     default null,
  p_from      date    default null,
  p_to        date    default null
)
returns table(week date, value numeric)
language sql
security definer
as $$
  select
    date_trunc('week', completed_at)::date as week,
    case p_metric
      when 'p90'            then percentile_cont(0.9) within group (order by build_duration_seconds)
      when 'p50'            then percentile_cont(0.5) within group (order by build_duration_seconds)
      when 'count'          then count(*)::numeric
      when 'total_duration' then sum(build_duration_seconds)::numeric
    end as value
  from builds
  where
    (p_workflow   is null or workflow_name = p_workflow)
    and (p_branch     is null or branch       = p_branch)
    and (p_runner_os  is null or runner_os    = p_runner_os)
    and (p_cpu_count  is null or cpu_count    = p_cpu_count)
    and completed_at >= coalesce(p_from::timestamptz, (current_date - (p_weeks * 7))::timestamptz)
    and completed_at <  coalesce((p_to  + 1)::timestamptz, now() + interval '1 second')
  group by 1
  order by 1
$$;

-- builds_breakdown: weekly buckets per dimension value
-- the filter for the chosen dimension is intentionally ignored so all its values appear
create or replace function builds_breakdown(
  p_weeks      int     default 12,
  p_metric     text    default 'p90',
  p_dimension  text    default 'workflow',
  p_workflow   text    default null,
  p_branch     text    default null,
  p_runner_os  text    default null,
  p_cpu_count  int     default null,
  p_from       date    default null,
  p_to         date    default null
)
returns table(week date, dim text, value numeric)
language sql
security definer
as $$
  select
    date_trunc('week', completed_at)::date as week,
    case p_dimension
      when 'workflow'  then workflow_name
      when 'branch'    then branch
      when 'runner_os' then runner_os
      when 'cpu_count' then cpu_count::text
    end as dim,
    case p_metric
      when 'p90'            then percentile_cont(0.9) within group (order by build_duration_seconds)
      when 'p50'            then percentile_cont(0.5) within group (order by build_duration_seconds)
      when 'count'          then count(*)::numeric
      when 'total_duration' then sum(build_duration_seconds)::numeric
    end as value
  from builds
  where
    -- skip the filter for the breakdown dimension so all its values appear as separate lines
    (p_dimension = 'workflow'  or p_workflow  is null or workflow_name = p_workflow)
    and (p_dimension = 'branch'    or p_branch    is null or branch       = p_branch)
    and (p_dimension = 'runner_os' or p_runner_os is null or runner_os    = p_runner_os)
    and (p_dimension = 'cpu_count' or p_cpu_count is null or cpu_count    = p_cpu_count)
    and completed_at >= coalesce(p_from::timestamptz, (current_date - (p_weeks * 7))::timestamptz)
    and completed_at <  coalesce((p_to  + 1)::timestamptz, now() + interval '1 second')
  group by 1, 2
  order by 1, 2
$$;

grant execute on function builds_stats     to service_role;
grant execute on function builds_trend     to service_role;
grant execute on function builds_breakdown to service_role;
```

3. Note the following from the Supabase dashboard:
   - `SUPABASE_PROJECT_ID` — the short project ID (e.g. `abcdefghijklmnop`)
     → Visible in the browser URL: `supabase.com/dashboard/project/<project-id>  (Settings → General → Project ID)`
     → Also in Settings → General
     → `SUPABASE_URL` is derived from this: `https://${SUPABASE_PROJECT_ID}.supabase.co`
       (never ask the operator to copy/paste the full URL — construct it in scripts and apps)
   - `SUPABASE_SECRET_KEY` = secret key (`sb_secret_...`) from Settings → API → Publishable and secret API keys (server-side only — webapp + Edge Function)
   - `SUPABASE_PUBLISHABLE_KEY` = publishable key (`sb_publishable_...`) from same page (used by runner scripts for INSERT)

### Acceptance criteria
- All three tables exist in Supabase table editor.
- RLS enabled with anon-INSERT policy on all three.
- `SUPABASE_PROJECT_ID`, `SUPABASE_SECRET_KEY`, and `SUPABASE_PUBLISHABLE_KEY` are known and ready.

---

## Stream A

### Task A1 — `scripts/send_metrics_to_supabase.sh`

**Goal:** Read a monitoring CSV and batch-POST all rows to the `metrics` table via Supabase REST.

**File to create:** `scripts/send_metrics_to_supabase.sh`

**Behaviour:**
- `set -euo pipefail`
- Usage: `send_metrics_to_supabase.sh <csv_path>`
- Guard: if CSV absent or empty (≤ 1 line), log warning and exit 0.
- Source `$DAEMON_ENV` (`/usr/local/bin/gha-monitoring/daemon.env`); check `SUPABASE_URL` and `SUPABASE_SECRET_KEY` are set.
- Read CSV line by line (skip header). Accumulate rows into a JSON array. Flush in batches of 500.
- Each JSON object keys: `run_id` (from `$GITHUB_RUN_ID`), `vm_name` (from `$RUNNER_NAME`),
  `sampled_at` (CSV `timestamp` reformatted as `YYYY-MM-DDTHH:MM:SS+00:00`), plus all 13 numeric columns.
- POST each batch to `${SUPABASE_URL}/rest/v1/metrics` with headers:
  `apikey`, `Authorization: Bearer`, `Content-Type: application/json`, `Prefer: return=minimal`.
- Log HTTP status and row count per batch. Log full response body on non-2xx.
- Always exits 0.

**Modelled on:** `scripts/send_metrics_to_newrelic.sh`

**Acceptance criteria:**
- Exits 0 against a sample CSV with real credentials; rows appear in Supabase.
- `run_id` and `vm_name` match env vars. `sampled_at` is valid timestamptz.
- Exits 0 with warning when no CSV provided.
- 600-row CSV results in two POST calls (500 + 100).

**Verification:**
```bash
export GITHUB_RUN_ID=test-run-001
export RUNNER_NAME=test-vm-001
bash scripts/send_metrics_to_supabase.sh monitoring-20251204_035335.csv
# Check Supabase table editor: filter run_id = 'test-run-001'
```

---

### Task A2 — `scripts/send_build_info_to_supabase.sh`

**Goal:** Insert one row into `builds` for the completed GHA job.

**File to create:** `scripts/send_build_info_to_supabase.sh`

**Behaviour:**
- `set -euo pipefail`; same guard as A1.
- Source `daemon.env`; check credentials.
- Detect `runner_os` via `uname`; `cpu_count` via `sysctl -n hw.logicalcpu` / `nproc`.
- Parse `commit_author` from `$GITHUB_EVENT_PATH` via `python3`; fall back to `$GITHUB_ACTOR`.
- `started_at` = first CSV timestamp as ISO8601+00:00.
- `completed_at` = `$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')`.
- `build_duration_seconds` = epoch(last ts) − epoch(first ts); 0 if < 2 data rows.
- POST single JSON object to `${SUPABASE_URL}/rest/v1/builds` with `Prefer: return=minimal` (plain INSERT — each run_id is unique).
- Log HTTP status. Always exits 0.

**Acceptance criteria:**
- Row appears in `builds` after running against real CSV.
- All columns non-null. `build_duration_seconds` is a positive integer.
- Re-run with same `GITHUB_RUN_ID` does not create a duplicate.

---

### Task A3 — `scripts/supabase_hook.sh`

**Goal:** Entry point for `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`. Calls A1 + A2.

**File to create:** `scripts/supabase_hook.sh`

**Behaviour:**
- Mirror structure of `scripts/newrelic_hook.sh` exactly.
- Find latest CSV: `ls -t /tmp/gha-monitoring/monitoring-*.csv 2>/dev/null | head -1`
- If no CSV: log warning, exit 0.
- Call `send_metrics_to_supabase.sh "$csv" || true` then `send_build_info_to_supabase.sh "$csv" || true`.
- Always exits 0.

**Acceptance criteria:**
- Exits 0 when no CSV exists.
- Exits 0 when both send scripts succeed or fail.
- Log created at `/tmp/gha-monitoring/supabase.log`.

---

### Task A4 — `scripts/warmup_runner.sh` (update)

**Goal:** Replace NR credentials and hook registration with Supabase equivalents.

**File to modify:** `scripts/warmup_runner.sh`

**Changes:**
- Replace NR credential placeholders with `SUPABASE_PROJECT_ID`, `SUPABASE_SECRET_KEY`, `SUPABASE_PUBLISHABLE_KEY`.
- Change `git clone --branch new-relic` → `--branch supabase`.
- `daemon.env` heredoc derives and writes `SUPABASE_URL` from `SUPABASE_PROJECT_ID`:
  ```bash
  SUPABASE_PROJECT_ID="SUPABASE_PROJECT_ID_PLACEHOLDER"
  SUPABASE_SECRET_KEY="SUPABASE_SECRET_KEY_PLACEHOLDER"
  SUPABASE_PUBLISHABLE_KEY="SUPABASE_PUBLISHABLE_KEY_PLACEHOLDER"
  # derived — not a placeholder:
  SUPABASE_URL="https://${SUPABASE_PROJECT_ID}.supabase.co"
  ```
- Replace NR script `cp`/`chmod` lines with Supabase equivalents.
- `HOOK_SCRIPT` points to `supabase_hook.sh`.

**Acceptance criteria:**
- `daemon.env` contains `SUPABASE_URL` (constructed), `SUPABASE_SECRET_KEY`, `SUPABASE_PUBLISHABLE_KEY` — no NR keys.
- `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` points to `supabase_hook.sh`.
- `chmod 600` on `daemon.env`.

---

### Checkpoint A — Stream A Smoke Test

```bash
export GITHUB_RUN_ID=smoke-test-$(date +%s)
export RUNNER_NAME=local-test-vm
export GITHUB_WORKFLOW="Smoke Test"
export GITHUB_REPOSITORY=naveen-bitrise/test
export GITHUB_REF_NAME=main

# Write daemon.env locally (do not commit)
echo "export SUPABASE_PROJECT_ID=<project-id>" > /tmp/test_daemon.env
echo "export SUPABASE_URL=https://<project-id>.supabase.co" >> /tmp/test_daemon.env
echo "export SUPABASE_PUBLISHABLE_KEY=sb_publishable_..." >> /tmp/test_daemon.env

DAEMON_ENV=/tmp/test_daemon.env \
  bash scripts/send_metrics_to_supabase.sh monitoring-20251204_035335.csv

DAEMON_ENV=/tmp/test_daemon.env \
  bash scripts/send_build_info_to_supabase.sh monitoring-20251204_035335.csv
```

**Pass criteria:** Both scripts log `HTTP 201`. Rows visible in Supabase. No duplicate `builds` row on re-run.

---

## Stream D

Stream D is **independent of Streams A/B/C** — it can start immediately after Pre-work.
It populates `job_conclusions` (failure rate + queue time) via GitHub webhook.

### Task D1 — Supabase Edge Function `gha-webhook`

**Goal:** Receive GitHub `workflow_job` webhook, validate signature, write to `job_conclusions`.

**File to create:** `supabase/functions/gha-webhook/index.ts`

**Behaviour:**
- Deno/TypeScript ES module, `export default { async fetch(req, env) }`.
- Reject non-POST requests with 405.
- Read raw body as text; validate `X-Hub-Signature-256` header using `HMAC-SHA256(GITHUB_WEBHOOK_SECRET, body)`. Return 401 on mismatch.
- Parse JSON; if `action !== 'completed'` return 200 immediately (no-op).
- Filter: if `workflow_job.runner_name` does not start with `env.RUNNER_NAME_PREFIX` return 200 (skip non-Bitrise jobs).
- Parse `workflow_job.labels`:
  - `machine_os`: first of `macOS`, `Linux`, `Windows` found in labels.
  - `machine_arch`: first of `arm64`, `x64`, `ARM64`, `X64`.
  - `cpu_count`: first label matching `/^(\d+)core$/i` → extract number.
  - `runner_type`: `self-hosted` if label present, else `github-hosted`.
- Compute:
  - `wait_time_seconds` = `Date.parse(started_at) - Date.parse(created_at)` / 1000 (integer).
  - `build_duration_seconds` = `Date.parse(completed_at) - Date.parse(started_at)` / 1000.
- Build insert object from `workflow_job`, `repository.full_name`, `sender.login`, computed fields.
- `POST` to `${SUPABASE_URL}/rest/v1/job_conclusions` with service_role key + `Prefer: resolution=merge-duplicates` (upsert on `job_id`).
- Log non-2xx response bodies to `console.error`.
- Always return `200` — even on insert failure (prevents GitHub retrying).

**Environment variables (set via `supabase secrets set`):**
- `GITHUB_WEBHOOK_SECRET`
- `RUNNER_NAME_PREFIX` (e.g. `vm-pool`)
- `SUPABASE_URL` and `SUPABASE_SECRET_KEY` are available automatically within Edge Functions via `Deno.env`.

**Acceptance criteria:**
- Valid payload with matching signature → row inserted in `job_conclusions`.
- Invalid signature → returns 401, no insert.
- `action = 'queued'` payload → returns 200, no insert.
- Runner name not matching prefix → returns 200, no insert.
- Duplicate `job_id` (webhook retry) → upserts cleanly, no duplicate row.

---

### Task D2 — Deploy Edge Function + configure secrets

**Goal:** Live function reachable at Supabase URL.

**Steps (manual — documented for operator):**
```bash
# Install Supabase CLI if not present
brew install supabase/tap/supabase

# Link to project
supabase link --project-id <project-id>

# Deploy
supabase functions deploy gha-webhook

# Set secrets
supabase secrets set GITHUB_WEBHOOK_SECRET=<value>
supabase secrets set RUNNER_NAME_PREFIX=vm-pool
```

Function URL after deploy:
`https://<project-id>.supabase.co/functions/v1/gha-webhook`

**Acceptance criteria:**
- `curl -X POST https://<project-id>.supabase.co/functions/v1/gha-webhook` returns 401 (no signature).
- Function shows as active in Supabase dashboard → Edge Functions.

---

### Task D3 — Configure GitHub org-level webhook

**Goal:** GitHub pushes `workflow_job` events to the Edge Function on every job completion.

**Steps (manual — one-time org setup, requires org owner access):**
1. GitHub → Your Org → Settings → Webhooks → Add webhook
2. Payload URL: `https://<project-id>.supabase.co/functions/v1/gha-webhook`
3. Content type: `application/json`
4. Secret: same value as `GITHUB_WEBHOOK_SECRET`
5. Events: select **Let me select individual events** → tick **Workflow jobs** only
6. Active: checked → Save

**Acceptance criteria:**
- Webhook appears in org Settings → Webhooks with a green tick (ping delivered successfully).
- Ping event visible in Supabase Edge Function logs (returns 200, action is not `completed` so no insert).

---

### Checkpoint D — Edge Function End-to-End

Send a synthetic `workflow_job completed` payload:

```bash
BODY=$(cat <<'EOF'
{
  "action": "completed",
  "workflow_job": {
    "id": 999999999,
    "run_id": 12345678,
    "run_attempt": 1,
    "name": "build",
    "workflow_name": "CI",
    "conclusion": "success",
    "head_branch": "main",
    "head_sha": "abc123",
    "runner_name": "vm-pool-test-runner",
    "runner_group_name": "Bitrise Mac Pool",
    "labels": ["self-hosted", "macOS", "arm64", "14core"],
    "created_at": "2026-04-06T10:00:00Z",
    "started_at": "2026-04-06T10:01:30Z",
    "completed_at": "2026-04-06T10:07:12Z"
  },
  "repository": { "full_name": "org/repo" },
  "sender": { "login": "naveen" }
}
EOF
)
SIG="sha256=$(echo -n "$BODY" | openssl dgst -sha256 -hmac "$GITHUB_WEBHOOK_SECRET" | awk '{print $2}')"
curl -X POST https://<project-id>.supabase.co/functions/v1/gha-webhook \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: $SIG" \
  -d "$BODY"
```

**Pass criteria:**
- Response: `200`.
- Row visible in `job_conclusions` table editor: `conclusion = success`, `wait_time_seconds = 90`, `build_duration_seconds = 342`, `machine_os = macOS`, `cpu_count = 14`.
- Re-running the same payload does not create a duplicate.

---

## Stream E — Linux Runner Support

Stream E is **independent of all other streams** — it can proceed any time after Checkpoint A.
The macOS scripts continue to work unchanged; Linux support is additive via `uname` detection.

### Task E1 — `scripts/collect_metrics.sh` — Linux code paths

**Goal:** Same CSV output on Linux runners without requiring macOS tools.

**File to modify:** `scripts/collect_metrics.sh`

**macOS-specific tools to replace on Linux:**

| macOS | Linux equivalent |
|---|---|
| `iostat -c 2 -w 1` (CPU) | `/proc/stat` — read twice with 1s sleep, compute delta percentages |
| `vm_stat` + `pagesize` (memory) | `/proc/meminfo` — `MemUsed = MemTotal − MemFree − Buffers − Cached`, `MemCached = Cached + SReclaimable` |
| `sysctl -n vm.loadavg` (load) | `/proc/loadavg` — fields 1–3 |
| `sysctl vm.swapusage` (swap) | `/proc/meminfo` — `SwapTotal`, `SwapFree` |

**Approach:** wrap each metric block in `if [[ "$(uname)" == "Darwin" ]]; then ... else ... fi`.
CSV header and output row format remain identical.

**Acceptance criteria:**
- Script produces the same 13-column CSV on Linux as on macOS.
- On macOS, existing behaviour is unchanged.
- CPU percentages sum to ≈100%; memory values are in MB; swap values are in MB.

---

### Task E2 — `scripts/send_build_info_to_supabase.sh` — Linux cpu_count

**Goal:** Correct `cpu_count` on Linux runners.

**File to modify:** `scripts/send_build_info_to_supabase.sh`

**Change:** replace the bare `sysctl -n hw.logicalcpu` call (line ~61) with:
```bash
if [[ "$(uname)" == "Darwin" ]]; then
  cpu_count=$(sysctl -n hw.logicalcpu 2>/dev/null) || cpu_count=0
else
  cpu_count=$(nproc 2>/dev/null) || cpu_count=0
fi
```

**Acceptance criteria:**
- On Linux, `cpu_count` in the `builds` row matches `nproc` output.
- On macOS, unchanged.

---

### Task E3 — `scripts/install_on_runner.sh` — Linux startup

**Goal:** Daemon starts automatically on Linux without launchd.

**File to modify:** `scripts/install_on_runner.sh`

**Change:** the launchd block (`if [ "$EUID" -eq 0 ]`) is macOS-only. Add an OS check:
- On macOS: existing launchd path unchanged.
- On Linux as root: write `/etc/systemd/system/gha-monitor.service` and run `systemctl enable --now gha-monitor`. If systemd is unavailable, fall back to adding a `nohup ... &` line to `/etc/rc.local`.
- On Linux non-root: same hint as macOS non-root case.

**Acceptance criteria:**
- On Linux with systemd: `systemctl status gha-monitor` shows active after install.
- On macOS: existing launchd behaviour unchanged.

---

### Task E4 — `scripts/warmup_runner.sh` — configurable runner home path

**Goal:** Runner `.env` path works on Linux where the runner user is typically `runner`, not `vagrant`.

**File to modify:** `scripts/warmup_runner.sh`

**Change:** replace the hardcoded `/Users/vagrant/actions-runner/.env` with:
```bash
if [[ "$(uname)" == "Darwin" ]]; then
  RUNNER_ENV_FILE="${RUNNER_HOME:-/Users/vagrant}/actions-runner/.env"
else
  RUNNER_ENV_FILE="${RUNNER_HOME:-/home/runner}/actions-runner/.env"
fi
```

**Acceptance criteria:**
- On Linux with default path: `.env` written to `/home/runner/actions-runner/.env`.
- `RUNNER_HOME` env var overrides the default on both platforms.
- On macOS: unchanged default of `/Users/vagrant`.

---

### Checkpoint E — Linux Runner Smoke Test

1. Trigger a GHA job on a Linux self-hosted runner with the updated scripts.
2. Verify CSV is written to `/tmp/gha-monitoring/monitoring-*.csv` with correct Linux metric values.
3. Verify rows appear in Supabase `metrics` table with `run_id` and `vm_name` set.
4. Verify row appears in Supabase `builds` table with `runner_os = Linux` and correct `cpu_count`.
5. On macOS runner: re-run existing smoke test to confirm no regression.

---

## Stream B

### Task B1 — Restore webapp skeleton

**Goal:** Re-create the deleted Sinatra app with Supabase wiring, no CSV logic.

**Files to create:**
- `webapp/app.rb` — from `fa0e15a`, strip: `parse_monitoring_file`, `job_start_from_filename`, `DATA_DIR`, `/api/files`, `/api/data/*`. Add: `SUPABASE_PROJECT_ID`/`SUPABASE_SECRET_KEY` from ENV; derive `SUPABASE_URL = "https://#{ENV['SUPABASE_PROJECT_ID']}.supabase.co"`; `require 'net/http'`, `require 'uri'`.
- `webapp/views/index.erb` — layout shell only (head, CSS, empty container).
- `webapp/Gemfile` — verbatim from `fa0e15a`.
- `webapp/config.ru` — verbatim from `fa0e15a`.

**Acceptance criteria:**
- `bundle exec ruby webapp/app.rb` starts without error.
- `GET /` returns 200. No CSV references remain.

---

### Task B2 — Supabase client helper + VM Metrics API endpoints

**Goal:** Server-side Supabase REST calls for the three `/api/vm_*` endpoints.

**File to modify:** `webapp/app.rb`

**`supabase_get(path, params = {})` helper:**
- Builds URI, sets query params, makes `Net::HTTP` GET with service_role headers.
- Returns parsed JSON.

**`GET /api/vm_filters`**
- Distinct values of `workflow_name`, `branch`, `repository`, `runner_os`, `cpu_count` from `builds`.
- Returns `{ workflows, branches, repositories, runner_os_values, cpu_counts }`.

**`GET /api/vm_runs`**
- Params: `started_from`, `started_to`, `workflow_name`, `branch`, `repository`, `runner_os`, `cpu_count` (all optional).
- PostgREST filters for each non-blank param. `order=started_at.desc&limit=10`.
- Include `Prefer: count=exact` header. PostgREST returns total match count in `Content-Range: 0-9/{total}` response header.
- Returns `{ total: N, runs: [{ run_id, vm_name, workflow_name, branch, started_at, build_duration_seconds }] }`.

**`GET /api/metrics/:run_id`**
- Queries `metrics` (all rows ordered `sampled_at asc`) and `builds` (for `started_at`, `build_duration_seconds`).
- Returns Chart.js-ready JSON: `{ timestamps, cpu, memory, load, swap, job_start, duration_seconds }`.
- MB → GB conversion for memory and swap. `memory.total` = max(used+free+cached).

**Acceptance criteria:**
- `/api/vm_filters` returns valid JSON with populated arrays.
- `/api/vm_runs` returns `{ total, runs }` where `runs` has ≤ 10 rows and `total` reflects full match count.
- `/api/vm_runs` with filters returns a `total` smaller than unfiltered total.
- `/api/metrics/:run_id` returns equal-length arrays for all series.
- `service_role` key never in any response body.

---

### Task B3 — `webapp/views/index.erb` — VM Metrics page

**Goal:** 6-filter bar + VM run selector + 4 charts.

**File to modify:** `webapp/views/index.erb`

**Layout:**
- Filter bar: `started_from`/`started_to` date inputs; `workflow_name`, `branch`, `repository`, `runner_os`, `cpu_count` dropdowns.
- VM run selector: options as `vm_name — run_id — workflow_name — started_at` (max 10). Below the selector: `Showing 10 of {total}` (hidden when total ≤ 10).
- Job info bar: start time + duration.
- 4 chart canvases (CPU, Memory, Load, Swap — unchanged from `fa0e15a`).

**JS:**
- `loadFilters()` → populates dropdowns from `/api/vm_filters`.
- `loadVmRuns()` → calls `/api/vm_runs` with current filter values → populates selector; updates `Showing N of {total}` hint (hidden when total ≤ 10). Called on any filter change.
- `loadMetrics()` → calls `/api/metrics/:run_id` → calls `renderCharts(data)`.
- `renderCharts(data)` → identical Chart.js logic and colour scheme from `fa0e15a`.

**Acceptance criteria:**
- All 6 filter dropdowns populate on load.
- Filter change repopulates VM run selector.
- Selecting a run renders all 4 charts. Job info bar shows start + duration.

---

### Checkpoint B — VM Metrics Page End-to-End

1. `cd webapp && bundle exec ruby app.rb`
2. Open `http://localhost:4567`.
3. 6 dropdowns populated. Filter change narrows selector. Selecting run renders 4 charts.
4. Network tab: no `service_role` key visible.

---

## Stream C

### Task C1 — `/api/builds/*` API endpoints

**Goal:** Four Builds Dashboard endpoints + `/builds` route.

**File to modify:** `webapp/app.rb`

**Approach:** All aggregation (percentiles, weekly bucketing, grouping) is done server-side in
PostgreSQL via Supabase `/rpc` calls. PostgREST is used only for the filters endpoint (distinct
values). Ruby does no aggregation — it just serialises the RPC response to the frontend.

**Add `supabase_rpc(fn, params = {})` helper alongside `supabase_get`:**
- POSTs to `${SUPABASE_URL}/rest/v1/rpc/{fn}` with `Content-Type: application/json`.
- Body: `params.to_json` (keys are the PostgreSQL function parameter names).
- Same service_role headers as `supabase_get`.
- Returns parsed JSON. Raises on non-2xx.

**Shared param extraction `builds_rpc_params(request.params)`:**
- Extracts: `p_weeks` (integer, default 12), `p_workflow`, `p_branch`, `p_runner_os`,
  `p_cpu_count` (integer or nil), `p_from` (date string or nil), `p_to` (date string or nil).
- Omits nil values from the hash so PostgreSQL defaults apply.

**`GET /api/builds/filters`**
- PostgREST: `supabase_get('/rest/v1/builds', { select: 'workflow_name,branch,runner_os,cpu_count' })`.
- Deduplicate in Ruby. Returns `{ workflows, branches, runner_os_values, cpu_counts }`.

**`GET /api/builds/stats`**
- Calls `supabase_rpc('builds_stats', ...)` → returns `{ p90_seconds, p50_seconds, count, total_duration_seconds }`.
- Also calls `supabase_rpc('job_stats', ...)` → returns `{ failure_rate, queue_time_p90, queue_time_p50 }`.
- Merges both results. `job_stats` call wrapped in `rescue StandardError → {}` so the endpoint works before Stream D is live.
- Returns merged: `{ p90_seconds, p50_seconds, count, total_duration_seconds, failure_rate, queue_time_p90, queue_time_p50 }`.

**`JOB_METRICS = %w[failure_rate queue_time_p90 queue_time_p50]`** constant — used by trend + breakdown to route to the right RPC.

**`GET /api/builds/trend`**
- If `metric` in `JOB_METRICS` → `supabase_rpc('job_trend', ...)`.
- Otherwise → `supabase_rpc('builds_trend', ...)`.
- Returns `[{ week, value }, ...]` directly.

**`GET /api/builds/breakdown`**
- If `metric` in `JOB_METRICS` → `supabase_rpc('job_breakdown', ...)`.
- Otherwise → `supabase_rpc('builds_breakdown', ...)`.
- RPC returns `[{ week, dim, value }, ...]`. Ruby reshapes to `{ "dim_value" => [{ week, value }, ...] }`.

**`get '/builds'`** → `erb :builds`.

**Acceptance criteria:**
- `/api/builds/stats` returns all 7 keys; `failure_rate`/`queue_time_*` are `null` before Stream D (graceful).
- `/api/builds/trend?metric=p90&weeks=12` returns weekly `{ week, value }` buckets ordered ascending.
- `/api/builds/trend?metric=failure_rate` calls `job_trend` RPC.
- `/api/builds/breakdown?metric=queue_time_p90&dimension=workflow` calls `job_breakdown` RPC.
- `from`/`to` params passed through to RPC; override `weeks` in the SQL function.
- `service_role` key never in any response body.

---

### Task C2 — `webapp/views/builds.erb` — Builds Dashboard page

**Goal:** Full Builds Dashboard UI per spec section 5.3.

**File to create:** `webapp/views/builds.erb`

**HTML structure:**
- Time range selector (top right): Last week / Last 4 weeks / Last 12 weeks (default) / Last 6 months / Custom. Custom reveals `from`/`to` date inputs.
- Top filter bar: Workflow, Branch, Machine Type (always shown). vCPU Count (shown only when Machine Type is set).
- Metric tab cards (7): p90 · p50 · Build count · Total duration · Failure rate · Queue time (p90) · Queue time (p50). Each shows current aggregate value. Click to switch active metric. Failure rate formatted as `X%`; queue times formatted as `Xm Ys`; tabs sourced from `job_conclusions` show `—` until Stream D is live.
- Main trend chart: single line, weekly buckets, y-axis formatted per metric type (seconds as `Xm Ys`, count as integer).
- Breakdown section:
  - Dimension tabs visibility rules:
    - Workflow: shown if workflow filter NOT set
    - Branch: shown if branch filter NOT set
    - Machine Type: shown if runner_os filter NOT set
    - vCPU Count: shown only if runner_os IS set (and cpu_count not set)
  - Multi-line breakdown chart (one line per distinct dimension value, null fill for missing weeks).

**JS functions:**
- `loadFilters()` → populate dropdowns + call `renderBreakdownTabs()`.
- `getTimeParams()` → `{ weeks }` or `{ from, to }`.
- `getFilterParams()` → non-blank values from all 4 dropdowns.
- `loadStats()` → update 7 card spans. Format: p90/p50 as `Xm Ys`; total as `Xh Ym Zs`; failure_rate as `X%`; queue_time_p90/p50 as `Xm Ys`.
- `loadTrend()` → fetch `/api/builds/trend`, render/update `trendChart`.
- `loadBreakdown()` → fetch `/api/builds/breakdown`, render/update `breakdownChart`.
- `renderBreakdownTabs()` → evaluate rules, rebuild tab strip, select first visible tab.
- `refresh()` = `Promise.all([loadStats(), loadTrend(), loadBreakdown()])`.
- Metric tab click → set `activeMetric` → `loadTrend() + loadBreakdown()`.
- Breakdown tab click → set `activeBreakdown` → `loadBreakdown()`.
- Machine Type change → toggle vCPU dropdown + `renderBreakdownTabs()` + `refresh()`.
- All other filter/time range changes → `refresh()`.
- On load: `loadFilters()` then `refresh()`.

**Acceptance criteria:**
- `/builds` returns 200. 4 `builds`-sourced metric cards show non-zero values; 3 `job_conclusions`-sourced cards show `—` until Stream D is live.
- Trend + breakdown charts render on load.
- Metric tab switch updates both charts.
- Clicking Failure rate or Queue time cards → trend and breakdown use `job_trend`/`job_breakdown` RPCs; y-axis shows `%` for failure_rate, duration format for queue times.
- Workflow filter hides Workflow breakdown tab.
- Machine Type filter reveals vCPU dropdown and vCPU Count breakdown tab.
- Custom time range reveals date inputs; entering dates re-fetches.
- No `service_role` key in page source.

---

### Checkpoint C — Builds Dashboard End-to-End

1. Open `http://localhost:4567/builds`.
2. Default (Last 12 weeks, p90): all 4 `builds` cards populated, trend chart renders, Workflow breakdown tab active with multi-line chart.
3. Click "Build count" → both charts switch to count.
4. Click "Failure rate" → trend/breakdown charts switch; y-axis shows `%`.
5. Click "Queue time (p90)" → trend/breakdown charts switch; y-axis shows duration.
6. Set Workflow filter → Workflow tab disappears, next tab auto-selected.
7. Set Machine Type → vCPU dropdown appears + vCPU breakdown tab appears.
8. Custom range → date inputs appear, values update on date change.
9. Network tab: no `service_role` key.

---

## Final wiring

### Task F1 — Navigation between pages

**Files to modify:** `webapp/views/index.erb`, `webapp/views/builds.erb`

Add at top of `<body>` in both files:
```html
<nav class="main-nav">
  <a href="/" class="<%= request.path == '/' ? 'active' : '' %>">VM Metrics</a>
  <a href="/builds" class="<%= request.path == '/builds' ? 'active' : '' %>">Builds</a>
</nav>
```

**Acceptance criteria:**
- Both pages have working nav links.
- Current page link is visually highlighted.

---

### Task F2 — Update `README.md`

**File to modify:** `README.md`

**Sections to replace/add:**
- Remove: NR credentials setup, NR script install instructions, GitHub PAT block.
- Add: Supabase project setup (link to schema SQL, where to get URL + service_role key).
- Add: Edge Function deploy steps (`supabase functions deploy`, secrets).
- Add: GitHub org webhook setup (URL, secret, event selection).
- Add: `warmup_runner.sh` usage with Supabase placeholders.
- Add: Webapp — env vars required (`SUPABASE_PROJECT_ID`, `SUPABASE_SECRET_KEY`); note that `SUPABASE_URL` is derived from `SUPABASE_PROJECT_ID` automatically; how to run locally; hosting options summary.

**Acceptance criteria:**
- README has no references to New Relic credentials or NR API endpoints.
- A new operator can follow the README end-to-end to set up the full system.
