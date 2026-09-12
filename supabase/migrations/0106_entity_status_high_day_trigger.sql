-- ============================================================================
-- DDS — 0106_entity_status_high_day_trigger
-- ----------------------------------------------------------------------------
-- Adds a second, independent flagging condition alongside the existing
-- streak rule, per explicit instruction: a single day whose summed
-- event_count exceeds 10 should flag a driver/asset immediately, without
-- waiting for a 3-consecutive-day streak of day_total >= 20 to build up.
-- These are kept as two distinct, OR'd signals (a sudden one-day spike vs.
-- a sustained pattern) rather than folded into one formula, since they
-- answer different questions and the existing streak rule
-- (dds_current_streak() / dds_driver_asset_weekly() / the reopen trigger,
-- all sharing "day_total >= 20") stays completely unchanged.
--
-- The >10 threshold reuses this codebase's own existing precedent
-- (v_high_day_threshold := 10 in index.html/applySeverity()'s older
-- per-day-ratio system — "a day is high if that day's summed event_count
-- > 10") rather than inventing a new number, and is checked against the
-- same summed-per-shift_date day_total the streak rule already computes,
-- not a single events row's raw event_count.
--
-- Two call sites updated for consistency (a single-day spike should reopen
-- an already-actioned entity exactly as readily as it flags a fresh one):
--
-- 1. dds_driver_asset_weekly() — 'required' now also fires when ANY day in
--    the entity's existing 90-day lookback window has day_total > 10, in
--    addition to the existing streak >= 3 check. Computed from the
--    already-materialized driver_entity_days/asset_entity_days CTEs — no
--    new joins.
-- 2. dds_entity_status_reopen() — the trigger (fires on every events
--    insert) now also reopens an actioned/monitoring entity when the
--    JUST-INSERTED row's shift_date has a day_total > 10, alongside the
--    existing streak >= 3 check. recurrence_count increments either way,
--    matching 0086's existing "same signal regardless of reopen reason"
--    rationale.
-- ============================================================================

create or replace function public.dds_driver_asset_weekly(
  p_from date default null,
  p_to date default null
)
returns jsonb
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
  driver_has_high_day as (
    select entity_id, bool_or(day_total > 10) as has_high_day
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
  asset_has_high_day as (
    select entity_id, bool_or(day_total > 10) as has_high_day
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
                    case when coalesce(ds.streak, 0) >= 3 or coalesce(dhh.has_high_day, false)
                         then 'required' else 'ok' end
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
    left join driver_has_high_day dhh on dhh.entity_id = e.entity_id
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
                    case when coalesce(ast.streak, 0) >= 3 or coalesce(ahh.has_high_day, false)
                         then 'required' else 'ok' end
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
    left join asset_has_high_day ahh on ahh.entity_id = e.entity_id
    left join public.entity_status es on es.entity_type = 'asset' and es.entity_id = e.entity_id
    left join last_actions la on la.entity_type = 'asset' and la.entity_id = e.entity_id
  )
  select jsonb_build_object(
    'drivers', coalesce((select jsonb_agg(row) from drivers_out), '[]'::jsonb),
    'assets',  coalesce((select jsonb_agg(row) from assets_out), '[]'::jsonb)
  );
$$;

create or replace function public.dds_entity_status_reopen()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_asset_id text;
  v_driver_key text;
  v_streak int;
  v_status text;
  v_day_total int;
begin
  v_asset_id := new.asset_id;
  if v_asset_id is not null then
    select status into v_status from public.entity_status
      where entity_type = 'asset' and entity_id = v_asset_id and status in ('monitoring', 'actioned');
    if v_status is not null then
      v_streak := public.dds_current_streak('asset', v_asset_id);
      select coalesce(sum(event_count), 0) into v_day_total
        from public.events where asset_id = v_asset_id and shift_date = new.shift_date;
      if v_streak >= 3 or v_day_total > 10 then
        update public.entity_status
          set status = 'required',
              monitor_until = null,
              recurrence_count = recurrence_count + 1,
              updated_at = now(),
              updated_by = null
          where entity_type = 'asset' and entity_id = v_asset_id and status = v_status;
      end if;
    end if;
  end if;

  v_driver_key := coalesce(new.emp_no, 'UNSPECIFIED');
  select status into v_status from public.entity_status
    where entity_type = 'driver' and entity_id = v_driver_key and status in ('monitoring', 'actioned');
  if v_status is not null then
    v_streak := public.dds_current_streak('driver', v_driver_key);
    select coalesce(sum(event_count), 0) into v_day_total
      from public.events where coalesce(emp_no, 'UNSPECIFIED') = v_driver_key and shift_date = new.shift_date;
    if v_streak >= 3 or v_day_total > 10 then
      update public.entity_status
        set status = 'required',
            monitor_until = null,
            recurrence_count = recurrence_count + 1,
            updated_at = now(),
            updated_by = null
        where entity_type = 'driver' and entity_id = v_driver_key and status = v_status;
    end if;
  end if;

  return new;
end;
$$;
