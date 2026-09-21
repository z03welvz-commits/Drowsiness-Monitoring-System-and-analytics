-- ============================================================================
-- DDS — 0162_monitoring_streaks_flag_reason
-- ----------------------------------------------------------------------------
-- Adds the concrete qualifying reason for a streak's peak day to
-- dds_monitoring_streaks() — peakDayTriggerType/peakDayTriggerCode/
-- peakDayTriggerValue — so the Driver & Asset Monitoring export/detail
-- description can state WHICH of the two dds_qualifying_days() (0153)
-- criteria was actually met, and by how much, instead of a flat "20+"
-- restatement that doesn't match the real rule (a single event > 10, OR
-- one event_code's day-sum > 20 — never blended across event types).
--
-- peak_day_trigger picks, per entity, ONE representative event_code from
-- the run's peak day (already computed by run_peak_days): a single-event
-- trigger (event_count > 10) if any exists for that day, else the
-- highest-summing event_code whose day-total exceeds 20. Every row this
-- function returns is, by construction, a qualifying run (dds_qualifying_
-- days() found at least one qualifying day in it), and the peak day is
-- itself always drawn from within that run — so this join is expected to
-- resolve for every row, never leaving the reason blank.
--
-- Purely additive: three new jsonb keys, no existing key's shape changes.
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
  -- Which real dds_qualifying_days() criterion the peak day met, and by how
  -- much — a single event's own count for 'single_event', or the event_code's
  -- summed count for the day for 'daily_total'. When a peak day meets both
  -- criteria (possible, e.g. across different event_codes), the single-event
  -- trigger is preferred as the more acute signal; ties within a type break
  -- on the larger value.
  peak_day_trigger_candidates as (
    select lr.entity_id, e.event_code, 'single_event'::text as trigger_type,
           e.event_count as trigger_value
    from latest_run lr
    join run_peak_days rpd on rpd.entity_id = lr.entity_id
    join public.events e on (case when v_is_driver then e.emp_no else e.asset_id end) = lr.entity_id
      and e.shift_date = rpd.peak_date
    where e.event_count > 10
    union all
    select lr.entity_id, e.event_code, 'daily_total'::text as trigger_type,
           sum(e.event_count) as trigger_value
    from latest_run lr
    join run_peak_days rpd on rpd.entity_id = lr.entity_id
    join public.events e on (case when v_is_driver then e.emp_no else e.asset_id end) = lr.entity_id
      and e.shift_date = rpd.peak_date
    group by lr.entity_id, e.event_code
    having sum(e.event_count) > 20
  ),
  peak_day_trigger as (
    select distinct on (entity_id) entity_id, event_code, trigger_type, trigger_value
    from peak_day_trigger_candidates
    order by entity_id, (trigger_type = 'single_event') desc, trigger_value desc
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
    pdt.trigger_type as peak_day_trigger_type,
    pdt.event_code as peak_day_trigger_code,
    pdt.trigger_value as peak_day_trigger_value,
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
  left join peak_day_trigger pdt on pdt.entity_id = lr.entity_id
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
       ''peakDayTriggerType'', peak_day_trigger_type,
       ''peakDayTriggerCode'', peak_day_trigger_code,
       ''peakDayTriggerValue'', peak_day_trigger_value,
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
  'Canonical driver/asset streak-run summary for the merged Driver & Asset Monitoring page (0158) — generalizes dds_driver_streaks() to both entity types via dds_qualifying_days(). The This Week/All-Time toggle is just a p_from/p_to choice on this one function, not two different queries. peakDayTrigger* fields (0162) name the concrete dds_qualifying_days() criterion the peak day met.';
