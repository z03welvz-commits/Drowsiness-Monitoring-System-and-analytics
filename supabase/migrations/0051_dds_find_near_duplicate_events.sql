-- ============================================================================
-- DDS — 0051_dds_find_near_duplicate_events
-- ----------------------------------------------------------------------------
-- The code-correctness audit's "post-upload duplicate detection" finding
-- noted this exists at upload time (Data Management's preflight check) but
-- nowhere for data already in the database, and recommended a lightweight
-- "find duplicates" action from Alert Logs.
--
-- events.uq_events_natural (asset_id, start_time, event_code) already makes
-- exact-key duplicates impossible — that's not the failure mode worth
-- surfacing. The real one an operator hits is a genuine double-log: the
-- same asset firing the same event code twice within a few seconds
-- (a device retry, a manual re-entry, a borderline shift-boundary split).
-- This RPC finds pairs of events sharing (asset_id, event_code) whose
-- start_time is within a configurable window of each other, scoped to the
-- date range the caller is currently viewing — a small, indexed self-join
-- (idx_events_shiftdate/idx_events_asset already cover the filter), not a
-- full-table scan.
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
as $$
  with candidates as (
    select e.id, e.asset_id, e.event_code, e.start_time, e.event_count,
           coalesce(e.emp_no, e.operator, 'Unspecified') as driver_display
    from public.events e
    where (p_from is null or e.shift_date >= p_from)
      and (p_to   is null or e.shift_date <= p_to)
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
