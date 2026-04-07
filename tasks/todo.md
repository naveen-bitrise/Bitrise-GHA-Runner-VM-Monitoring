# TODO: SPEC-SUPABASE.md Implementation

Branch: `supabase` (create from `main`)

---

## Pre-work (manual — not code)

- [ ] P0. Create Supabase project; run schema SQL for `metrics`, `builds`, and `job_conclusions` tables; enable RLS with anon-INSERT policy on all three; note `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`

---

## Stream A — Supabase Schema + Runner Scripts

- [ ] A1. Create `scripts/send_metrics_to_supabase.sh` — batch-POST CSV rows to `metrics` table (batches of 500, logs to `supabase.log`, exits 0 always)
- [ ] A2. Create `scripts/send_build_info_to_supabase.sh` — upsert one row to `builds` table on `run_id`
- [ ] A3. Create `scripts/supabase_hook.sh` — `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` entry point; calls A1 + A2; mirror structure of `newrelic_hook.sh`
- [ ] A4. Update `scripts/warmup_runner.sh` — replace NR placeholders/copies with Supabase equivalents; point hook at `supabase_hook.sh`; update branch name to `supabase`
- [ ] A-CHECKPOINT. Smoke test: run A1 + A2 locally against `monitoring-20251204_035335.csv`; verify rows in Supabase table editor; verify no duplicate `builds` row on re-run

---

## Stream D — Edge Function: Job Conclusions (independent of A/B/C)

- [ ] D1. Create `supabase/functions/gha-webhook/index.ts` — validate `X-Hub-Signature-256`, filter by `RUNNER_NAME_PREFIX`, parse labels (machine_os/arch/cpu_count/runner_type), compute `wait_time_seconds` + `build_duration_seconds`, upsert into `job_conclusions` on `job_id`; return 200 always
- [ ] D2. Deploy Edge Function via Supabase CLI; set `GITHUB_WEBHOOK_SECRET` and `RUNNER_NAME_PREFIX` secrets
- [ ] D3. Configure GitHub org-level webhook → Payload URL: Edge Function URL; Events: Workflow jobs only; Secret: matches `GITHUB_WEBHOOK_SECRET`
- [ ] D-CHECKPOINT. Send synthetic `workflow_job completed` payload with valid HMAC signature; verify row in `job_conclusions` (conclusion, wait_time_seconds, machine_os, cpu_count); verify re-send does not duplicate

---

## Stream B — Webapp: VM Metrics Page

- [ ] B1. Restore webapp skeleton — `webapp/app.rb` (stripped of CSV logic), `webapp/views/index.erb` (layout shell), `webapp/Gemfile`, `webapp/config.ru` from git `fa0e15a`; add Supabase ENV constants; verify `bundle exec ruby webapp/app.rb` starts
- [ ] B2. Implement Supabase client helper + `/api/vm_filters`, `/api/vm_runs`, `/api/metrics/:run_id` in `webapp/app.rb`
- [ ] B3. Rewrite `webapp/views/index.erb` — 6-filter bar (started_at range, workflow, branch, repository, runner_os, cpu_count) + VM run selector (top 10, desc by started_at, label: `vm_name — run_id — workflow — started_at`) + 4 charts (Chart.js logic unchanged from `fa0e15a`)
- [ ] B-CHECKPOINT. Manual: open `/`; all 6 filters populate; filter change narrows selector; selecting run renders 4 charts; no key in page source

---

## Stream C — Webapp: Builds Dashboard Page

- [ ] C1. Implement `/api/builds/filters`, `/api/builds/stats`, `/api/builds/trend`, `/api/builds/breakdown` in `webapp/app.rb`; `builds_stats` + `job_stats` RPCs merged in stats endpoint (job_stats graceful fallback); `JOB_METRICS` constant routes failure_rate/queue_time_p90/queue_time_p50 to job_trend/job_breakdown RPCs
- [ ] C2. Create `webapp/views/builds.erb` — 7 metric tab cards (p90/p50/count/total from builds; failure_rate/queue_time_p90/queue_time_p50 from job_conclusions — show — until Stream D live), trend line chart (% y-axis for failure_rate, duration for others), breakdown multi-line chart, top filters, time range selector, breakdown tab visibility rules
- [ ] C-CHECKPOINT. Manual: open `/builds`; 4 builds cards show values; 3 job_conclusions cards show —; trend + breakdown render; failure_rate tab shows % axis; queue_time tab shows duration axis; metric tab switch updates both charts; filter + time range controls work; no key in page source

---

## Final wiring

- [ ] F1. Add top nav to `webapp/views/index.erb` and `webapp/views/builds.erb` with links to `/` and `/builds`; active page link highlighted
- [ ] F2. Update `README.md` — replace NR setup instructions with Supabase setup (credentials, schema SQL, Edge Function deploy, GitHub webhook config, webapp env vars)
