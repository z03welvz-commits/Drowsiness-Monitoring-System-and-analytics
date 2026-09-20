-- ============================================================================
-- DDS — 0158_monitoring_streaks_unified
-- ----------------------------------------------------------------------------
-- Part 5 of the action-logging/status redesign: merges Driver & Asset
-- Monitoring + Driver Streaks into one page with a This Week / All-Time
-- toggle. That only works if both toggle states and both entity types come
-- from the SAME rich row shape (Date Flag/Streak Days/Total Count/etc.) —
-- dds_driver_streaks() already computes that shape correctly (post-0154,
-- built on the canonical dds_qualifying_days()) but only for drivers;
-- dds_driver_asset_weekly() covers both entity types but never returns the
-- run-length fields (runStart/runEnd/runTotalCount/avgCount/peakCount/
-- highAlerts/dominantShift) the merged table's column set needs.
--
-- dds_monitoring_streaks(p_entity_type, ...) generalizes dds_driver_streaks()
-- to serve both drivers and assets from one function, reusing
-- dds_qualifying_days(p_entity_type, ...) exactly as dds_driver_streaks()
-- does. The "This Week" vs "All-Time" toggle is just a parameter choice on
-- this ONE function, not two different queries:
--   This Week: p_from/p_to = the selected range, p_window_days = null
--     (still an unbounded history search for qualifying days — a streak
--     that started before the window shouldn't be truncated — filtered at
--     the end to runs overlapping the window, exactly like
--     dds_driver_streaks()'s existing p_from/p_to already work).
--   All-Time:  p_from = null, p_to = null, p_window_days = null.
--
-- Driver-only enrichments (name from the drivers table, a primary-
-- associated-asset "unit" figure) are gated on p_entity_type = 'driver' —
-- for assets, name = the asset's own id and unit is not returned (an
-- asset's own id already identifies it; the asset-side "most-associated
-- driver" is a different question this redesign doesn't add). Everything
-- else (streak-run computation, severity/high-alert totals, dominant
-- shift, status/monitorUntil/lastAction) is entity-agnostic already, since
-- entity_status/entity_action_log are keyed by (entity_type, entity_id).
--
-- dds_driver_streaks() and dds_driver_asset_weekly() are left in place —
-- the nav-badge fetch and (for now) other pages/RPCs may still reference
-- them — this migration only adds the new function alongside.
-- ============================================================================

create or replace function public.dds_monitoring_streaks(
  p_entity_type text,
  p_search text default null,
  p_min_streak integer default 1,
  p_sort text default 'status_priority',
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
  v_sort   text := case when p_sort in ('streak_days','run_total_count','entity_id','name','run_end','status_priority')
                        then p_sort else 'status_priority' end;
  v_dir    text := case when lower(coalesce(p_dir,'desc')) = 'asc' then 'asc' else 'desc' end;
  v_is_driver boolean := coalesce(p_entity_type, 'driver') = 'driver';
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

  create temporary table _monitoring_streak_rows on commit drop as
  with daily as (
    -- Combined-type per-day total — kept for peak-day DISPLAY only, same
    -- as dds_driver_streaks()'s own `daily` CTE.
    select
      case when v_is_driver then emp_no else asset_id end as entity_id,
      shift_date, sum(event_count) as day_total
    from public.events
    where (case when v_is_driver then emp_no else asset_id end) is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
    group by 1, 2
  ),
  qualifying_days as (
    select entity_id, shift_date
    from public.dds_qualifying_days(
      coalesce(p_entity_type, 'driver'),
      (case when p_window_days is null then null else current_date - make_interval(days => p_window_days) end)::date,
      null
    )
  ),
  qualifying as (
    select entity_id, shift_date,
           shift_date - (row_number() over (partition by entity_id order by shift_date))::int as grp
    from qualifying_days
  ),
  runs as (
    select entity_id, min(shift_date) as run_start, max(shift_date) as run_end, count(*) as run_len
    from qualifying
    group by entity_id, grp
  ),
  run_counts as (
    select entity_id, count(*) as streak_count
    from runs
    group by entity_id
  ),
  latest_run as (
    select distinct on (entity_id) entity_id, run_start, run_end, run_len
    from runs
    order by entity_id, run_end desc
  ),
  run_span_totals as (
    select lr.entity_id,
      sum(d.event_count) as run_total_count
    from latest_run lr
    join public.events d on (case when v_is_driver then d.emp_no else d.asset_id end) = lr.entity_id
      and d.shift_date >= lr.run_start and d.shift_date <= lr.run_end
    group by lr.entity_id
  ),
  run_peak_days as (
    select distinct on (lr.entity_id) lr.entity_id, dl.shift_date as peak_date, dl.day_total as peak_count
    from latest_run lr
    join daily dl on dl.entity_id = lr.entity_id
      and dl.shift_date >= lr.run_start and dl.shift_date <= lr.run_end
    order by lr.entity_id, dl.day_total desc, dl.shift_date asc
  ),
  run_shift_counts as (
    select lr.entity_id,
      count(*) filter (where ev.shift = 'NIGHT') as night_n,
      count(*) filter (where ev.shift = 'DAY') as day_n
    from latest_run lr
    join public.events ev on (case when v_is_driver then ev.emp_no else ev.asset_id end) = lr.entity_id
      and ev.shift_date >= lr.run_start and ev.shift_date <= lr.run_end
    group by lr.entity_id
  ),
  totals as (
    select
      case when v_is_driver then emp_no else asset_id end as entity_id,
      sum(event_count) as total_count
    from public.events
    where (case when v_is_driver then emp_no else asset_id end) is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
    group by 1
  ),
  severity_totals as (
    select
      case when v_is_driver then emp_no else asset_id end as entity_id,
      coalesce(sum(event_count) filter (where event_code ilike '%sleep%'), 0)
        + coalesce(sum(event_count) filter (where event_code ilike '%drowsi%' and event_code not ilike '%sleep%'), 0)
        as high_alerts
    from public.events
    where (case when v_is_driver then emp_no else asset_id end) is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
    group by 1
  ),
  -- Driver-only: the driver's most-used associated asset over their run
  -- span, shown as "unit". Not a meaningful concept for the asset entity
  -- type itself, so this CTE is empty (and `unit` null) when p_entity_type
  -- = 'asset'.
  asset_totals as (
    select emp_no as entity_id, asset_id, sum(event_count) as asset_total
    from public.events
    where v_is_driver and emp_no is not null and asset_id is not null
      and (p_window_days is null or shift_date >= current_date - make_interval(days => p_window_days))
    group by emp_no, asset_id
  ),
  primary_asset as (
    select distinct on (entity_id) entity_id, asset_id
    from asset_totals
    order by entity_id, asset_total desc, asset_id
  ),
  last_actions as (
    select distinct on (entity_id)
      entity_id, action_type, action_other_text, note, logged_by, created_at
    from public.entity_action_log
    where entity_type = coalesce(p_entity_type, 'driver')
    order by entity_id, created_at desc
  ),
  driver_names as (
    select emp_no as entity_id, full_name from public.drivers
  )
  select
    lr.entity_id,
    case when v_is_driver then coalesce(dn.full_name, lr.entity_id) else lr.entity_id end as name,
    lr.run_start, lr.run_end, lr.run_len as streak_days,
    coalesce(rc.streak_count, 1) as streak_count,
    coalesce(t.total_count, 0) as total_count,
    coalesce(rst.run_total_count, 0) as run_total_count,
    round(coalesce(rst.run_total_count, 0)::numeric / greatest(lr.run_len, 1), 1) as avg_count,
    rpd.peak_count, rpd.peak_date,
    coalesce(st.high_alerts, 0) as high_alerts,
    pa.asset_id as unit,
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
    la.action_other_text as last_action_other_text,
    la.note as last_action_note,
    la.logged_by as last_action_by,
    la.created_at as last_action_at
  from latest_run lr
  left join driver_names dn on v_is_driver and dn.entity_id = lr.entity_id
  left join run_counts rc on rc.entity_id = lr.entity_id
  left join totals t on t.entity_id = lr.entity_id
  left join run_span_totals rst on rst.entity_id = lr.entity_id
  left join run_peak_days rpd on rpd.entity_id = lr.entity_id
  left join run_shift_counts rsc on rsc.entity_id = lr.entity_id
  left join severity_totals st on st.entity_id = lr.entity_id
  left join primary_asset pa on pa.entity_id = lr.entity_id
  left join public.entity_status es on es.entity_type = coalesce(p_entity_type, 'driver') and es.entity_id = lr.entity_id
  left join last_actions la on la.entity_id = lr.entity_id
  where lr.run_len >= greatest(coalesce(p_min_streak, 1), 1)
    and (
      p_search is null or p_search = ''
      or lr.entity_id ilike '%' || p_search || '%'
      or (v_is_driver and coalesce(dn.full_name, '') ilike '%' || p_search || '%')
    )
    and (
      p_shift is null or p_shift = ''
      or (case when coalesce(rsc.night_n, 0) > coalesce(rsc.day_n, 0) then 'NIGHT' else 'DAY' end) = upper(p_shift)
    )
    and (not v_is_driver or p_asset is null or p_asset = '' or pa.asset_id = p_asset)
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

  select count(*) into v_total from _monitoring_streak_rows;
  select count(*) into v_open from _monitoring_streak_rows where status = 'pending';
  select count(*) into v_critical from _monitoring_streak_rows where streak_days >= 2;
  select count(*) into v_monitoring from _monitoring_streak_rows where status = 'monitoring';
  select count(*) into v_closed from _monitoring_streak_rows where status = 'closed';

  execute format(
    'select jsonb_agg(jsonb_build_object(
       ''id'', entity_id, ''name'', name,
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
       ''unit'', unit,
       ''dominantShift'', dominant_shift,
       ''status'', status,
       ''monitorUntil'', to_char(monitor_until, ''YYYY-MM-DD''),
       ''lastAction'', case when last_action_type is null then null else jsonb_build_object(
         ''type'', last_action_type, ''otherText'', last_action_other_text,
         ''note'', last_action_note, ''by'', last_action_by,
         ''at'', to_char(last_action_at at time zone ''utc'', ''YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z'')
       ) end
     ))
     from (select * from _monitoring_streak_rows order by %I %s, streak_days desc, run_end desc, entity_id asc limit %s offset %s) s',
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

comment on function public.dds_monitoring_streaks(text, text, integer, text, text, integer, integer, integer, text, text, text, date, date) is
  'Canonical driver/asset streak-run summary for the merged Driver & Asset Monitoring page (0158) — generalizes dds_driver_streaks() to both entity types via dds_qualifying_days(). The This Week/All-Time toggle is just a p_from/p_to choice on this one function, not two different queries.';
