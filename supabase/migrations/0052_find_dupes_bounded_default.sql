-- ============================================================================
-- DDS — 0052_find_dupes_bounded_default
-- ----------------------------------------------------------------------------
-- Live-data testing against the real database (98,877 events) found
-- dds_find_near_duplicate_events (0051) times out: with no p_from/p_to
-- (Alert Logs' default, unfiltered state — exactly what a user hits
-- clicking "Find duplicates" without first setting a date range), the
-- self-join scans the entire events table. Same class of bug as
-- dds_driver_asset_weekly before 0048 — a CTE-scoped filter that's
-- correct in shape but was never given a bounded default, so the
-- "no filter set" case degrades to a full-table self-join.
--
-- Fix: same pattern as 0048 — null/null now means "trailing 7 days", not
-- "all time". Finding duplicates is inherently a check against recent
-- activity (did today's/this week's import double-log something), not a
-- historical audit tool, so this default matches the actual use case
-- rather than only existing as a performance patch. An explicit wide
-- p_from/p_to still works for a caller that deliberately wants a longer
-- window. Also adds work_mem headroom for the self-join, matching every
-- other multi-row-scan RPC in this schema (0040).
-- ============================================================================

create or replace function public.dds_find_near_duplicate_events(
  p_from             date default null,
  p_to               date default null,
  p_window_seconds   integer default 60,
  p_limit            integer default 100
)
returns jsonb
language sql
stable
security invoker
set search_path = public
set work_mem = '64MB'
as $$
  with bounds as (
    select
      coalesce(p_from, current_date - interval '6 days')::date as v_from,
      coalesce(p_to, current_date)::date as v_to
  ),
  candidates as (
    select e.id, e.asset_id, e.event_code, e.start_time, e.event_count,
           coalesce(e.emp_no, e.operator, 'Unspecified') as driver_display
    from public.events e, bounds
    where e.shift_date >= bounds.v_from
      and e.shift_date <= bounds.v_to
  ),
  pairs as (
    select a.id as event_id_a, b.id as event_id_b,
           a.asset_id, a.event_code, a.start_time as start_time_a, b.start_time as start_time_b,
           a.driver_display,
           extract(epoch from (b.start_time - a.start_time))::integer as gap_seconds
    from candidates a
    join candidates b
      on a.asset_id = b.asset_id
     and a.event_code = b.event_code
     and a.id < b.id
     and b.start_time between a.start_time and a.start_time + make_interval(secs => p_window_seconds)
  )
  select jsonb_build_object(
    'pairs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'eventIdA', event_id_a, 'eventIdB', event_id_b,
        'assetId', asset_id, 'eventCode', event_code,
        'startTimeA', start_time_a, 'startTimeB', start_time_b,
        'driverDisplay', driver_display, 'gapSeconds', gap_seconds
      ) order by gap_seconds asc)
      from (select * from pairs limit p_limit) p
    ), '[]'::jsonb),
    'total', (select count(*) from pairs)
  );
$$;

revoke all on function public.dds_find_near_duplicate_events(date, date, integer, integer) from public, anon;
grant execute on function public.dds_find_near_duplicate_events(date, date, integer, integer) to authenticated;
