# SPEC: GHA Build Health — Cloudflare Worker Webhook (v2)

**Supersedes:** SPEC-GHA.md (scheduled polling approach)
**Status:** Draft
**Date:** 2026-04-05

---

## 1. Why v2

The scheduled polling approach (SPEC-GHA.md) requires N+1 GitHub API calls per run (1 to list runs + 1 per run to fetch jobs). For busy repos or org-wide monitoring this becomes expensive and slow.

**v2 uses GitHub webhooks instead:**
- GitHub pushes `workflow_job` events to a Cloudflare Worker on every job completion
- Zero GitHub API calls — the payload contains everything needed
- Zero GHA workflow runs spawned
- Real-time data (no up-to-4h delay)
- Free tier: 100K requests/day on Cloudflare Workers (sufficient for any customer)

---

## 2. Architecture

```
GitHub repo/org
  └── Webhook (workflow_job → completed)
        │
        │  HTTP POST (JSON payload)
        ▼
Cloudflare Worker (~20 lines JS)
  ├── filter: only Bitrise runner jobs
  ├── parse: job metadata, labels, timestamps
  ├── compute: wait_time, build_duration
  └── POST → New Relic Events API (GHABuildConclusion)
```

**For per-repo:** webhook in repo Settings → Webhooks
**For org-wide:** webhook in org Settings → Webhooks → same Worker URL covers all repos automatically — no GitHub App needed

---

## 3. Data Model

### `GHABuildConclusion` Event (NR Events API)

All fields come directly from the `workflow_job` webhook payload — no additional API calls.

#### From `workflow_job` object

| Attribute | Payload field | Example |
|---|---|---|
| `job_id` | `workflow_job.id` | `987654321` |
| `run_id` | `workflow_job.run_id` | `12345678` |
| `run_attempt` | `workflow_job.run_attempt` | `1` |
| `job_name` | `workflow_job.name` | `build (ubuntu, 18)` |
| `workflow_name` | `workflow_job.workflow_name` | `CI` |
| `conclusion` | `workflow_job.conclusion` | `success` / `failure` / `cancelled` / `skipped` / `timed_out` |
| `branch` | `workflow_job.head_branch` | `main` |
| `sha` | `workflow_job.head_sha` | `abc123...` |
| `runner_name` | `workflow_job.runner_name` | `vm-pool-g2-mac-m4pro-14c-...` |
| `runner_group_name` | `workflow_job.runner_group_name` | `Bitrise Mac Pool` |

#### Computed

| Attribute | Computation | Example |
|---|---|---|
| `wait_time_seconds` | `started_at − created_at` (seconds) | `90` |
| `build_duration_seconds` | `completed_at − started_at` (seconds) | `342` |
| `timestamp` | Unix epoch ms of `completed_at` | `1712345678000` |
| `eventType` | hardcoded | `GHABuildConclusion` |

#### From `repository` object

| Attribute | Payload field | Example |
|---|---|---|
| `repository` | `repository.full_name` | `org/repo` |

#### From `sender` object

| Attribute | Payload field | Notes |
|---|---|---|
| `actor` | `sender.login` | Who triggered the workflow — for push-based workflows this is the commit pusher, which equals the commit author in most cases. Differs on merges (merger vs PR author) and bot-pushed commits. |

#### From `workflow_job.labels` (best effort)

| Attribute | Parsing logic | Example |
|---|---|---|
| `machine_os` | First of `macOS`, `Linux`, `Windows` in labels | `macOS` |
| `machine_arch` | First of `arm64`, `x64`, `ARM64`, `X64` in labels | `arm64` |
| `cpu_count` | First label matching `\d+core` → extract number | `14` |
| `runner_type` | `self-hosted` in labels → `self-hosted`, else `github-hosted` | `self-hosted` |

If a label value is not parseable, the field is omitted.

### Known Limitations vs SPEC-GHA.md

| Field | Scheduled (v1) | Webhook (v2) |
|---|---|---|
| `event_name` (push/PR/schedule) | ✅ from API | ❌ not in webhook payload |
| `commit_author` | ✅ from `head_commit.author` | `actor` used instead — equals commit pusher for push-based workflows |
| `triggering_actor` | ✅ from API | ❌ not in webhook payload (`sender` only) |

These fields require an additional GitHub API call — omitted in v2 to keep zero-API-call architecture. Can be added later if needed.

---

## 4. Cloudflare Worker

### Deployment

- Platform: Cloudflare Workers (free tier: 100K requests/day, 10ms CPU/request)
- Language: JavaScript (ES modules)
- No build step, no dependencies — deploy directly via Wrangler CLI or Cloudflare dashboard

### Environment Variables (set as Worker secrets)

| Variable | Description |
|---|---|
| `NR_LICENSE_KEY` | New Relic Ingest - License key |
| `NR_ACCOUNT_ID` | New Relic numeric account ID |
| `GITHUB_WEBHOOK_SECRET` | Webhook secret set in GitHub (for signature validation) |
| `RUNNER_NAME_PREFIX` | Filter prefix for Bitrise runner names (e.g. `vm-pool`) |

### Worker Logic

```
1. Receive POST from GitHub
2. Validate X-Hub-Signature-256 (HMAC-SHA256 of body using GITHUB_WEBHOOK_SECRET)
3. Parse JSON body
4. Ignore if action != "completed"
5. Filter: skip if not a Bitrise runner job
   → runner_name starts with RUNNER_NAME_PREFIX
   → OR labels includes "self-hosted" (configurable)
6. Parse labels → machine_os, cpu_count, machine_arch, runner_type
7. Compute wait_time_seconds, build_duration_seconds
8. Build GHABuildConclusion event JSON
9. POST to NR Events API
10. Return 200 (always — even on NR failure, to avoid GitHub retrying)
```

### Filtering Bitrise Runner Jobs

Filter on `workflow_job.runner_name` using `RUNNER_NAME_PREFIX`:
```js
if (!job.runner_name?.startsWith(env.RUNNER_NAME_PREFIX)) return new Response('skipped', { status: 200 })
```

This ensures the Worker only forwards jobs that ran on Bitrise runners — not jobs on GitHub-hosted runners or other self-hosted runners in the same repo.

### Webhook Signature Validation

GitHub signs every webhook payload with `HMAC-SHA256` using the webhook secret:
```js
const sig = request.headers.get('X-Hub-Signature-256')
const expected = 'sha256=' + hex(await hmacSha256(env.GITHUB_WEBHOOK_SECRET, body))
if (sig !== expected) return new Response('Unauthorized', { status: 401 })
```

### Return 200 Always

Even if the NR POST fails, the Worker returns `200` to GitHub. If it returns non-2xx, GitHub will retry the webhook — causing duplicate events in NR. Better to log the failure and return 200.

---

## 5. Setup Instructions

### Step 1: Deploy the Cloudflare Worker

```bash
# Install Wrangler CLI
npm install -g wrangler

# Deploy (from the worker directory)
wrangler deploy

# Set secrets
wrangler secret put NR_LICENSE_KEY
wrangler secret put NR_ACCOUNT_ID
wrangler secret put GITHUB_WEBHOOK_SECRET
wrangler secret put RUNNER_NAME_PREFIX   # e.g. "vm-pool"
```

Or deploy via the Cloudflare dashboard (paste the JS, add secrets in UI).

Worker URL after deploy: `https://<worker-name>.<subdomain>.workers.dev`

### Step 2: Add GitHub Webhook

**Per-repo:**
→ Repo → Settings → Webhooks → Add webhook
- Payload URL: `https://<worker-name>.<subdomain>.workers.dev`
- Content type: `application/json`
- Secret: same value as `GITHUB_WEBHOOK_SECRET`
- Events: select **"Workflow jobs"** only

**Org-wide (one webhook, all repos):**
→ Org → Settings → Webhooks → Add webhook
- Same fields as above
- Covers all current and future repos automatically

### Step 3: Done

No GitHub App, no PAT, no scheduled workflow, no per-repo YAML changes needed.

---

## 6. NR Dashboard Widgets

### Dashboard Filters (template variables — apply to all widgets)

| Variable | NR attribute |
|---|---|
| Time picker | Built-in NR time picker |
| Repository | `repository` |
| Machine type | `machine_os` |
| vCPU count | `cpu_count` |
| Workflow name | `workflow_name` |
| Branch | `branch` |
| Commit author | `actor` |

### Widgets

All queries: `FROM GHABuildConclusion`

Deduplication: all count-based queries use `uniqueCount(job_id)` — handles any duplicate events from webhook retries.

| Widget | Type | NRQL sketch |
|---|---|---|
| Build count | Billboard | `SELECT uniqueCount(job_id)` |
| Failure rate | Billboard | `SELECT filter(uniqueCount(job_id), WHERE conclusion = 'failure') / uniqueCount(job_id) * 100` |
| p50 / p90 build time | Billboard | `SELECT percentile(build_duration_seconds, 50, 90)` |
| p50 / p90 wait time | Billboard | `SELECT percentile(wait_time_seconds, 50, 90)` |
| Build duration over time | Line | `SELECT percentile(build_duration_seconds, 50, 90) TIMESERIES 1 hour` |
| Wait time over time | Line | `SELECT percentile(wait_time_seconds, 50, 90) TIMESERIES 1 hour` |
| Failure rate over time | Line | `SELECT filter(uniqueCount(job_id), WHERE conclusion = 'failure') / uniqueCount(job_id) * 100 TIMESERIES 1 hour` |
| Build count by workflow | Bar | `SELECT uniqueCount(job_id) FACET workflow_name` |
| Failure rate by workflow | Bar | `SELECT filter(uniqueCount(job_id), WHERE conclusion = 'failure') / uniqueCount(job_id) * 100 FACET workflow_name` |
| Build duration by machine type | Bar | `SELECT average(build_duration_seconds) FACET machine_os` |
| Build duration by vCPU count | Bar | `SELECT average(build_duration_seconds) FACET cpu_count` |
| Build duration by branch | Bar | `SELECT average(build_duration_seconds) FACET branch` |
| Failure rate by branch | Bar | `SELECT filter(uniqueCount(job_id), WHERE conclusion = 'failure') / uniqueCount(job_id) * 100 FACET branch` |
| Build count by actor | Bar | `SELECT uniqueCount(job_id) FACET actor` |
| Failure rate by actor | Bar | `SELECT filter(uniqueCount(job_id), WHERE conclusion = 'failure') / uniqueCount(job_id) * 100 FACET actor` |
| Build duration by actor | Bar | `SELECT average(build_duration_seconds) FACET actor` |

---

## 7. Free Tier Limits

| Resource | Free Tier | Typical usage |
|---|---|---|
| Cloudflare Worker requests | 100K/day | 1 request per job completion |
| Cloudflare Worker CPU time | 10ms/request | ~1ms per request (simple JSON transform + curl) |
| New Relic Events ingest | 100 GB/month | ~1 KB per event × jobs/month — negligible |

100K requests/day = ~3M jobs/month. Sufficient for any customer.

---

## 8. Boundaries

### Always do
- Return `200` to GitHub even on NR failure — prevents webhook retries and duplicate events
- Validate `X-Hub-Signature-256` before processing
- Filter to Bitrise runner jobs only — ignore github-hosted runner jobs
- Use `uniqueCount(job_id)` in all count-based NRQL queries

### Never do
- Make GitHub API calls from the Worker — payload has everything needed
- Store webhook payloads — process and forward only
- Return non-2xx to GitHub unless signature validation fails

---

## 9. Out of Scope

- `event_name` (push/PR/schedule) — not in webhook payload without an API call
- `commit_author` — not a distinct field; `actor` (sender.login) is used as proxy, which is accurate for push-based workflows
- Worker authentication beyond webhook signature (the Worker URL is not secret — security comes from signature validation)
- Multi-region Cloudflare Worker deployment (single region is fine for this use case)
