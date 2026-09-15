-- ============================================================================
-- DDS — 0135_driver_asset_weekly_persist_until_closed
-- ----------------------------------------------------------------------------
-- Audit finding (live-data confirmed): dds_driver_asset_weekly()'s 'required'
-- status — the source of Driver & Asset Monitoring's "Action Required" KPI
-- and Assets/Drivers tables — only ever checked the entity's SINGLE MOST
-- RECENT day (driver_latest_day_total / asset_latest_day_total) against the
-- >10 threshold, or a run of 3+ consecutive qualifying (>=20/day) days
-- ending on that same most-recent day. A qualifying day that is NOT the
-- entity's latest logged day is invisible to this check no matter how
-- severe, the moment even one quieter day follows it.
--
-- Confirmed live: asset DT-689 had a 196-alert day on 2026-09-12, then only
-- 4 alerts on its next (and latest, within the default 7-day window) day
-- 2026-09-13. dds_driver_asset_weekly() returned status:"ok", streakDays:0
-- for DT-689 — the 196-alert day was completely hidden from Action Required
-- because it wasn't the latest day. Same shape of bug applies identically
-- to drivers via driver_latest_day_total.
--
-- Fix, per explicit decision: a qualifying day (day_total > 10, same
-- threshold and same 90-day lookback window already computed for the
-- streak calc — no new scan added) now flags the entity 'required' and
-- KEEPS it flagged regardless of how many quiet days follow, exactly
-- mirroring the "persist until closed" policy already applied to Driver
-- Streaks (0130): it only stops being 'required' when a human explicitly
-- logs Monitoring/Closed via entity_status, never by the entity simply
-- having a quiet day.
--
-- driver_latest_day_total / asset_latest_day_total are replaced by
-- driver_any_qualifying / asset_any_qualifying (bool_or over the same
-- *_entity_days CTE, no additional table scan); the old CTEs are dropped
-- entirely rather than left unused.
-- ============================================================================
create or replace function public.dds_driver_asset_weekly(p_from date default null, p_to date default null)
returns jsonb
language sql
stable
set search_path to 'public'
set work_mem to '64MB'
as $function$
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

  driver_entity_last_day as (
    select coalesce(emp_no, 'UNSPECIFIED') as entity_id, max(shift_date) as last_day
    from public.events
    where coalesce(emp_no, 'UNSPECIFIED') in (
      select entity_id from driver_entities where entity_id <> 'UNSPECIFIED'
    )
    group by coalesce(emp_no, 'UNSPECIFIED')
  ),
  driver_entity_days as (
    select e.driver_key as entity_id, e.shift_date, sum(e.event_count) as day_total
    from (select coalesce(emp_no, 'UNSPECIFIED') as driver_key, shift_date, event_count from public.events) e
    join driver_entity_last_day l on l.entity_id = e.driver_key
    where e.shift_date >= l.last_day - interval '89 days'
    group by e.driver_key, e.shift_date
  ),
  driver_cal as (
    select l.entity_id, gs.cal_date::date as cal_date
    from driver_entity_last_day l
    cross join lateral generate_series(l.last_day - interval '89 days', l.last_day, interval '1 day') as gs(cal_date)
  ),
  driver_ranked as (
    select cal.entity_id,
           row_number() over (partition by cal.entity_id order by cal.cal_date desc) as rn,
           (coalesce(ed.day_total, 0) >= 20) as qualifies
    from driver_cal cal
    left join driver_entity_days ed on ed.entity_id = cal.entity_id and ed.shift_date = cal.cal_date
  ),
  driver_first_break as (
    select entity_id, min(rn) as rn from driver_ranked where not qualifies group by entity_id
  ),
  driver_streaks as (
    select l.entity_id,
      coalesce(
        case when fb.rn is null then (select count(*) from driver_ranked r where r.entity_id = l.entity_id)
        else fb.rn - 1 end, 0
      ) as streak
    from driver_entity_last_day l
    left join driver_first_break fb on fb.entity_id = l.entity_id
  ),
  driver_any_qualifying as (
    select entity_id, bool_or(day_total > 10) as has_qualifying_day
    from driver_entity_days
    group by entity_id
  ),
  asset_entity_last_day as (
    select asset_id as entity_id, max(shift_date) as last_day
    from public.events
    where asset_id in (select entity_id from asset_entities)
    group by asset_id
  ),
  asset_entity_days as (
    select e.asset_id as entity_id, e.shift_date, sum(e.event_count) as day_total
    from public.events e
    join asset_entity_last_day l on l.entity_id = e.asset_id
    where e.shift_date >= l.last_day - interval '89 days'
    group by e.asset_id, e.shift_date
  ),
  asset_cal as (
    select l.entity_id, gs.cal_date::date as cal_date
    from asset_entity_last_day l
    cross join lateral generate_series(l.last_day - interval '89 days', l.last_day, interval '1 day') as gs(cal_date)
  ),
  asset_ranked as (
    select cal.entity_id,
           row_number() over (partition by cal.entity_id order by cal.cal_date desc) as rn,
           (coalesce(ed.day_total, 0) >= 20) as qualifies
    from asset_cal cal
    left join asset_entity_days ed on ed.entity_id = cal.entity_id and ed.shift_date = cal.cal_date
  ),
  asset_first_break as (
    select entity_id, min(rn) as rn from asset_ranked where not qualifies group by entity_id
  ),
  asset_streaks as (
    select l.entity_id,
      coalesce(
        case when fb.rn is null then (select count(*) from asset_ranked r where r.entity_id = l.entity_id)
        else fb.rn - 1 end, 0
      ) as streak
    from asset_entity_last_day l
    left join asset_first_break fb on fb.entity_id = l.entity_id
  ),
  asset_any_qualifying as (
    select entity_id, bool_or(day_total > 10) as has_qualifying_day
    from asset_entity_days
    group by entity_id
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
                  when es.status = 'actioned' then 'actioned'
                  else
                    case when coalesce(ds.streak, 0) >= 3 or coalesce(daq.has_qualifying_day, false)
                         then 'required' else 'ok' end
                end,
      'streakDays', coalesce(ds.streak, 0),
      'recurrenceCount', coalesce(es.recurrence_count, 0),
      'monitorUntil', to_char(es.monitor_until, 'YYYY-MM-DD'),
      'lastAction', case when la.entity_id is null then null else jsonb_build_object(
        'type', la.action_type, 'note', la.note, 'by', la.logged_by,
        'at', to_char(la.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z')
      ) end
    ) as row
    from driver_entities e
    left join driver_names n on n.driver_key = e.entity_id
    left join driver_days_agg dd on dd.entity_id = e.entity_id
    left join driver_streaks ds on ds.entity_id = e.entity_id
    left join driver_any_qualifying daq on daq.entity_id = e.entity_id
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
                  when es.status = 'actioned' then 'actioned'
                  else
                    case when coalesce(ast.streak, 0) >= 3 or coalesce(aaq.has_qualifying_day, false)
                         then 'required' else 'ok' end
                end,
      'streakDays', coalesce(ast.streak, 0),
      'recurrenceCount', coalesce(es.recurrence_count, 0),
      'monitorUntil', to_char(es.monitor_until, 'YYYY-MM-DD'),
      'lastAction', case when la.entity_id is null then null else jsonb_build_object(
        'type', la.action_type, 'note', la.note, 'by', la.logged_by,
        'at', to_char(la.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z')
      ) end
    ) as row
    from asset_entities e
    left join asset_days_agg ad on ad.entity_id = e.entity_id
    left join asset_streaks ast on ast.entity_id = e.entity_id
    left join asset_any_qualifying aaq on aaq.entity_id = e.entity_id
    left join public.entity_status es on es.entity_type = 'asset' and es.entity_id = e.entity_id
    left join last_actions la on la.entity_type = 'asset' and la.entity_id = e.entity_id
  )
  select jsonb_build_object(
    'drivers', coalesce((select jsonb_agg(row) from drivers_out), '[]'::jsonb),
    'assets',  coalesce((select jsonb_agg(row) from assets_out), '[]'::jsonb)
  );
$function$;
