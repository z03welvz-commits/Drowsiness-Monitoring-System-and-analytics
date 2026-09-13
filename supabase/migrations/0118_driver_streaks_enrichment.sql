-- ============================================================================
-- DDS — 0118_driver_streaks_enrichment
-- ----------------------------------------------------------------------------
-- Adds fields + filters the redesigned Driver Streaks table needs, on top of
-- the live dds_driver_streaks() definition (which already carries
-- highAlerts/unit from a since-reverted migration file — the live function
-- was deliberately left in place when that revert shipped, since nothing
-- broke by their presence; this migration is additive on top of that live
-- state, not the older file-only version).
--
-- New fields, all scoped to the entity's CURRENT/most-recent qualifying run
-- (run_start..run_end), not their all-time history — the table's new
-- Description column explains THIS flag, so its numbers should describe
-- the same span:
--   - streakCount: how many separate qualifying runs (>=1 day at >=20/day)
--     this driver has ever had, lifetime (or within p_window_days when
--     set) — distinct from streakDays, which is just the length of the
--     latest run.
--   - peakCount / peakDate: the single highest day_total within the current
--     run, and which day it fell on — feeds the Description text for a
--     1-day (High) flag ("observed N alerts in one day on <peakDate>").
--   - runTotalCount / avgCount: sum(event_count) over the current run's own
--     date range, and that total divided by streakDays. The existing
--     totalCount field (all-time / p_window_days total) is left untouched
--     so nothing that already reads it changes meaning; the UI redesign
--     displays runTotalCount as "Total Count" instead, since it is what
--     the flag itself is about.
--   - dominantShift: DAY or NIGHT, whichever shift most of the run's own
--     events fell on — feeds the new Shift filter.
--
-- New filter params: p_shift (matches dominantShift), p_asset (matches the
-- run's primary asset/unit), p_status (matches the same derived status
-- string already returned) — all additive, all default null (no filter),
-- so every existing caller keeps working unchanged.
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
  p_status     text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_limit  integer := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_sort   text := case when p_sort in ('streak_days','run_total_count','emp_no','name','run_end')
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
  qualifying as (
    select emp_no, shift_date,
           shift_date - (row_number() over (partition by emp_no order by shift_date))::int as grp
    from daily
    where day_total >= 20
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
      else
        case when lr.run_len >= 3 then 'required' else 'ok' end
    end as status,
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
          else case when lr.run_len >= 3 then 'required' else 'ok' end
        end
      ) = p_status
    );

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
     from (select * from _driver_streak_rows order by %I %s limit %s offset %s) s',
    v_sort, v_dir, v_limit, v_offset
  ) into v_result;

  return jsonb_build_object(
    'rows', coalesce(v_result, '[]'::jsonb),
    'total', v_total,
    'openCount', v_open
  );
end;
$function$;
