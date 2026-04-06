# SPEC: GHA Scheduled Workflow — New Relic Build Health

**Status:** Draft
**Date:** 2026-04-05

---

## 1. Objective

A scheduled GHA workflow that customers add to their repo. It runs hourly, queries the GitHub Actions API for completed jobs in the past hour, and posts a `GHABuildConclusion` event to New Relic for each job.

This provides the data that cannot come from the VM hook:
- Job conclusion (success / failure / cancelled)
- Wait time (time from workflow queued to job start)
- Accurate job-level duration from GitHub timestamps
- Branch, trigger event, actor
- Machine type and CPU count (from runner labels — best effort)

**Target users:** Bitrise customers who run GHA jobs on Bitrise-hosted runners and want build health dashboards in New Relic.

**Relationship to VM Hook data:**
- `GHABuildConclusion` (this spec) + `GHABuildInfo` (SPEC-VM-HOOK.md) are **independent datasets**
- VM metrics charts use hook data (accurate machine type from `uname`)
- Build health charts use this data (machine type from labels — may not be accurate)
- No join between the two datasets — each serves different dashboard widgets

---

## 2. Architecture

```
Customer repo
└── .github/workflows/nr-build-health.yml   ← scheduled workflow (this spec)
      │  runs every hour on ubuntu-latest (cheap, doesn't need Bitrise runner)
      │
      ├── queries GitHub API: /repos/{owner}/{repo}/actions/runs?status=completed&created=>1h_ago
      ├── for each run → queries /repos/{owner}/{repo}/actions/runs/{run_id}/jobs
      ├── for each job → builds GHABuildConclusion event JSON
      └── POSTs events to New Relic Events API
```

The workflow runs on `ubuntu-latest` (standard GitHub-hosted runner) — it does not need a Bitrise runner.

---

## 3. Data Model

### `GHABuildConclusion` Event (NR Events API)

One event per **job** (not per workflow run). A workflow run with 3 jobs produces 3 events.

#### From GitHub Runs API (`/actions/runs`)

| Attribute | API field | Example |
|---|---|---|
| `run_id` | `id` | `12345678` |
| `run_number` | `run_number` | `42` |
| `run_attempt` | `run_attempt` | `1` |
| `workflow_name` | `name` | `CI` |
| `branch` | `head_branch` | `main` |
| `sha` | `head_sha` | `abc123...` |
| `event_name` | `event` | `push` / `pull_request` / `schedule` |
| `actor` | `actor.login` | `naveen` |
| `triggering_actor` | `triggering_actor.login` | `naveen` |
| `commit_author` | `head_commit.author.login` (GitHub username); falls back to `head_commit.author.name` (git name) if login absent | `naveen` |
| `repository` | `repository.full_name` | `org/repo` |
| `run_created_at` | `created_at` (ISO 8601) | `2026-04-05T10:00:00Z` |

#### From GitHub Jobs API (`/actions/runs/{run_id}/jobs`)

| Attribute | API field | Example |
|---|---|---|
| `job_id` | `id` | `987654321` |
| `job_name` | `name` | `build` / `build (ubuntu, 18)` |
| `conclusion` | `conclusion` | `success` / `failure` / `cancelled` / `skipped` / `timed_out` |
| `job_started_at` | `started_at` (ISO 8601) | `2026-04-05T10:01:30Z` |
| `job_completed_at` | `completed_at` (ISO 8601) | `2026-04-05T10:07:12Z` |
| `runner_name` | `runner_name` | `vm-pool-g2-mac-m4pro-14c-...` |
| `runner_group_name` | `runner_group_name` | `Bitrise Mac Pool` |

#### Computed Fields

| Attribute | Computation | Example |
|---|---|---|
| `wait_time_seconds` | `job_started_at - run_created_at` (seconds) | `90` |
| `build_duration_seconds` | `job_completed_at - job_started_at` (seconds) | `342` |
| `timestamp` | Unix epoch ms of `job_completed_at` | `1712345678000` |
| `eventType` | hardcoded | `GHABuildConclusion` |

#### From Runner Labels (best effort — parsed from `labels` array)

Labels example: `["self-hosted", "macOS", "arm64", "14core"]`

| Attribute | Parsing logic | Example |
|---|---|---|
| `machine_os` | first of: `macOS`, `Linux`, `Windows` found in labels | `macOS` |
| `machine_arch` | first of: `arm64`, `x64`, `ARM64`, `X64` found in labels | `arm64` |
| `cpu_count` | first label matching `\d+core` → extract number | `14` |
| `runner_type` | `self-hosted` present → `self-hosted`, else `github-hosted` | `self-hosted` |

If a label value is not found, the field is omitted (not set to null/unknown — omitting keeps NR events clean).

---

## 4. Deployment Options

Two options depending on whether the customer wants single-repo or org-wide coverage.

---

### Option A: Per-Repo (default, simplest)

The workflow lives in each repo the customer wants to monitor. Uses the auto-provided `GITHUB_TOKEN` — no extra credentials needed beyond the NR keys.

**Scope:** single repo only.
**Setup:** copy `.github/workflows/nr-build-health.yml` into each repo + add NR secrets.

**File:** `.github/workflows/nr-build-health.yml`

```yaml
name: Post Build Health to New Relic
on:
  schedule:
    - cron: '0 * * * *'
  workflow_dispatch:
    inputs:
      lookback_hours:
        description: 'Hours of history to fetch (default: 1)'
        default: '1'

permissions:
  actions: read

jobs:
  post-to-newrelic:
    runs-on: ubuntu-latest
    steps:
      - name: Fetch completed jobs and post to New Relic
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NR_LICENSE_KEY: ${{ secrets.NEW_RELIC_LICENSE_KEY }}
          NR_ACCOUNT_ID: ${{ secrets.NEW_RELIC_ACCOUNT_ID }}
          LOOKBACK_HOURS: ${{ inputs.lookback_hours || '1' }}
          REPOS: ${{ github.repository }}
        run: |
          # inline shell script — see Section 5
```

**Required secrets:**

| Secret | Description |
|---|---|
| `NEW_RELIC_LICENSE_KEY` | NR Ingest - License key |
| `NEW_RELIC_ACCOUNT_ID` | NR numeric account ID |
| `GITHUB_TOKEN` | Auto-provided — no setup needed |

---

### Option B: Org-Wide via GitHub App (no per-repo setup)

One workflow in a central monitoring repo covers all repos in the org. Uses a GitHub App for the org-scoped token. New repos are covered automatically without any additional workflow setup.

**Scope:** all repos in the org.
**Setup:** one-time app registration + install on org + add secrets to the central monitoring repo.

#### GitHub App Setup (one-time, no code required)

1. Go to GitHub → Settings → Developer Settings → GitHub Apps → **New GitHub App**
2. Set:
   - **Permissions:** `Actions: Read-only`, `Metadata: Read-only` — nothing else
   - **Webhook:** disabled
3. Install the app on the org (Settings → Install App → select org → All repositories)
4. Download the private key (`.pem` file)
5. Add to the central monitoring repo secrets:
   - `APP_ID` — shown on the app's settings page
   - `APP_PRIVATE_KEY` — contents of the downloaded `.pem` file

#### Workflow File (lives in central monitoring repo only)

```yaml
name: Post Build Health to New Relic (Org-Wide)
on:
  schedule:
    - cron: '0 * * * *'
  workflow_dispatch:
    inputs:
      lookback_hours:
        description: 'Hours of history to fetch (default: 1)'
        default: '1'

jobs:
  post-to-newrelic:
    runs-on: ubuntu-latest
    steps:
      - name: Generate org-scoped token from GitHub App
        uses: actions/create-github-app-token@v1
        id: app-token
        with:
          app-id: ${{ secrets.APP_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}   # scopes token to whole org

      - name: Fetch completed jobs and post to New Relic
        env:
          GH_TOKEN: ${{ steps.app-token.outputs.token }}
          NR_LICENSE_KEY: ${{ secrets.NEW_RELIC_LICENSE_KEY }}
          NR_ACCOUNT_ID: ${{ secrets.NEW_RELIC_ACCOUNT_ID }}
          LOOKBACK_HOURS: ${{ inputs.lookback_hours || '1' }}
          ORG: ${{ github.repository_owner }}
        run: |
          # inline shell script — see Section 5
          # script loops over all org repos via GET /orgs/{ORG}/repos
          # then queries runs per repo
```

**Required secrets (central monitoring repo only):**

| Secret | Description |
|---|---|
| `NEW_RELIC_LICENSE_KEY` | NR Ingest - License key |
| `NEW_RELIC_ACCOUNT_ID` | NR numeric account ID |
| `APP_ID` | GitHub App ID (from app settings page) |
| `APP_PRIVATE_KEY` | GitHub App private key (`.pem` contents) |

---

### Comparison

| | Option A (per-repo) | Option B (GitHub App) |
|---|---|---|
| Setup effort | Copy workflow to each repo | One-time app registration |
| New repos covered automatically | ❌ | ✅ |
| Credentials needed | NR keys only | NR keys + App ID + private key |
| GitHub App required | ❌ | ✅ (registration only, no code) |
| Recommended for | 1–3 repos | 4+ repos / whole org |

---

## 5. Script Logic

The workflow step runs a shell script inline. The core logic is identical for both options — the only difference is how the repo list is built.

```
Option A: REPOS = ["owner/repo"]                   (single repo from REPOS env var)
Option B: REPOS = GET /orgs/{ORG}/repos            (all org repos, paginated)

For each repo in REPOS:
  1. Compute lookback window: since = now - LOOKBACK_HOURS * 3600 (ISO 8601)
  2. Fetch runs: GET /repos/{repo}/actions/runs?status=completed&created=>{since}&per_page=100
  3. Paginate until no more results
  4. For each run:
     a. Fetch jobs: GET /repos/{repo}/actions/runs/{run_id}/jobs?per_page=100
     b. For each completed job:
        - Parse label fields (machine_os, cpu_count, machine_arch, runner_type)
        - Compute wait_time_seconds, build_duration_seconds
        - Build GHABuildConclusion JSON event
  5. Accumulate all events

POST accumulated events to NR Events API (max 2000 per request, batch if needed)
Log response; exit 0 always
```

### Pagination
- GitHub API: max 100 per page; use `?page=N` until empty results
- NR Events API: max 2000 events per POST; batch if needed

### API calls
- GitHub: `curl -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json"`
- New Relic: `curl --max-time 30 --silent -X POST -H "Api-Key: $NR_LICENSE_KEY" -H "Content-Type: application/json"`

### Deduplication
Runs are queried by `created` time within the lookback window. If the workflow fires slightly late, runs near the boundary could be double-posted. NR Events API does not deduplicate — acceptable for now. `job_id` is included in the event so duplicates can be filtered in NRQL with `SELECT uniques(job_id)`.

---

## 6. NR Dashboard Widgets (GHA build health data)

### Dashboard Filters (apply to all widgets)

New Relic template variables added to the dashboard. Each renders as a dropdown filter:

| Variable | Filters on | NR attribute |
|---|---|---|
| Time picker | All widgets | Built-in NR time picker |
| Repository | All widgets | `repository` |
| Machine type | All widgets | `machine_os` |
| vCPU count | All widgets | `cpu_count` |
| Workflow name | All widgets | `workflow_name` |
| Branch | All widgets | `branch` |
| Commit author | All widgets | `commit_author` |

> **Multi-repo:** Each `GHABuildConclusion` event includes `repository` (from `repository.full_name` in the GitHub API). If a customer has multiple repos and wants to filter across all of them in one dashboard, they must add the scheduled workflow to each repo separately. All repos post to the same NR account — the `repository` filter then lets them drill down per repo.

All NRQL queries include `WHERE {{machine_type_var}} AND {{cpu_count_var}} AND {{workflow_var}} AND {{branch_var}}` via template variable injection (NR handles this automatically when variables are configured).

### Widgets

All queries: `FROM GHABuildConclusion`

| Widget | Type | NRQL sketch |
|---|---|---|
| Build count | Billboard | `SELECT count(*)` |
| Failure rate | Billboard | `SELECT percentage(count(*), WHERE conclusion = 'failure')` |
| p50 / p90 build time | Billboard | `SELECT percentile(build_duration_seconds, 50, 90)` |
| p50 / p90 wait time | Billboard | `SELECT percentile(wait_time_seconds, 50, 90)` |
| Build duration over time | Line | `SELECT percentile(build_duration_seconds, 50, 90) TIMESERIES 1 hour` |
| Wait time over time | Line | `SELECT percentile(wait_time_seconds, 50, 90) TIMESERIES 1 hour` |
| Failure rate over time | Line | `SELECT percentage(count(*), WHERE conclusion = 'failure') TIMESERIES 1 hour` |
| Build count by workflow | Bar | `SELECT count(*) FACET workflow_name` |
| Failure rate by workflow | Bar | `SELECT percentage(count(*), WHERE conclusion = 'failure') FACET workflow_name` |
| Build duration by machine type | Bar | `SELECT average(build_duration_seconds) FACET machine_os` |
| Build duration by vCPU count | Bar | `SELECT average(build_duration_seconds) FACET cpu_count` |
| Build duration by branch | Bar | `SELECT average(build_duration_seconds) FACET branch` |
| Failure rate by branch | Bar | `SELECT percentage(count(*), WHERE conclusion = 'failure') FACET branch` |
| Build count by commit author | Bar | `SELECT count(*) FACET commit_author` |
| Failure rate by commit author | Bar | `SELECT percentage(count(*), WHERE conclusion = 'failure') FACET commit_author` |
| Build duration by commit author | Bar | `SELECT average(build_duration_seconds) FACET commit_author` |
| Build count by event type | Pie | `SELECT count(*) FACET event_name` |

---

## 7. Code Style

- Inline shell script in the workflow step — no separate script files to install
- `set -euo pipefail` at top of the inline script
- JSON built via heredoc / string concatenation — no `jq` required (but `jq` is available on `ubuntu-latest` if needed for parsing API responses)
- All NR API calls: `curl --silent --max-time 30`; errors logged; exit 0 always

---

## 9. Boundaries

### Always do
- Exit 0 from the NR post step — a NR failure must not fail the monitoring workflow
- Include `job_id` in every event for deduplication filtering
- Omit label-derived fields if not parseable (don't set `machine_os = ""`)

### Ask first
- Expanding to query multiple repos (requires org-level token or GitHub App)
- Changing the schedule frequency (more frequent = more API calls, approaching rate limits)

### Never do
- Run this workflow on Bitrise runners — it should run on `ubuntu-latest` (cheap, no runner consumption)
- Store `GITHUB_TOKEN` or NR keys in plaintext in the workflow file
- Post events for in-progress jobs — only `status=completed` runs

---

## 10. Out of Scope

- Multi-repo from a single workflow without a GitHub App — use Option B for that
- Accurate machine type/CPU count for build health charts (label-dependent — see SPEC-VM-HOOK.md for accurate values)
- Per-step timing
- Alerting / notification policies
