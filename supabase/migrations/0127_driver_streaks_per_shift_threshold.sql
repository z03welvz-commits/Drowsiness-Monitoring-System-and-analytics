-- ============================================================================
-- DDS — 0127_driver_streaks_per_shift_threshold
-- ----------------------------------------------------------------------------
-- Per direct instruction, Driver Streaks' definition of a "flagged" day is
-- corrected to exactly two criteria, evaluated independently:
--   (a) any single events row for the day has event_count > 10 (an acute
--       single entry, regardless of which shift it's on), OR
--   (b) the SAME date+shift combination's event_count sums to > 20 (strict,
--       not >= 20).
--
-- Two bugs this fixes:
-- 1. "day_total >= 20" pooled DAY and NIGHT together before comparing, so a
--    date with e.g. DAY=12 and NIGHT=12 (24 pooled) qualified even though
--    neither shift alone was concerning, while a genuinely severe single
--    shift could be diluted by a quiet other shift on the same calendar
--    date. The qualifying test now runs per (shift_date, shift): a date
--    qualifies if ANY one shift on it exceeds 20 on its own.
-- 2. The bound was ">=20"; per explicit correction it must be "> 20" (a day
--    at exactly 20 is not flagged) — same tightening applies to the
--    required-status acute-day check, which is now a literal event_count>10
--    on an individual row rather than a pooled day total (a single logged
--    entry of 11 is acute; two separate entries of 6 each on the same day
--    are not, until their shift sum itself passes 20).
--
-- Scope, per explicit instruction: Driver Streaks only for now. This is a
-- DELIBERATE, temporary divergence from dds_corrective_actions_queue() /
-- dds_required_attention() / dds_driver_asset_weekly(), which still pool
-- by calendar date alone and use >=20 / >10 — the same kind of
-- cross-page mismatch 0124 fixed once already. Do not "helpfully" apply
-- this to those other three without asking again; a follow-up migration is
-- expected to unify all four once this definition is confirmed live here.
--
-- Streak Days/Streak Count, Total Count, Avg Count, Peak Count/Date still
-- use the plain pooled per-calendar-day total for DISPLAY (they describe
-- "how many alerts", not "is this concerning") — only the gate that decides
-- which days build a streak, and the required-status acute-day check,
-- change.
-- ============================================================================
create or replace function public.dds_driver_streaks(
  p_search     text default null,
  p_min_streak integer default 1,
  p_sort       text default 'streak_days',
  p_dir        text default 'desc',
  p_limit      integer default 50,
  p_offset     integer default 0,
  p_window_days integer default null,
  p_shift      text default null,
  p_asset      text default null,
  p_status     text default null,
  p_from       date default null,
  p_to         date default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_sort   text := case when p_sort in ('streak_days','run_total_count','emp_no','name','run_end','status_priority')
                        then p_sort else 'streak_days' end;
  v_dir    text := case when lower(coalesce(p_dir,'desc')) = 'asc' then 'asc' else 'desc' end;
  v_result jsonb;
  v_total  integer;
  v_open   integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  create temporary table _driver_streak_rows on commit drop as
  with daily as (
    select emp_no, shift_date, sum(event_count) as day_total
    from public.events
    where emp_no is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
    group by emp_no, shift_date
  ),
  shift_daily as (
    -- Same (date+shift) grain the "daily count" criterion is defined on —
    -- deliberately NOT pooled with the other shift on the same date.
    select emp_no, shift_date, shift, sum(event_count) as shift_total
    from public.events
    where emp_no is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
    group by emp_no, shift_date, shift
  ),
  qualifying_days as (
    -- A calendar day qualifies (builds/extends a streak) if either
    -- criterion holds for it, on either shift: a single event_count>10
    -- entry, or a per-shift daily sum >20 (strict).
    select distinct emp_no, shift_date
    from public.events
    where emp_no is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
      and event_count > 10
    union
    select emp_no, shift_date
    from shift_daily
    where shift_total > 20
  ),
  qualifying as (
    select emp_no, shift_date,
           shift_date - (row_number() over (partition by emp_no order by shift_date))::int as grp
    from qualifying_days
  ),
  runs as (
    select emp_no, min(shift_date) as run_start, max(shift_date) as run_end, count(*) as run_len
    from qualifying
    group by emp_no, grp
  ),
  run_counts as (
    select emp_no, count(*) as streak_count
    from runs
    group by emp_no
  ),
  latest_run as (
    select distinct on (emp_no) emp_no, run_start, run_end, run_len
    from runs
    order by emp_no, run_end desc
  ),
  driver_last_activity as (
    select emp_no, max(shift_date) as last_activity
    from daily
    group by emp_no
  ),
  last_activity_acute as (
    -- The required-status acute-day check: does the driver's most recent
    -- active day contain a single event_count>10 row, on any shift?
    select dla.emp_no, bool_or(ev.event_count > 10) as acute
    from driver_last_activity dla
    join public.events ev on ev.emp_no = dla.emp_no and ev.shift_date = dla.last_activity
    group by dla.emp_no
  ),
  run_span_totals as (
    select lr.emp_no,
      sum(d.event_count) as run_total_count
    from latest_run lr
    join public.events d on d.emp_no = lr.emp_no
      and d.shift_date >= lr.run_start and d.shift_date <= lr.run_end
    group by lr.emp_no
  ),
  run_peak_days as (
    select distinct on (lr.emp_no) lr.emp_no, dl.shift_date as peak_date, dl.day_total as peak_count
    from latest_run lr
    join daily dl on dl.emp_no = lr.emp_no
      and dl.shift_date >= lr.run_start and dl.shift_date <= lr.run_end
    order by lr.emp_no, dl.day_total desc, dl.shift_date asc
  ),
  run_shift_counts as (
    select lr.emp_no,
      count(*) filter (where ev.shift = 'NIGHT') as night_n,
      count(*) filter (where ev.shift = 'DAY') as day_n
    from latest_run lr
    join public.events ev on ev.emp_no = lr.emp_no
      and ev.shift_date >= lr.run_start and ev.shift_date <= lr.run_end
    group by lr.emp_no
  ),
  totals as (
    select emp_no, sum(event_count) as total_count
    from public.events
    where emp_no is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
    group by emp_no
  ),
  severity_totals as (
    select emp_no,
      coalesce(sum(event_count) filter (where event_code ilike '%sleep%'), 0)
        + coalesce(sum(event_count) filter (where event_code ilike '%drowsi%' and event_code not ilike '%sleep%'), 0)
        as high_alerts
    from public.events
    where emp_no is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
    group by emp_no
  ),
  asset_totals as (
    select emp_no, asset_id, sum(event_count) as asset_total
    from public.events
    where emp_no is not null and asset_id is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
    group by emp_no, asset_id
  ),
  primary_asset as (
    select distinct on (emp_no) emp_no, asset_id
    from asset_totals
    order by emp_no, asset_total desc, asset_id
  ),
  last_actions as (
    select distinct on (entity_id)
      entity_id, action_type, note, logged_by, created_at
    from public.entity_action_log
    where entity_type = 'driver'
    order by entity_id, created_at desc
  )
  select
    lr.emp_no,
    coalesce(d.full_name, lr.emp_no) as name,
    lr.run_start, lr.run_end, lr.run_len as streak_days,
    coalesce(rc.streak_count, 1) as streak_count,
    coalesce(t.total_count, 0) as total_count,
    coalesce(rst.run_total_count, 0) as run_total_count,
    round(coalesce(rst.run_total_count, 0)::numeric / greatest(lr.run_len, 1), 1) as avg_count,
    rpd.peak_count, rpd.peak_date,
    coalesce(st.high_alerts, 0) as high_alerts,
    pa.asset_id as primary_asset,
    case when coalesce(rsc.night_n, 0) > coalesce(rsc.day_n, 0) then 'NIGHT' else 'DAY' end as dominant_shift,
    case
      when es.status = 'monitoring' then
        case when es.monitor_until is not null and es.monitor_until >= current_date
             then 'monitoring' else 'resolved' end
      when es.status = 'actioned' then 'actioned'
      when (case when lr.run_end = coalesce(dla.last_activity, lr.run_end) then lr.run_len else 0 end) >= 3
           or coalesce(laa.acute, false)
      then 'required'
      else 'ok'
    end as status,
    -- Numeric mirror of the status CASE above (can't reference that alias
    -- from within the same SELECT list) so the default sort can put
    -- required rows first without a second client round-trip: required=0,
    -- an active monitoring window=1, actioned=2, an expired monitoring
    -- window (genuinely 'resolved')=3, not-currently-required ('ok')=4.
    case
      when es.status = 'monitoring' then
        case when es.monitor_until is not null and es.monitor_until >= current_date
             then 1 else 3 end
      when es.status = 'actioned' then 2
      when (case when lr.run_end = coalesce(dla.last_activity, lr.run_end) then lr.run_len else 0 end) >= 3
           or coalesce(laa.acute, false)
      then 0
      else 4
    end as status_priority,
    es.monitor_until,
    la.action_type as last_action_type,
    la.note as last_action_note,
    la.logged_by as last_action_by,
    la.created_at as last_action_at
  from latest_run lr
  left join public.drivers d on d.emp_no = lr.emp_no
  left join run_counts rc on rc.emp_no = lr.emp_no
  left join totals t on t.emp_no = lr.emp_no
  left join run_span_totals rst on rst.emp_no = lr.emp_no
  left join run_peak_days rpd on rpd.emp_no = lr.emp_no
  left join run_shift_counts rsc on rsc.emp_no = lr.emp_no
  left join severity_totals st on st.emp_no = lr.emp_no
  left join primary_asset pa on pa.emp_no = lr.emp_no
  left join driver_last_activity dla on dla.emp_no = lr.emp_no
  left join last_activity_acute laa on laa.emp_no = lr.emp_no
  left join public.entity_status es on es.entity_type = 'driver' and es.entity_id = lr.emp_no
  left join last_actions la on la.entity_id = lr.emp_no
  where lr.run_len >= greatest(coalesce(p_min_streak, 1), 1)
    and (
      p_search is null or p_search = ''
      or lr.emp_no ilike '%' || p_search || '%'
      or coalesce(d.full_name, '') ilike '%' || p_search || '%'
    )
    and (
      p_shift is null or p_shift = ''
      or (case when coalesce(rsc.night_n, 0) > coalesce(rsc.day_n, 0) then 'NIGHT' else 'DAY' end) = upper(p_shift)
    )
    and (p_asset is null or p_asset = '' or pa.asset_id = p_asset)
    and (
      p_status is null or p_status = ''
      or (
        case
          when es.status = 'monitoring' then
            case when es.monitor_until is not null and es.monitor_until >= current_date
                 then 'monitoring' else 'resolved' end
          when es.status = 'actioned' then 'actioned'
          when (case when lr.run_end = coalesce(dla.last_activity, lr.run_end) then lr.run_len else 0 end) >= 3
               or coalesce(laa.acute, false)
          then 'required'
          else 'ok'
        end
      ) = p_status
    )
    and (p_from is null or lr.run_end >= p_from)
    and (p_to is null or lr.run_start <= p_to);

  select count(*) into v_total from _driver_streak_rows;
  select count(*) into v_open from _driver_streak_rows where status = 'required';

  execute format(
    'select jsonb_agg(jsonb_build_object(
       ''empNo'', emp_no, ''name'', name,
       ''streakDays'', streak_days,
       ''streakCount'', streak_count,
       ''runStart'', to_char(run_start, ''MM/DD/YYYY''),
       ''runEnd'', to_char(run_end, ''MM/DD/YYYY''),
       ''totalCount'', total_count,
       ''runTotalCount'', run_total_count,
       ''avgCount'', avg_count,
       ''peakCount'', peak_count,
       ''peakDate'', to_char(peak_date, ''MM/DD/YYYY''),
       ''highAlerts'', high_alerts,
       ''unit'', primary_asset,
       ''dominantShift'', dominant_shift,
       ''status'', status,
       ''monitorUntil'', to_char(monitor_until, ''YYYY-MM-DD''),
       ''lastAction'', case when last_action_type is null then null else jsonb_build_object(
         ''type'', last_action_type, ''note'', last_action_note, ''by'', last_action_by,
         ''at'', to_char(last_action_at at time zone ''utc'', ''YYYY-MM-DD"T"HH24:MI:SS.MS"Z'')
       ) end
     ))
     -- streak_days desc, run_end desc always break ties after whatever the
     -- caller actually asked to sort by — harmless (a no-op) when the
     -- primary sort already is streak_days, and keeps a stable, sensible
     -- order (longest/most-recent first) when the primary sort is
     -- status_priority (the default) or any other column with lots of ties.
     from (select * from _driver_streak_rows order by %I %s, streak_days desc, run_end desc limit %s offset %s) s',
    v_sort, v_dir, v_limit, v_offset
  ) into v_result;

  return jsonb_build_object(
    'rows', coalesce(v_result, '[]'::jsonb),
    'total', v_total,
    'openCount', v_open
  );
end;
$function$;
