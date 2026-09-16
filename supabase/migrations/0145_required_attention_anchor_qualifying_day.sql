-- ============================================================================
-- DDS — 0145_required_attention_anchor_qualifying_day
-- ----------------------------------------------------------------------------
-- Investigated a live report: DT-689 was not showing in Overview's "Required
-- Attention" table despite a real, severe spike (192 alerts across one
-- NIGHT shift, 2026-09-11 to 09-12, driver 9701176). Root cause confirmed
-- live: dds_required_attention() (0117) anchors its entire computation
-- (the qualifying gate, the streak, the flagged-since date, the unit lookup)
-- on driver_last_day — the driver's single most recent ACTIVE day within
-- the window, whatever its count. If that most recent day happens to be
-- quiet (here: 4 alerts on 09-14, two days after the 192-alert spike), the
-- driver fails the "> 10" gate and is dropped entirely — the severe day
-- itself is never looked at, because nothing anchors to it.
--
-- This is the exact same class of bug 0130_driver_streaks_persistent_flag_
-- until_closed.sql already corrected for dds_driver_streaks(), "per
-- explicit correction": a flagged streak must not auto-clear just because
-- the driver has since had clean days. dds_required_attention() was never
-- updated to match when 0130 shipped — it still silently clears (worse:
-- never even surfaces) a real incident the moment a quieter day follows it
-- within the same review window.
--
-- Fix: anchor driver_last_day on the driver's most recent QUALIFYING day
-- (day_total > 10) within the window, not their most recent active day of
-- any size. Every downstream computation (the 90-day streak lookback,
-- flagged_since, the window/unit totals) already reads from driver_last_day
-- unchanged, so this one CTE is the whole fix. A driver whose most recent
-- active day already IS their qualifying day (the common case) sees no
-- change; a driver whose alert activity already cooled down by the end of
-- the window now correctly stays flagged based on when the incident
-- actually happened, same "nothing clears itself without a human" rule
-- 0130 already established elsewhere in this exact pipeline.
-- ============================================================================
create or replace function public.dds_required_attention(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
set work_mem = '64MB'
as $function$
declare
  result jsonb;
  v_from date := coalesce(p_from, current_date - 6);
  v_to   date := coalesce(p_to, current_date);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with driver_entities as (
    select distinct emp_no as entity_id
    from events
    where emp_no is not null and shift_date >= v_from and shift_date <= v_to
  ),
  driver_last_day as (
    -- Most recent QUALIFYING day (day_total > 10) within the window — not
    -- simply the most recent day with any activity at all (see header).
    select entity_id, max(shift_date) as last_day
    from (
      select emp_no as entity_id, shift_date, sum(event_count) as day_total
      from events
      where emp_no is not null and shift_date >= v_from and shift_date <= v_to
      group by emp_no, shift_date
    ) x
    where day_total > 10
    group by entity_id
  ),
  driver_days as (
    select e.entity_id, ev.shift_date, sum(ev.event_count) as day_total
    from driver_last_day e
    join events ev on ev.emp_no = e.entity_id
    where ev.shift_date >= e.last_day - interval '89 days'
      and ev.shift_date <= e.last_day
    group by e.entity_id, ev.shift_date
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
  driver_streak20 as (
    select l.entity_id,
      coalesce(
        case when fb.rn is null then (select count(*) from driver_ranked r where r.entity_id = l.entity_id)
        else fb.rn - 1 end, 0
      ) as streak
    from driver_last_day l
    left join driver_first_break fb on fb.entity_id = l.entity_id
  ),
  driver_latest_day_total as (
    select ed.entity_id, ed.day_total
    from driver_days ed
    join driver_last_day l on l.entity_id = ed.entity_id and ed.shift_date = l.last_day
  ),
  driver_names as (
    select coalesce(d.full_name, e.entity_id) as name, e.entity_id
    from driver_entities e
    left join drivers d on d.emp_no = e.entity_id
  ),
  flagged as (
    select
      e.entity_id as emp_no,
      n.name,
      l.last_day,
      coalesce(dlt.day_total, 0) as latest_day_total,
      coalesce(ds.streak, 0) as streak20,
      greatest(coalesce(ds.streak, 0), 1) as streak_days,
      (l.last_day - (greatest(coalesce(ds.streak, 0), 1) - 1)::int) as flagged_since,
      case when coalesce(ds.streak, 0) >= 2 then 'critical' else 'high' end as severity,
      case
        when es.status = 'monitoring' then
          case when es.monitor_until is not null and es.monitor_until >= current_date
               then 'monitoring' else 'resolved' end
        when es.status = 'actioned' then 'actioned'
        else 'required'
      end as derived_status
    from driver_entities e
    left join driver_names n on n.entity_id = e.entity_id
    left join driver_last_day l on l.entity_id = e.entity_id
    left join driver_streak20 ds on ds.entity_id = e.entity_id
    left join driver_latest_day_total dlt on dlt.entity_id = e.entity_id
    left join entity_status es on es.entity_type = 'driver' and es.entity_id = e.entity_id
    where coalesce(dlt.day_total, 0) > 10
  ),
  flagged_open as (
    select * from flagged where derived_status not in ('actioned', 'resolved')
  ),
  flagged_totaled as (
    select fo.*,
      (select sum(dd.day_total) from driver_days dd
        where dd.entity_id = fo.emp_no and dd.shift_date >= fo.flagged_since and dd.shift_date <= fo.last_day
      ) as window_total,
      (select at2.asset_id from (
         select ev.asset_id, sum(ev.event_count) as total
         from events ev
         where ev.emp_no = fo.emp_no and ev.asset_id is not null
           and ev.shift_date >= fo.flagged_since and ev.shift_date <= fo.last_day
         group by ev.asset_id
         order by total desc, ev.asset_id
         limit 1
       ) at2
      ) as unit
    from flagged_open fo
  )
  select jsonb_build_object(
    'generatedAt', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'empNo', emp_no,
        'name', name,
        'unit', unit,
        'severity', severity,
        'flaggedSince', to_char(flagged_since, 'YYYY-MM-DD'),
        'streakDays', streak_days,
        'totalCount', coalesce(window_total, 0),
        'avgCount', round(coalesce(window_total, 0)::numeric / greatest(streak_days, 1), 1)
      ) order by (severity = 'critical') desc, streak_days desc, window_total desc nulls last)
      from flagged_totaled
    ), '[]'::jsonb)
  )
  into result;

  return result;
end;
$function$;
