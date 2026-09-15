-- ============================================================================
-- DDS — 0136_driver_asset_weekly_narrow_qualifying_window
-- ----------------------------------------------------------------------------
-- Follow-up to 0135. That fix correctly made DT-689-style spikes visible to
-- "required" by checking ANY day in the existing 90-day streak-lookback
-- window instead of only the single latest day — but scanning the FULL
-- 90 days for a single qualifying day (day_total > 10) turned out to flag
-- almost the entire fleet as a live-data check right after deploying 0135:
-- 86/87 assets and 34/45 drivers came back 'required', versus 18/19 and 7
-- under the old (broken) latest-day-only rule for the same entities. A
-- >10-alert day happening at least once somewhere in 90 days is common
-- enough that the flag stopped being a useful "needs attention now" signal.
--
-- Per explicit decision: narrow the qualifying-day scan from 90 days to a
-- 7-day window (matching this page's own default date-filter range),
-- while leaving the pre-existing 3+ consecutive-day streak logic (already
-- scoped to the 90-day window, unchanged, not part of this audit) alone.
-- A qualifying day still PERSISTS the 'required' flag until a human closes
-- it via entity_status (0135's actual fix, unchanged) — this migration only
-- narrows how far back a NEW qualifying day is allowed to come from before
-- it can trigger that persistent flag in the first place.
--
-- driver_any_qualifying / asset_any_qualifying now also join back to
-- *_entity_last_day to bound the scan to [last_day - 6 days, last_day],
-- instead of scanning the full *_entity_days CTE (already 90-day bounded
-- for the streak calc) unfiltered.
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
    select ed.entity_id, bool_or(ed.day_total > 10) as has_qualifying_day
    from driver_entity_days ed
    join driver_entity_last_day l on l.entity_id = ed.entity_id
    where ed.shift_date >= l.last_day - interval '6 days'
    group by ed.entity_id
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
    select ed.entity_id, bool_or(ed.day_total > 10) as has_qualifying_day
    from asset_entity_days ed
    join asset_entity_last_day l on l.entity_id = ed.entity_id
    where ed.shift_date >= l.last_day - interval '6 days'
    group by ed.entity_id
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
