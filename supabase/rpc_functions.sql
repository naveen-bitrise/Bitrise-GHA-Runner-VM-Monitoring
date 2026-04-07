-- RPC functions for the Builds Dashboard webapp.
-- Run this entire file in the Supabase SQL editor once.
-- Safe to re-run — all functions use CREATE OR REPLACE.
--
-- NOTE: builds_stats, builds_trend, builds_breakdown already exist in Supabase
-- (they pre-date this file). Only the three job_* functions below are new.

-- ============================================================
-- 1. job_stats
--    Returns one row: failure_rate, queue_time_p90, queue_time_p50
--    from the job_conclusions table.
-- ============================================================
create or replace function job_stats(
  p_weeks     integer  default 12,
  p_workflow  text     default null,
  p_branch    text     default null,
  p_runner_os text     default null,
  p_cpu_count integer  default null,
  p_from      text     default null,
  p_to        text     default null
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

-- ============================================================
-- 2. job_trend
--    Returns weekly buckets for one job_conclusions metric.
--    p_metric: failure_rate | queue_time_p90 | queue_time_p50
-- ============================================================
create or replace function job_trend(
  p_metric    text     default 'failure_rate',
  p_weeks     integer  default 12,
  p_workflow  text     default null,
  p_branch    text     default null,
  p_runner_os text     default null,
  p_cpu_count integer  default null,
  p_from      text     default null,
  p_to        text     default null
) returns table (week text, value numeric)
language sql security definer as $$
  with agg as (
    select
      date_trunc('week', completed_at)                                        as wk,
      round(
        100.0 * count(*) filter (where conclusion != 'success')
        / nullif(count(*), 0),
        1
      )                                                                       as failure_rate,
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
  select
    to_char(wk, 'YYYY-MM-DD'),
    case p_metric
      when 'failure_rate'   then failure_rate
      when 'queue_time_p90' then q_p90
      when 'queue_time_p50' then q_p50
    end
  from agg
  order by wk
$$;

-- ============================================================
-- 3. job_breakdown
--    Returns (dim, week, value) for one job_conclusions metric.
--    p_metric:    failure_rate | queue_time_p90 | queue_time_p50
--    p_dimension: workflow | branch | runner_os | cpu_count
-- ============================================================
create or replace function job_breakdown(
  p_metric    text     default 'failure_rate',
  p_dimension text     default 'workflow',
  p_weeks     integer  default 12,
  p_workflow  text     default null,
  p_branch    text     default null,
  p_runner_os text     default null,
  p_cpu_count integer  default null,
  p_from      text     default null,
  p_to        text     default null
) returns table (dim text, week text, value numeric)
language sql security definer as $$
  with agg as (
    select
      case p_dimension
        when 'workflow'  then workflow_name
        when 'branch'    then branch
        when 'runner_os' then machine_os
        when 'cpu_count' then cpu_count::text
      end                                                                     as dim,
      date_trunc('week', completed_at)                                        as wk,
      round(
        100.0 * count(*) filter (where conclusion != 'success')
        / nullif(count(*), 0),
        1
      )                                                                       as failure_rate,
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
  select
    coalesce(dim, 'unknown'),
    to_char(wk, 'YYYY-MM-DD'),
    case p_metric
      when 'failure_rate'   then failure_rate
      when 'queue_time_p90' then q_p90
      when 'queue_time_p50' then q_p50
    end
  from agg
  order by wk, dim
$$;
