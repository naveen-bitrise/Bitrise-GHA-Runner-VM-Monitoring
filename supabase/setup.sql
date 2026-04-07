-- =============================================================
-- Supabase setup for GHA Runner VM Monitoring
-- Run this entire file once in the Supabase SQL editor.
-- Safe to re-run — tables use IF NOT EXISTS,
-- functions use CREATE OR REPLACE.
-- =============================================================

-- -------------------------------------------------------------
-- Tables
-- -------------------------------------------------------------

create table if not exists metrics (
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
create index if not exists metrics_run_id_idx     on metrics (run_id);
create index if not exists metrics_vm_name_idx    on metrics (vm_name);
create index if not exists metrics_sampled_at_idx on metrics (sampled_at desc);

create table if not exists builds (
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
alter table builds add constraint if not exists builds_run_id_attempt_key unique (run_id, run_attempt);
create index if not exists builds_vm_name_idx   on builds (vm_name);
create index if not exists builds_workflow_idx  on builds (workflow_name);
create index if not exists builds_completed_idx on builds (completed_at desc);
create index if not exists builds_branch_idx    on builds (branch);
create index if not exists builds_runner_os_idx on builds (runner_os);
create index if not exists builds_cpu_count_idx on builds (cpu_count);

create table if not exists job_conclusions (
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
create index if not exists job_conclusions_run_id_idx     on job_conclusions (run_id);
create index if not exists job_conclusions_runner_idx     on job_conclusions (runner_name);
create index if not exists job_conclusions_completed_idx  on job_conclusions (completed_at desc);
create index if not exists job_conclusions_conclusion_idx on job_conclusions (conclusion);

-- -------------------------------------------------------------
-- Row Level Security
-- anon role: INSERT only (used by runner scripts)
-- service_role: bypasses RLS (used by webapp + Edge Function)
-- -------------------------------------------------------------

alter table metrics         enable row level security;
alter table builds          enable row level security;
alter table job_conclusions enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'metrics' and policyname = 'anon insert metrics') then
    create policy "anon insert metrics" on metrics for insert to anon with check (true);
  end if;
  if not exists (select 1 from pg_policies where tablename = 'builds' and policyname = 'anon insert builds') then
    create policy "anon insert builds" on builds for insert to anon with check (true);
  end if;
  if not exists (select 1 from pg_policies where tablename = 'job_conclusions' and policyname = 'anon insert job_conclusions') then
    create policy "anon insert job_conclusions" on job_conclusions for insert to anon with check (true);
  end if;
end $$;

-- -------------------------------------------------------------
-- RPC functions — Builds Dashboard
-- -------------------------------------------------------------

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
language sql security definer as $$
  select json_build_object(
    'p90_seconds',            percentile_cont(0.9) within group (order by build_duration_seconds),
    'p50_seconds',            percentile_cont(0.5) within group (order by build_duration_seconds),
    'count',                  count(*),
    'total_duration_seconds', coalesce(sum(build_duration_seconds), 0)
  )
  from builds
  where
    (p_workflow  is null or workflow_name = p_workflow)
    and (p_branch    is null or branch       = p_branch)
    and (p_runner_os is null or runner_os    = p_runner_os)
    and (p_cpu_count is null or cpu_count    = p_cpu_count)
    and completed_at >= coalesce(p_from::timestamptz, (current_date - (p_weeks * 7))::timestamptz)
    and completed_at <  coalesce((p_to + 1)::timestamptz, now() + interval '1 second')
$$;

-- builds_trend: weekly buckets for a single builds metric
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
language sql security definer as $$
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
    (p_workflow  is null or workflow_name = p_workflow)
    and (p_branch    is null or branch       = p_branch)
    and (p_runner_os is null or runner_os    = p_runner_os)
    and (p_cpu_count is null or cpu_count    = p_cpu_count)
    and completed_at >= coalesce(p_from::timestamptz, (current_date - (p_weeks * 7))::timestamptz)
    and completed_at <  coalesce((p_to + 1)::timestamptz, now() + interval '1 second')
  group by 1
  order by 1
$$;

-- builds_breakdown: weekly buckets per dimension value
create or replace function builds_breakdown(
  p_weeks     int     default 12,
  p_metric    text    default 'p90',
  p_dimension text    default 'workflow',
  p_workflow  text    default null,
  p_branch    text    default null,
  p_runner_os text    default null,
  p_cpu_count int     default null,
  p_from      date    default null,
  p_to        date    default null
)
returns table(week date, dim text, value numeric)
language sql security definer as $$
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
    (p_dimension = 'workflow'  or p_workflow  is null or workflow_name = p_workflow)
    and (p_dimension = 'branch'    or p_branch    is null or branch       = p_branch)
    and (p_dimension = 'runner_os' or p_runner_os is null or runner_os    = p_runner_os)
    and (p_dimension = 'cpu_count' or p_cpu_count is null or cpu_count    = p_cpu_count)
    and completed_at >= coalesce(p_from::timestamptz, (current_date - (p_weeks * 7))::timestamptz)
    and completed_at <  coalesce((p_to + 1)::timestamptz, now() + interval '1 second')
  group by 1, 2
  order by 1, 2
$$;

-- job_stats: failure_rate, queue_time_p90/p50 from job_conclusions
create or replace function job_stats(
  p_weeks     integer default 12,
  p_workflow  text    default null,
  p_branch    text    default null,
  p_runner_os text    default null,
  p_cpu_count integer default null,
  p_from      text    default null,
  p_to        text    default null
) returns table (failure_rate numeric, queue_time_p90 numeric, queue_time_p50 numeric)
language sql security definer as $$
  select
    round(
      100.0 * count(*) filter (where conclusion != 'success')
      / nullif(count(*), 0),
      1
    ),
    round(percentile_cont(0.9) within group (order by wait_time_seconds)::numeric, 0),
    round(percentile_cont(0.5) within group (order by wait_time_seconds)::numeric, 0)
  from job_conclusions
  where
    (p_workflow  is null or workflow_name = p_workflow)
    and (p_branch    is null or branch       = p_branch)
    and (p_runner_os is null or machine_os   = p_runner_os)
    and (p_cpu_count is null or cpu_count    = p_cpu_count)
    and completed_at >= coalesce(
          p_from::timestamptz,
          now() - make_interval(weeks => coalesce(p_weeks, 12))
        )
    and completed_at <= coalesce(p_to::timestamptz, now())
$$;

-- job_trend: weekly buckets for a single job_conclusions metric
create or replace function job_trend(
  p_metric    text    default 'failure_rate',
  p_weeks     integer default 12,
  p_workflow  text    default null,
  p_branch    text    default null,
  p_runner_os text    default null,
  p_cpu_count integer default null,
  p_from      text    default null,
  p_to        text    default null
) returns table (week text, value numeric)
language sql security definer as $$
  with agg as (
    select
      date_trunc('week', completed_at) as wk,
      round(
        100.0 * count(*) filter (where conclusion != 'success')
        / nullif(count(*), 0), 1
      ) as failure_rate,
      round(percentile_cont(0.9) within group (order by wait_time_seconds)::numeric, 0) as q_p90,
      round(percentile_cont(0.5) within group (order by wait_time_seconds)::numeric, 0) as q_p50
    from job_conclusions
    where
      (p_workflow  is null or workflow_name = p_workflow)
      and (p_branch    is null or branch       = p_branch)
      and (p_runner_os is null or machine_os   = p_runner_os)
      and (p_cpu_count is null or cpu_count    = p_cpu_count)
      and completed_at >= coalesce(
            p_from::timestamptz,
            now() - make_interval(weeks => coalesce(p_weeks, 12))
          )
      and completed_at <= coalesce(p_to::timestamptz, now())
    group by 1
  )
  select to_char(wk, 'YYYY-MM-DD'),
    case p_metric
      when 'failure_rate'   then failure_rate
      when 'queue_time_p90' then q_p90
      when 'queue_time_p50' then q_p50
    end
  from agg order by wk
$$;

-- job_breakdown: weekly buckets per dimension for job_conclusions metrics
create or replace function job_breakdown(
  p_metric    text    default 'failure_rate',
  p_dimension text    default 'workflow',
  p_weeks     integer default 12,
  p_workflow  text    default null,
  p_branch    text    default null,
  p_runner_os text    default null,
  p_cpu_count integer default null,
  p_from      text    default null,
  p_to        text    default null
) returns table (dim text, week text, value numeric)
language sql security definer as $$
  with agg as (
    select
      case p_dimension
        when 'workflow'  then workflow_name
        when 'branch'    then branch
        when 'runner_os' then machine_os
        when 'cpu_count' then cpu_count::text
      end as dim,
      date_trunc('week', completed_at) as wk,
      round(
        100.0 * count(*) filter (where conclusion != 'success')
        / nullif(count(*), 0), 1
      ) as failure_rate,
      round(percentile_cont(0.9) within group (order by wait_time_seconds)::numeric, 0) as q_p90,
      round(percentile_cont(0.5) within group (order by wait_time_seconds)::numeric, 0) as q_p50
    from job_conclusions
    where
      (p_dimension = 'workflow'  or p_workflow  is null or workflow_name = p_workflow)
      and (p_dimension = 'branch'    or p_branch    is null or branch       = p_branch)
      and (p_dimension = 'runner_os' or p_runner_os is null or machine_os   = p_runner_os)
      and (p_dimension = 'cpu_count' or p_cpu_count is null or cpu_count    = p_cpu_count)
      and completed_at >= coalesce(
            p_from::timestamptz,
            now() - make_interval(weeks => coalesce(p_weeks, 12))
          )
      and completed_at <= coalesce(p_to::timestamptz, now())
    group by 1, 2
  )
  select coalesce(dim, 'unknown'), to_char(wk, 'YYYY-MM-DD'),
    case p_metric
      when 'failure_rate'   then failure_rate
      when 'queue_time_p90' then q_p90
      when 'queue_time_p50' then q_p50
    end
  from agg order by wk, dim
$$;

grant execute on function builds_stats     to service_role;
grant execute on function builds_trend     to service_role;
grant execute on function builds_breakdown to service_role;
grant execute on function job_stats        to service_role;
grant execute on function job_trend        to service_role;
grant execute on function job_breakdown    to service_role;

-- -------------------------------------------------------------
-- Scheduled cleanup: delete metrics older than 7 days
-- Runs daily at 02:00 UTC via pg_cron (built into Supabase).
-- Safe to re-run — cron.schedule replaces any existing job
-- with the same name.
-- -------------------------------------------------------------
select cron.schedule(
  'delete-old-metrics',
  '0 2 * * *',
  $$delete from metrics where sampled_at < now() - interval '7 days'$$
);
