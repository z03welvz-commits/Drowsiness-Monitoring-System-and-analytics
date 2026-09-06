-- ============================================================================
-- DDS — 0064_fix_driver_asset_weekly_unspecified_streak
-- ----------------------------------------------------------------------------
-- REAL FIX for the dds_driver_asset_weekly() timeout (0062's index attempt
-- was wrong for this data shape and has been dropped by 0063).
--
-- ROOT CAUSE, confirmed via EXPLAIN ANALYZE: dds_current_streak('driver',
-- 'UNSPECIFIED') forces a sequential scan of `events`, because 85,801 of
-- 98,877 rows (87%) in this dataset have emp_no IS NULL — far too large a
-- fraction for ANY index (partial or otherwise) to beat a seq scan; the
-- planner's choice is correct, not a missing-index problem. This one call
-- (out of ~84 entities in a typical week) dominates the function's runtime
-- and pushes it over the `authenticated` role's 8s statement_timeout under
-- real page-load/pooled-connection conditions, even though the function
-- measures ~2s over an uncontended direct connection.
--
-- THE ACTUAL FIX: 'UNSPECIFIED' was never a real driver who could
-- meaningfully be "flagged for a consistent alert pattern" in the first
-- place — every other ranked-driver surface in this app (Analytics' Top
-- Employees list, for one) already excludes the Unspecified bucket from
-- this exact kind of per-driver behavioral scoring. This migration makes
-- dds_driver_asset_weekly() consistent with that: the 'UNSPECIFIED' driver
-- key skips dds_current_streak() entirely and reports streakDays: 0,
-- status computed the same way any other zero-streak driver would be
-- (i.e. 'required' only if entity_status.status is independently
-- 'monitoring' — never via the streak path). It still appears in the
-- drivers list with its real day-by-day counts; only the expensive,
-- meaningless-for-this-key streak calculation is skipped.
--
-- Asset streaks are untouched — assets are always identified by a real
-- asset_id (never an 'UNSPECIFIED' bucket), and dds_current_streak('asset',
-- ...) already benefits from idx_events_asset_shift_date (confirmed fast:
-- ~5ms via EXPLAIN ANALYZE), so there is no equivalent problem to fix there.
-- ============================================================================

create or replace function public.dds_driver_asset_weekly(
  p_from date default null,
  p_to   date default null
) returns jsonb
language sql
stable
set search_path = public
set work_mem = '64MB'
as $$
  with bounds as (
    select
      coalesce(p_from, current_date - interval '6 days')::date as v_from,
      coalesce(p_to, current_date)::date as v_to
  ),
  filtered as (
    select
      coalesce(emp_no, 'UNSPECIFIED') as driver_key,
      asset_id,
      shift_date,
      event_count
    from public.events, bounds
    where shift_date >= bounds.v_from
      and shift_date <= bounds.v_to
  ),
  driver_days_agg as (
    select driver_key as entity_id, jsonb_object_agg(day_label, counts) as days
    from (
      select driver_key,
             to_char(shift_date, 'Dy') as day_label,
             jsonb_agg(event_count order by event_count desc) as counts
      from filtered
      group by driver_key, to_char(shift_date, 'Dy')
    ) x
    group by driver_key
  ),
  asset_days_agg as (
    select asset_id as entity_id, jsonb_object_agg(day_label, counts) as days
    from (
      select asset_id,
             to_char(shift_date, 'Dy') as day_label,
             jsonb_agg(event_count order by event_count desc) as counts
      from filtered
      group by asset_id, to_char(shift_date, 'Dy')
    ) x
    group by asset_id
  ),
  driver_entities as (
    select distinct driver_key as entity_id from filtered
  ),
  asset_entities as (
    select distinct asset_id as entity_id from filtered
  ),
  -- 'UNSPECIFIED' is excluded here — see header. Every other driver still
  -- gets its real streak via dds_current_streak(), untouched.
  driver_streaks as (
    select entity_id, public.dds_current_streak('driver', entity_id) as streak
    from driver_entities
    where entity_id <> 'UNSPECIFIED'
  ),
  asset_streaks as (
    select entity_id, public.dds_current_streak('asset', entity_id) as streak
    from asset_entities
  ),
  driver_names as (
    select coalesce(d.full_name, e.entity_id) as name, e.entity_id as driver_key
    from driver_entities e
    left join public.drivers d on d.emp_no = e.entity_id
  ),
  last_actions as (
    select distinct on (entity_type, entity_id)
      entity_type, entity_id, action_type, note, logged_by, created_at
    from public.entity_action_log
    order by entity_type, entity_id, created_at desc
  ),
  drivers_out as (
    select jsonb_build_object(
      'id', e.entity_id,
      'name', case when e.entity_id = 'UNSPECIFIED' then 'Unspecified' else n.name end,
      'days', coalesce(dd.days, '{}'::jsonb),
      'status', case
                  when es.status = 'monitoring' then
                    case when es.monitor_until is not null and es.monitor_until >= current_date
                         then 'monitoring' else 'resolved' end
                  else
                    case when coalesce(ds.streak, 0) >= 3 then 'required' else 'ok' end
                end,
      'streakDays', coalesce(ds.streak, 0),
      'recurrenceCount', coalesce(es.recurrence_count, 0),
      'monitorUntil', to_char(es.monitor_until, 'YYYY-MM-DD'),
      'lastAction', case when la.entity_id is null then null else jsonb_build_object(
        'type', la.action_type, 'note', la.note, 'by', la.logged_by,
        'at', to_char(la.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
      ) end
    ) as row
    from driver_entities e
    left join driver_names n on n.driver_key = e.entity_id
    left join driver_days_agg dd on dd.entity_id = e.entity_id
    left join driver_streaks ds on ds.entity_id = e.entity_id
    left join public.entity_status es on es.entity_type = 'driver' and es.entity_id = e.entity_id
    left join last_actions la on la.entity_type = 'driver' and la.entity_id = e.entity_id
  ),
  assets_out as (
    select jsonb_build_object(
      'id', e.entity_id,
      'name', e.entity_id,
      'days', coalesce(ad.days, '{}'::jsonb),
      'status', case
                  when es.status = 'monitoring' then
                    case when es.monitor_until is not null and es.monitor_until >= current_date
                         then 'monitoring' else 'resolved' end
                  else
                    case when coalesce(ast.streak, 0) >= 3 then 'required' else 'ok' end
                end,
      'streakDays', coalesce(ast.streak, 0),
      'recurrenceCount', coalesce(es.recurrence_count, 0),
      'monitorUntil', to_char(es.monitor_until, 'YYYY-MM-DD'),
      'lastAction', case when la.entity_id is null then null else jsonb_build_object(
        'type', la.action_type, 'note', la.note, 'by', la.logged_by,
        'at', to_char(la.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
      ) end
    ) as row
    from asset_entities e
    left join asset_days_agg ad on ad.entity_id = e.entity_id
    left join asset_streaks ast on ast.entity_id = e.entity_id
    left join public.entity_status es on es.entity_type = 'asset' and es.entity_id = e.entity_id
    left join last_actions la on la.entity_type = 'asset' and la.entity_id = e.entity_id
  )
  select jsonb_build_object(
    'drivers', coalesce((select jsonb_agg(row) from drivers_out), '[]'::jsonb),
    'assets',  coalesce((select jsonb_agg(row) from assets_out), '[]'::jsonb)
  );
$$;
