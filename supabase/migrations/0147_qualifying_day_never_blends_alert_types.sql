-- ============================================================================
-- DDS — 0147_qualifying_day_never_blends_alert_types
-- ----------------------------------------------------------------------------
-- Per direct clarification, with worked examples, of the canonical flagging
-- rule: a driver's day qualifies when EITHER a single event's event_count
-- > 10, OR the SUM of event_count for that driver, that shift instance
-- (shift_date + shift, never a naive raw-calendar-date), for ONE alert TYPE
-- (event_code), exceeds 20. Both dds_required_attention() (0117/0145) and
-- dds_driver_streaks() (0146) already correctly key on (emp_no, shift_date)
-- — which already handles the "same raw calendar date, different shift
-- instance" case correctly, since shift_date/shift are the DERIVED columns
-- (05:21-17:20:59 boundary, pre-05:21 rolls back a day), never the literal
-- timestamp's calendar date. Verified directly: an 11-count Sleep alert at
-- 2026-09-15 02:21 (shift_date=09-14 NIGHT) and a 1-count Sleep alert at
-- 2026-09-15 19:02 (shift_date=09-15 NIGHT) land in different buckets and
-- are never summed to 12, even though both raw timestamps read "09-15".
--
-- What NEITHER function did correctly: their day-total sums grouped by
-- (emp_no, shift_date) alone, blending every alert TYPE together. 10 Sleep
-- + 3 Drowsiness on the same shift is not a real 13-alert day for threshold
-- purposes — each type must be judged on its own sum. Verified directly:
-- a day with 10 Sleep + 3 Drowsiness must NOT flag (neither type's own sum
-- crosses either bar), while 7+3+5=15 Sleep alerts across three events in
-- the same shift instance correctly consolidates to one 15-count Sleep
-- total (below the 20 bar, correctly not flagged either).
--
-- Fix: every day-total computation feeding a qualifying/threshold decision
-- in both functions now groups by event_code too, and a day/shift instance
-- qualifies if ANY SINGLE event_code's sum crosses the bar — never a sum
-- across types. Purely informational/display totals (dds_driver_streaks()'s
-- peak-day figure, dds_required_attention()'s window/unit totals) are left
-- as combined-type sums on purpose — they're "how many alerts total during
-- this flagged period", not a threshold decision, so blending types there
-- is correct, human-readable reporting, not the bug being fixed here.
-- ============================================================================

-- ── dds_driver_streaks(): qualifying_days' second branch now checks a
--    per-event_code day total, not a blended one. ─────────────────────────
create or replace function public.dds_driver_streaks(
  p_search text default null,
  p_min_streak integer default 1,
  p_sort text default 'streak_days',
  p_dir text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_window_days integer default null,
  p_shift text default null,
  p_asset text default null,
  p_status text default null,
  p_from date default null,
  p_to date default null
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
  v_critical integer;
  v_monitoring integer;
  v_closed integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  create temporary table _driver_streak_rows on commit drop as
  with daily as (
    -- Combined-type per-day total — kept for peak-day DISPLAY (run_peak_days
    -- below), a human-readable "worst day" figure, not a threshold decision.
    select emp_no, shift_date, sum(event_count) as day_total
    from public.events
    where emp_no is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
    group by emp_no, shift_date
  ),
  daily_by_code as (
    -- Per-day, PER ALERT TYPE total — the qualifying-day decision must
    -- never blend different alert types together (see migration header).
    select emp_no, shift_date, event_code, sum(event_count) as code_day_total
    from public.events
    where emp_no is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
    group by emp_no, shift_date, event_code
  ),
  qualifying_days as (
    select distinct emp_no, shift_date
    from public.events
    where emp_no is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
      and event_count > 10
    union
    select emp_no, shift_date
    from daily_by_code
    where code_day_total > 20
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
             then 'monitoring' else 'pending' end
      when es.status = 'actioned' then 'closed'
      else 'pending'
    end as status,
    case
      when es.status = 'monitoring' then
        case when es.monitor_until is not null and es.monitor_until >= current_date
             then 1 else 0 end
      when es.status = 'actioned' then 2
      else 0
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
                 then 'monitoring' else 'pending' end
          when es.status = 'actioned' then 'closed'
          else 'pending'
        end
      ) = p_status
    )
    and (p_from is null or lr.run_end >= p_from)
    and (p_to is null or lr.run_start <= p_to);

  select count(*) into v_total from _driver_streak_rows;
  select count(*) into v_open from _driver_streak_rows where status = 'pending';
  select count(*) into v_critical from _driver_streak_rows where streak_days >= 2;
  select count(*) into v_monitoring from _driver_streak_rows where status = 'monitoring';
  select count(*) into v_closed from _driver_streak_rows where status = 'closed';

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
         ''at'', to_char(last_action_at at time zone ''utc'', ''YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z'')
       ) end
     ))
     from (select * from _driver_streak_rows order by %I %s, streak_days desc, run_end desc, emp_no asc limit %s offset %s) s',
    v_sort, v_dir, v_limit, v_offset
  ) into v_result;

  return jsonb_build_object(
    'rows', coalesce(v_result, '[]'::jsonb),
    'total', v_total,
    'openCount', v_open,
    'criticalCount', v_critical,
    'monitoringCount', v_monitoring,
    'closedCount', v_closed
  );
end;
$function$;

-- ── dds_required_attention(): both the entry gate and the 90-day streak
--    length now use the same per-event_code qualifying-day definition as
--    dds_driver_streaks() above, instead of a blended day_total>10 proxy. ──
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
  window_code_totals as (
    select emp_no as entity_id, shift_date, event_code, sum(event_count) as code_day_total
    from events
    where emp_no is not null and shift_date >= v_from and shift_date <= v_to
    group by emp_no, shift_date, event_code
  ),
  qualifying_days_in_window as (
    select distinct emp_no as entity_id, shift_date
    from events
    where emp_no is not null and shift_date >= v_from and shift_date <= v_to
      and event_count > 10
    union
    select entity_id, shift_date
    from window_code_totals
    where code_day_total > 20
  ),
  driver_last_day as (
    -- Most recent day, within the window, that actually qualifies (either
    -- criterion, evaluated per alert type) — not simply the most recent day
    -- with any activity at all, and never a type-blended total.
    select entity_id, max(shift_date) as last_day
    from qualifying_days_in_window
    group by entity_id
  ),
  driver_days as (
    -- Combined-type per-day total — kept for the window/unit "how many
    -- total alerts" DISPLAY figures, not a threshold decision.
    select e.entity_id, ev.shift_date, sum(ev.event_count) as day_total
    from driver_last_day e
    join events ev on ev.emp_no = e.entity_id
    where ev.shift_date >= e.last_day - interval '89 days'
      and ev.shift_date <= e.last_day
    group by e.entity_id, ev.shift_date
  ),
  driver_days_by_code as (
    select e.entity_id, ev.shift_date, ev.event_code, sum(ev.event_count) as code_day_total
    from driver_last_day e
    join events ev on ev.emp_no = e.entity_id
    where ev.shift_date >= e.last_day - interval '89 days'
      and ev.shift_date <= e.last_day
    group by e.entity_id, ev.shift_date, ev.event_code
  ),
  qualifying_days_90 as (
    -- Same qualifying-day definition as qualifying_days_in_window above,
    -- just scoped to each driver's own 90-day lookback from their last_day
    -- (the streak can extend earlier than the review window).
    select distinct e.entity_id, ev.shift_date
    from driver_last_day e
    join events ev on ev.emp_no = e.entity_id
    where ev.shift_date >= e.last_day - interval '89 days'
      and ev.shift_date <= e.last_day
      and ev.event_count > 10
    union
    select entity_id, shift_date
    from driver_days_by_code
    where code_day_total > 20
  ),
  driver_cal as (
    select l.entity_id, gs.cal_date::date as cal_date
    from driver_last_day l
    cross join lateral generate_series(l.last_day - interval '89 days', l.last_day, interval '1 day') as gs(cal_date)
  ),
  driver_ranked as (
    select cal.entity_id,
           row_number() over (partition by cal.entity_id order by cal.cal_date desc) as rn,
           exists (
             select 1 from qualifying_days_90 q
             where q.entity_id = cal.entity_id and q.shift_date = cal.cal_date
           ) as qualifies
    from driver_cal cal
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
    join driver_last_day l on l.entity_id = e.entity_id
    left join driver_streak20 ds on ds.entity_id = e.entity_id
    left join entity_status es on es.entity_type = 'driver' and es.entity_id = e.entity_id
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
