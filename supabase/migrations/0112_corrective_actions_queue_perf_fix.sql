-- ============================================================================
-- DDS — 0112_corrective_actions_queue_perf_fix
-- ----------------------------------------------------------------------------
-- 0111's dds_corrective_actions_queue() timed out (>60s) against live data.
-- Root cause: it called dds_current_streak(type, id, 10, 90) once per
-- currently-open entity to get "Days Open" — each call independently
-- re-scans events and re-runs its own generate_series/ranking from scratch,
-- so N open entities meant N redundant full streak computations on top of
-- the set-based work the function already does for every entity.
--
-- Fix: compute the >10-day streak the same way the >=20 streak already is
-- (driver_ranked/driver_streaks, inline, set-based, one pass) instead of
-- calling dds_current_streak() at all. Two new CTEs per entity type
-- (driver_ranked10/driver_streaks10, asset_ranked10/asset_streaks10)
-- mirror the existing >=20 ones exactly, threshold swapped. No behavior
-- change from 0111 — same fields, same status logic, same output shape —
-- purely a performance fix.
-- ============================================================================
create or replace function public.dds_corrective_actions_queue()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
set work_mem = '64MB'
as $function$
declare
  result jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with driver_entities as (
    select distinct coalesce(emp_no, 'UNSPECIFIED') as entity_id
    from events where shift_date >= current_date - 94
  ),
  asset_entities as (
    select distinct asset_id as entity_id
    from events where shift_date >= current_date - 94
  ),
  driver_last_day as (
    select coalesce(emp_no, 'UNSPECIFIED') as entity_id, max(shift_date) as last_day
    from events
    where coalesce(emp_no, 'UNSPECIFIED') in (
      select entity_id from driver_entities where entity_id <> 'UNSPECIFIED'
    )
    group by coalesce(emp_no, 'UNSPECIFIED')
  ),
  driver_days as (
    select e.driver_key as entity_id, e.shift_date, sum(e.event_count) as day_total
    from (select coalesce(emp_no, 'UNSPECIFIED') as driver_key, shift_date, event_count from events) e
    join driver_last_day l on l.entity_id = e.driver_key
    where e.shift_date >= l.last_day - interval '89 days'
    group by e.driver_key, e.shift_date
  ),
  driver_cal as (
    select l.entity_id, gs.cal_date::date as cal_date
    from driver_last_day l
    cross join lateral generate_series(l.last_day - interval '89 days', l.last_day, interval '1 day') as gs(cal_date)
  ),
  driver_ranked as (
    select cal.entity_id,
           row_number() over (partition by cal.entity_id order by cal.cal_date desc) as rn,
           (coalesce(dd.day_total, 0) >= 20) as qualifies
    from driver_cal cal
    left join driver_days dd on dd.entity_id = cal.entity_id and dd.shift_date = cal.cal_date
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
    from driver_last_day l
    left join driver_first_break fb on fb.entity_id = l.entity_id
  ),
  driver_ranked10 as (
    select cal.entity_id,
           row_number() over (partition by cal.entity_id order by cal.cal_date desc) as rn,
           (coalesce(dd.day_total, 0) > 10) as qualifies
    from driver_cal cal
    left join driver_days dd on dd.entity_id = cal.entity_id and dd.shift_date = cal.cal_date
  ),
  driver_first_break10 as (
    select entity_id, min(rn) as rn from driver_ranked10 where not qualifies group by entity_id
  ),
  driver_streaks10 as (
    select l.entity_id,
      coalesce(
        case when fb.rn is null then (select count(*) from driver_ranked10 r where r.entity_id = l.entity_id)
        else fb.rn - 1 end, 0
      ) as streak
    from driver_last_day l
    left join driver_first_break10 fb on fb.entity_id = l.entity_id
  ),
  driver_latest_day_total as (
    select ed.entity_id, ed.day_total
    from driver_days ed
    join driver_last_day l on l.entity_id = ed.entity_id and ed.shift_date = l.last_day
  ),
  asset_last_day as (
    select asset_id as entity_id, max(shift_date) as last_day
    from events
    where asset_id in (select entity_id from asset_entities)
    group by asset_id
  ),
  asset_days as (
    select e.asset_id as entity_id, e.shift_date, sum(e.event_count) as day_total
    from events e
    join asset_last_day l on l.entity_id = e.asset_id
    where e.shift_date >= l.last_day - interval '89 days'
    group by e.asset_id, e.shift_date
  ),
  asset_cal as (
    select l.entity_id, gs.cal_date::date as cal_date
    from asset_last_day l
    cross join lateral generate_series(l.last_day - interval '89 days', l.last_day, interval '1 day') as gs(cal_date)
  ),
  asset_ranked as (
    select cal.entity_id,
           row_number() over (partition by cal.entity_id order by cal.cal_date desc) as rn,
           (coalesce(ad.day_total, 0) >= 20) as qualifies
    from asset_cal cal
    left join asset_days ad on ad.entity_id = cal.entity_id and ad.shift_date = cal.cal_date
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
    from asset_last_day l
    left join asset_first_break fb on fb.entity_id = l.entity_id
  ),
  asset_ranked10 as (
    select cal.entity_id,
           row_number() over (partition by cal.entity_id order by cal.cal_date desc) as rn,
           (coalesce(ad.day_total, 0) > 10) as qualifies
    from asset_cal cal
    left join asset_days ad on ad.entity_id = cal.entity_id and ad.shift_date = cal.cal_date
  ),
  asset_first_break10 as (
    select entity_id, min(rn) as rn from asset_ranked10 where not qualifies group by entity_id
  ),
  asset_streaks10 as (
    select l.entity_id,
      coalesce(
        case when fb.rn is null then (select count(*) from asset_ranked10 r where r.entity_id = l.entity_id)
        else fb.rn - 1 end, 0
      ) as streak
    from asset_last_day l
    left join asset_first_break10 fb on fb.entity_id = l.entity_id
  ),
  asset_latest_day_total as (
    select ad.entity_id, ad.day_total
    from asset_days ad
    join asset_last_day l on l.entity_id = ad.entity_id and ad.shift_date = l.last_day
  ),
  driver_names as (
    select coalesce(d.full_name, e.entity_id) as name, e.entity_id as driver_key
    from driver_entities e
    left join drivers d on d.emp_no = e.entity_id
  ),
  last_actions as (
    select distinct on (entity_type, entity_id)
      entity_type, entity_id, action_type, action_other_text, note, logged_by, created_at
    from entity_action_log
    order by entity_type, entity_id, created_at desc
  ),
  all_status as (
    select 'driver' as entity_type, e.entity_id,
      case when e.entity_id = 'UNSPECIFIED' then 'Unspecified' else n.name end as name,
      l.last_day,
      case
        when es.status = 'monitoring' then
          case when es.monitor_until is not null and es.monitor_until >= current_date
               then 'monitoring' else 'resolved' end
        when es.status = 'actioned' then 'actioned'
        else case when coalesce(ds.streak, 0) >= 3 or coalesce(dlt.day_total, 0) > 10
                   then 'required' else 'ok' end
      end as status,
      coalesce(ds10.streak, 0) as days_open,
      es.updated_at,
      la.action_type, la.action_other_text, la.note, la.logged_by, la.created_at as action_at
    from driver_entities e
    left join driver_names n on n.driver_key = e.entity_id
    left join driver_last_day l on l.entity_id = e.entity_id
    left join driver_streaks ds on ds.entity_id = e.entity_id
    left join driver_streaks10 ds10 on ds10.entity_id = e.entity_id
    left join driver_latest_day_total dlt on dlt.entity_id = e.entity_id
    left join entity_status es on es.entity_type = 'driver' and es.entity_id = e.entity_id
    left join last_actions la on la.entity_type = 'driver' and la.entity_id = e.entity_id
    union all
    select 'asset' as entity_type, e.entity_id, e.entity_id as name,
      l.last_day,
      case
        when es.status = 'monitoring' then
          case when es.monitor_until is not null and es.monitor_until >= current_date
               then 'monitoring' else 'resolved' end
        when es.status = 'actioned' then 'actioned'
        else case when coalesce(ast.streak, 0) >= 3 or coalesce(alt.day_total, 0) > 10
                   then 'required' else 'ok' end
      end as status,
      coalesce(ast10.streak, 0) as days_open,
      es.updated_at,
      la.action_type, la.action_other_text, la.note, la.logged_by, la.created_at as action_at
    from asset_entities e
    left join asset_last_day l on l.entity_id = e.entity_id
    left join asset_streaks ast on ast.entity_id = e.entity_id
    left join asset_streaks10 ast10 on ast10.entity_id = e.entity_id
    left join asset_latest_day_total alt on alt.entity_id = e.entity_id
    left join entity_status es on es.entity_type = 'asset' and es.entity_id = e.entity_id
    left join last_actions la on la.entity_type = 'asset' and la.entity_id = e.entity_id
  ),
  open_cases as (
    select * from all_status where status = 'required'
  ),
  open_cases_totaled as (
    select oc.*,
      (oc.last_day - (oc.days_open - 1)) as flagged_since,
      coalesce((
        select sum(dd.day_total) from driver_days dd
        where oc.entity_type = 'driver' and dd.entity_id = oc.entity_id
          and dd.shift_date >= (oc.last_day - (oc.days_open - 1))
      ), (
        select sum(ad.day_total) from asset_days ad
        where oc.entity_type = 'asset' and ad.entity_id = oc.entity_id
          and ad.shift_date >= (oc.last_day - (oc.days_open - 1))
      )) as event_count
    from open_cases oc
  ),
  closed_cases as (
    select * from all_status
    where status in ('actioned', 'resolved') and action_at is not null
    order by updated_at desc nulls last
    limit 20
  )
  select jsonb_build_object(
    'generatedAt', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'open', coalesce((
      select jsonb_agg(jsonb_build_object(
        'entityType', entity_type,
        'entityId', entity_id,
        'name', name,
        'flaggedSince', to_char(flagged_since, 'YYYY-MM-DD'),
        'daysOpen', days_open,
        'eventCount', coalesce(event_count, 0),
        'status', 'Open'
      ) order by days_open desc, event_count desc nulls last)
      from open_cases_totaled
    ), '[]'::jsonb),
    'recentlyClosed', coalesce((
      select jsonb_agg(jsonb_build_object(
        'entityType', entity_type,
        'entityId', entity_id,
        'name', name,
        'actionPerformed', case when action_type = 'Other' then coalesce(action_other_text, 'Other') else action_type end,
        'actionDate', to_char(action_at at time zone 'utc', 'YYYY-MM-DD'),
        'actionBy', logged_by,
        'status', case when status = 'monitoring' then 'Monitoring' else 'Closed' end
      ) order by action_at desc)
      from closed_cases
    ), '[]'::jsonb)
  )
  into result;

  return result;
end;
$function$;
