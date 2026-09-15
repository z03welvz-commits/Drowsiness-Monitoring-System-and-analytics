-- ============================================================================
-- DDS — 0142_analytics_associative_cross_filters
-- ----------------------------------------------------------------------------
-- Analytics' redesign asks for Qlik-Sense-style associative filtering: a
-- selection on ANY chart (date, shift, unit, employee, alert type, hour,
-- sync interval bucket) narrows every other chart and KPI on the page.
--
-- dds_metrics() already had five of those seven dimensions covered
-- (p_from/p_to, p_shift, p_asset_ids, p_event_codes) — the two genuinely
-- missing were employee and hour-of-day, plus a sync-interval-bucket filter
-- to make the sync chart itself clickable. All three are simple predicates
-- against columns dds_metrics()'s own `filtered` CTE already selects
-- (emp_no, start_time, sync_seconds), so this is additive filtering, not a
-- new aggregation or a new business rule: every existing computation is
-- unchanged when the new params are left null (their default), and the sync
-- bucket boundaries are copied verbatim from this same function's own
-- sync_buckets CTE a few lines below, not invented here.
--
-- minestat_daily (operating hours) deliberately does NOT take the new
-- params, same as it already excludes p_event_codes/p_actionable_only —
-- MineStat's operating-hours rows have no emp_no/start_time/sync_seconds of
-- their own (they're per shift/unit/day, not per alert event), so an
-- employee/hour/sync-bucket selection has nothing there to filter by.
--
-- dds_asset_event_summary()/dds_driver_event_summary() (Analytics' "Alerts
-- by Unit"/"Alerts by Employee" ranked lists) get the matching p_event_code/
-- p_hour/p_sync_bucket additions so a donut or sync-interval selection also
-- narrows those two lists, not just the KPIs/trend/hourly/donut group that
-- already shared dds_metrics(). Both already read dds_case_records, which
-- carries start_time and sync_seconds, so no new column or join is needed.
-- ============================================================================

-- CREATE OR REPLACE only replaces a function whose argument list matches
-- exactly — adding 3 new parameters makes Postgres treat this as a distinct
-- overload rather than a replacement (same trap 0104's own header
-- documents), so the old 6-arg dds_metrics() is dropped explicitly first.
drop function if exists public.dds_metrics(date, date, text, text[], text[], boolean);

create or replace function public.dds_metrics(
  p_from date default null::date,
  p_to date default null::date,
  p_shift text default null::text,
  p_asset_ids text[] default null::text[],
  p_event_codes text[] default null::text[],
  p_actionable_only boolean default false,
  p_emp_no text default null,
  p_hour integer default null,
  p_sync_bucket integer default null
)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public'
 set work_mem to '64MB'
as $function$
declare
  result jsonb;
  v_high_day_threshold constant integer := 10;
  v_recent_limit       constant integer := 8;
  c_unspecified        constant text    := 'UNSPECIFIED';
  v_still_arriving_days constant integer := 4;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with filtered as (
    select *
    from public.events e
    where (p_from        is null or e.shift_date >= p_from)
      and (p_to          is null or e.shift_date <= p_to)
      and (p_shift       is null or e.shift = p_shift)
      and (p_asset_ids   is null or e.asset_id   = any(p_asset_ids))
      and (p_event_codes is null or e.event_code = any(p_event_codes))
      and (not p_actionable_only or e.actionable)
      and (p_emp_no      is null or e.emp_no = p_emp_no)
      and (p_hour        is null or extract(hour from e.start_time)::int = p_hour)
      and (p_sync_bucket is null or (
             case
               when e.sync_seconds is null   then null
               when e.sync_seconds < 10800   then 0
               when e.sync_seconds < 21600   then 1
               when e.sync_seconds < 28800   then 2
               when e.sync_seconds < 36000   then 3
               else 4
             end
           ) = p_sync_bucket)
  ),
  kpis as (
    select
      coalesce(sum(event_count), 0)                                    as total_alerts,
      count(distinct asset_id)                                         as distinct_assets,
      count(distinct emp_no) filter (where emp_no is not null)         as distinct_operators,
      avg(sync_seconds)                                                as avg_sync_seconds,
      coalesce(sum(event_count) filter (where actionable), 0)          as actionable_alerts,
      count(*)                                                         as row_count
    from filtered
  ),
  trend as (
    select shift_date,
           sum(event_count)          as units,
           count(*)                  as events,
           count(distinct asset_id)  as assets,
           avg(sync_seconds)         as avg_sync_seconds,
           coalesce(sum(event_count) filter (where actionable), 0) as actionable_units,
           count(distinct emp_no) filter (where emp_no is not null)  as distinct_operators,
           coalesce(sum(event_count) filter (where event_code ilike '%sleep%'), 0) as critical_units,
           coalesce(sum(event_count) filter (where event_code ilike '%drowsi%' and event_code not ilike '%sleep%'), 0) as high_units
    from filtered group by shift_date order by shift_date
  ),
  -- Independent of `filtered` — see the migration header for why this
  -- reads minestat_shifts directly rather than joining through it.
  minestat_daily as (
    select shift_date,
           sum(operating_hrs) as operating_hours
    from public.minestat_shifts
    where (p_from      is null or shift_date >= p_from)
      and (p_to        is null or shift_date <= p_to)
      and (p_shift     is null or shift = p_shift)
      and (p_asset_ids is null or asset_id = any(p_asset_ids))
    group by shift_date
  ),
  minestat_total as (
    select sum(operating_hours) as total_operating_hours from minestat_daily
  ),
  by_shift as (
    select shift, sum(event_count) as units, count(distinct asset_id) as assets
    from filtered group by shift
  ),
  by_code as (
    select event_code, sum(event_count) as units, count(*) as events
    from filtered group by event_code order by 2 desc, event_code
  ),
  hours as (select generate_series(0, 23) as h),
  hourly as (
    select h.h,
           coalesce(sum(f.event_count) filter (where f.shift = 'DAY'),   0) as day_units,
           coalesce(sum(f.event_count) filter (where f.shift = 'NIGHT'), 0) as night_units
    from hours h
    left join filtered f on extract(hour from f.start_time)::int = h.h
    group by h.h order by h.h
  ),
  months as (
    select distinct to_char(date_trunc('month', f.start_time), 'YYYY-MM') as month_key
    from filtered f
  ),
  hourly_by_month as (
    select to_char(date_trunc('month', f.start_time), 'YYYY-MM') as month_key,
           extract(hour from f.start_time)::int as h,
           sum(f.event_count) as units
    from filtered f group by 1, 2
  ),
  day_of_week as (
    select ((extract(dow from shift_date)::int + 6) % 7) as dow_idx,
           sum(event_count) as units
    from filtered group by 1
  ),
  sync_buckets as (
    select
      case
        when sync_seconds < 10800 then 0
        when sync_seconds < 21600 then 1
        when sync_seconds < 28800 then 2
        when sync_seconds < 36000 then 3
        else 4
      end as bucket,
      actionable, count(*) as n
    from filtered where sync_seconds is not null group by 1, 2
  ),
  alert_buckets as (
    select
      case
        when event_count < 5  then 0
        when event_count < 10 then 1
        when event_count < 15 then 2
        when event_count < 20 then 3
        else 4
      end as bucket,
      actionable, count(*) as n
    from filtered group by 1, 2
  ),
  asset_all as (
    select asset_id,
           sum(event_count)                                           as total,
           coalesce(sum(event_count) filter (where actionable), 0)     as actionable,
           coalesce(sum(event_count) filter (where not actionable), 0) as non_actionable,
           count(distinct shift_date)                                  as active_days
    from filtered group by asset_id
  ),

  -- ── Operator/driver CTEs — now keyed on emp_no, not raw operator text ────
  operator_all as (
    select coalesce(emp_no, c_unspecified) as emp_key,
           sum(event_count)                                           as total,
           coalesce(sum(event_count) filter (where actionable), 0)     as actionable,
           coalesce(sum(event_count) filter (where not actionable), 0) as non_actionable,
           count(distinct shift_date)                                  as active_days
    from filtered group by 1
  ),
  operator_code_counts as (
    select coalesce(emp_no, c_unspecified) as emp_key,
           event_code, count(*) as code_rows
    from filtered where event_code is not null group by 1, 2
  ),
  operator_primary_code as (
    select distinct on (emp_key) emp_key, event_code as primary_event_code
    from operator_code_counts
    order by emp_key, code_rows desc, event_code
  ),
  operator_last_alert as (
    select coalesce(emp_no, c_unspecified) as emp_key,
           max(start_time) as last_alert_time
    from filtered group by 1
  ),
  asset_days as (
    select asset_id, shift_date, sum(event_count) as day_total
    from filtered group by asset_id, shift_date
  ),
  operator_days as (
    select coalesce(emp_no, c_unspecified) as emp_key,
           shift_date, sum(event_count) as day_total
    from filtered group by 1, shift_date
  ),
  asset_consistency_all as (
    select a.asset_id, a.total, a.actionable, a.non_actionable, a.active_days,
           coalesce(hd.high_days, 0) as high_days
    from asset_all a
    left join (
      select asset_id, count(*) as high_days
      from asset_days where day_total > v_high_day_threshold group by asset_id
    ) hd on hd.asset_id = a.asset_id
  ),
  operator_consistency_all as (
    select o.emp_key, o.total, o.actionable, o.non_actionable, o.active_days,
           coalesce(hd.high_days, 0) as high_days
    from operator_all o
    left join (
      select emp_key, count(*) as high_days
      from operator_days where day_total > v_high_day_threshold group by emp_key
    ) hd on hd.emp_key = o.emp_key
  ),
  top_assets as (
    select * from asset_all order by total desc, asset_id limit 10
  ),
  top_operators as (
    select o.*, pc.primary_event_code, la.last_alert_time,
           case
             when o.emp_key = c_unspecified then 'Unspecified'
             else coalesce(d.full_name, o.emp_key)
           end as display_name
    from (select * from operator_all order by total desc, emp_key limit 10) o
    left join operator_primary_code pc on pc.emp_key = o.emp_key
    left join operator_last_alert    la on la.emp_key = o.emp_key
    left join public.drivers         d  on d.emp_no   = o.emp_key
  ),
  recent_alerts as (
    select start_time, operator, asset_id, event_code, shift, event_count
    from filtered
    order by start_time desc, asset_id
    limit v_recent_limit
  ),
  bucket_array as (
    select
      (select jsonb_agg(coalesce(v, 0) order by i)
         from generate_series(0, 4) i
         left join (select bucket, sum(n) v from sync_buckets where actionable group by 1) b
           on b.bucket = i) as sync_act,
      (select jsonb_agg(coalesce(v, 0) order by i)
         from generate_series(0, 4) i
         left join (select bucket, sum(n) v from sync_buckets where not actionable group by 1) b
           on b.bucket = i) as sync_non,
      (select jsonb_agg(coalesce(v, 0) order by i)
         from generate_series(0, 4) i
         left join (select bucket, sum(n) v from alert_buckets where actionable group by 1) b
           on b.bucket = i) as alert_act,
      (select jsonb_agg(coalesce(v, 0) order by i)
         from generate_series(0, 4) i
         left join (select bucket, sum(n) v from alert_buckets where not actionable group by 1) b
           on b.bucket = i) as alert_non
  )
  select jsonb_build_object(
    'meta', jsonb_build_object(
      'rowCount',          k.row_count,
      'unclassifiedRows',  0,
      'unclassifiedUnits', 0,
      'reconciles',        true,
      'stillArrivingThresholdDays', v_still_arriving_days,
      'filters', jsonb_build_object(
        'from', p_from, 'to', p_to, 'shift', p_shift,
        'assetIds', coalesce(to_jsonb(p_asset_ids), '[]'::jsonb),
        'eventCodes', coalesce(to_jsonb(p_event_codes), '[]'::jsonb),
        'actionableOnly', p_actionable_only,
        'empNo', p_emp_no, 'hour', p_hour, 'syncBucket', p_sync_bucket
      ),
      'generatedAt', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
    ),
    'kpis', jsonb_build_object(
      'totalAlerts',       k.total_alerts,
      'distinctAssets',    k.distinct_assets,
      'distinctOperators', k.distinct_operators,
      'avgSyncSeconds',    k.avg_sync_seconds,
      'actionableRatio',
        case when k.total_alerts > 0
          then (k.actionable_alerts::numeric / k.total_alerts) * 100 else 0 end,
      'alertsPerOperatingHour',
        case when coalesce(mt.total_operating_hours, 0) > 0
          then k.total_alerts::numeric / mt.total_operating_hours else null end
    ),
    'trend', coalesce((
      select jsonb_agg(jsonb_build_object(
        'date',   to_char(t.shift_date, 'MM/DD/YYYY'),
        'units',  t.units, 'events', t.events, 'assets', t.assets,
        'avgSyncSeconds', t.avg_sync_seconds,
        'operatingHours', coalesce(md.operating_hours, 0),
        'alertsPerOperatingHour', case when coalesce(md.operating_hours, 0) > 0
          then t.units::numeric / md.operating_hours else null end,
        'actionableRatio', case when t.units > 0
          then (t.actionable_units::numeric / t.units) * 100 else 0 end,
        'distinctOperators', t.distinct_operators,
        'criticalUnits', t.critical_units,
        'highUnits', t.high_units,
        'stillArriving', t.shift_date > current_date - v_still_arriving_days
      ) order by t.shift_date)
      from trend t
      left join minestat_daily md on md.shift_date = t.shift_date
    ), '[]'::jsonb),
    'shiftDistribution', jsonb_build_object(
      'DAY', jsonb_build_object(
        'units',  coalesce((select units  from by_shift where shift = 'DAY'), 0),
        'assets', coalesce((select assets from by_shift where shift = 'DAY'), 0),
        'pct', case when k.total_alerts > 0 then
          (coalesce((select units from by_shift where shift = 'DAY'), 0)::numeric
            / k.total_alerts) * 100 else 0 end),
      'NIGHT', jsonb_build_object(
        'units',  coalesce((select units  from by_shift where shift = 'NIGHT'), 0),
        'assets', coalesce((select assets from by_shift where shift = 'NIGHT'), 0),
        'pct', case when k.total_alerts > 0 then
          (coalesce((select units from by_shift where shift = 'NIGHT'), 0)::numeric
            / k.total_alerts) * 100 else 0 end)
    ),
    'eventCodeDistribution', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', event_code, 'units', units, 'events', events,
        'pct', case when k.total_alerts > 0
          then (units::numeric / k.total_alerts) * 100 else 0 end
      ) order by units desc, event_code) from by_code), '[]'::jsonb),
    'hourly', jsonb_build_object(
      'DAY',   (select jsonb_agg(day_units   order by h) from hourly),
      'NIGHT', (select jsonb_agg(night_units order by h) from hourly)
    ),
    'hourlyByMonth', coalesce((
      select jsonb_agg(jsonb_build_object(
        'month', m.month_key,
        'hours', (
          select jsonb_agg(coalesce(hbm.units, 0) order by h.h)
          from hours h
          left join hourly_by_month hbm
            on hbm.month_key = m.month_key and hbm.h = h.h
        )
      ) order by m.month_key)
      from months m), '[]'::jsonb),
    'dayOfWeek', (
      select jsonb_agg(jsonb_build_object('day', d.day_name, 'units', coalesce(dw.units, 0)) order by d.idx)
      from (values (0,'Mon'),(1,'Tue'),(2,'Wed'),(3,'Thu'),(4,'Fri'),(5,'Sat'),(6,'Sun')) as d(idx, day_name)
      left join day_of_week dw on dw.dow_idx = d.idx
    ),
    'syncBuckets', jsonb_build_object(
      'labels', '["<3h","3-6h","6-8h","8-10h","10h+"]'::jsonb,
      'actionable', b.sync_act, 'nonActionable', b.sync_non),
    'alertBuckets', jsonb_build_object(
      'labels', '["<5","5-10","10-15","15-20","20+"]'::jsonb,
      'actionable', b.alert_act, 'nonActionable', b.alert_non),
    'topAssets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', asset_id, 'total', total,
        'actionable', actionable, 'nonActionable', non_actionable,
        'activeDays', active_days
      ) order by total desc, asset_id) from top_assets), '[]'::jsonb),
    'topOperators', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', display_name, 'empNo', case when emp_key = c_unspecified then null else emp_key end,
        'total', total,
        'actionable', actionable, 'nonActionable', non_actionable,
        'activeDays', active_days,
        'primaryEventCode', primary_event_code,
        'lastAlertTime', case when last_alert_time is not null
          then to_char(last_alert_time, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') end
      ) order by total desc, display_name) from top_operators), '[]'::jsonb),

    'assetConsistency', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', asset_id, 'total', total,
        'actionable', actionable, 'nonActionable', non_actionable,
        'activeDays', active_days,
        'highDays', high_days,
        'highDayRatio', case when active_days > 0
          then (high_days::numeric / active_days) * 100 else 0 end,
        'consistencyRate', total::numeric / greatest(active_days, 1),
        'actionableRatio', case when total > 0
          then (actionable::numeric / total) * 100 else 0 end
      ) order by
        (case when active_days > 0 then (high_days::numeric / active_days) else 0 end) desc,
        (total::numeric / greatest(active_days, 1)) desc,
        asset_id)
      from asset_consistency_all), '[]'::jsonb),
    'operatorConsistency', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',
          case when oc.emp_key = c_unspecified then 'Unspecified'
               else coalesce(d.full_name, oc.emp_key) end,
        'empNo', case when oc.emp_key = c_unspecified then null else oc.emp_key end,
        'total', oc.total,
        'actionable', oc.actionable, 'nonActionable', oc.non_actionable,
        'activeDays', oc.active_days,
        'highDays', oc.high_days,
        'highDayRatio', case when oc.active_days > 0
          then (oc.high_days::numeric / oc.active_days) * 100 else 0 end,
        'consistencyRate', oc.total::numeric / greatest(oc.active_days, 1),
        'actionableRatio', case when oc.total > 0
          then (oc.actionable::numeric / oc.total) * 100 else 0 end
      ) order by
        (case when oc.active_days > 0 then (oc.high_days::numeric / oc.active_days) else 0 end) desc,
        (oc.total::numeric / greatest(oc.active_days, 1)) desc,
        oc.emp_key)
      from operator_consistency_all oc
      left join public.drivers d on d.emp_no = oc.emp_key), '[]'::jsonb),
    'recentAlerts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'time',      to_char(start_time, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
        'operator',  coalesce(nullif(operator, ''), 'Unspecified'),
        'asset',     coalesce(asset_id, '—'),
        'eventCode', coalesce(event_code, '—'),
        'shift',     coalesce(shift, ''),
        'count',     event_count
      ) order by start_time desc, asset_id)
      from recent_alerts), '[]'::jsonb)
  )
  into result
  from kpis k, bucket_array b, minestat_total mt;

  return result;
end;
$function$;

-- ── Alerts by Unit / Alerts by Employee: matching filters ───────────────────
-- Same p_event_code/p_hour/p_sync_bucket additions so a donut or sync-
-- interval selection narrows these two ranked lists too, not just the
-- dds_metrics()-backed charts. New 12-arg signature — the old 9-arg
-- overload is dropped first, same reason 0104's own header gives.
drop function if exists public.dds_asset_event_summary(text, text, text, integer, integer, date, date, text, text);
drop function if exists public.dds_driver_event_summary(text, text, text, integer, integer, date, date, text, text);

create or replace function public.dds_asset_event_summary(
  p_search text default null,
  p_sort text default 'total',
  p_dir text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_from date default null,
  p_to date default null,
  p_shift text default null,
  p_asset_id text default null,
  p_event_code text default null,
  p_hour integer default null,
  p_sync_bucket integer default null
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
set work_mem to '64MB'
as $function$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 50), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_desc boolean := lower(coalesce(p_dir, 'desc')) is distinct from 'asc';
  v_sort text := lower(coalesce(p_sort, 'total'));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with base as (
    select r.asset_id, r.event_code, r.event_count, r.sync_seconds
    from public.dds_case_records r
    where (p_from is null or r.shift_date >= p_from)
      and (p_to   is null or r.shift_date <= p_to)
      and (p_shift is null or p_shift = '' or r.shift = p_shift)
      and (p_asset_id is null or r.asset_id = p_asset_id)
      and (p_event_code is null or r.event_code = p_event_code)
      and (p_hour is null or extract(hour from r.start_time)::int = p_hour)
      and (p_sync_bucket is null or (
             case
               when r.sync_seconds is null then null
               when r.sync_seconds < 10800 then 0
               when r.sync_seconds < 21600 then 1
               when r.sync_seconds < 28800 then 2
               when r.sync_seconds < 36000 then 3
               else 4
             end
           ) = p_sync_bucket)
  ),
  per_asset_code as (
    select asset_id, event_code, sum(event_count) as code_count
    from base
    group by asset_id, event_code
  ),
  codes_agg as (
    select asset_id,
      jsonb_agg(jsonb_build_object('eventCode', event_code, 'count', code_count) order by code_count desc) as codes,
      sum(code_count) as total
    from per_asset_code
    group by asset_id
  ),
  sync_agg as (
    select asset_id, avg(sync_seconds)::int as avg_sync_seconds
    from base
    where sync_seconds is not null
    group by asset_id
  ),
  filtered as (
    select ca.asset_id, ca.codes, ca.total, sy.avg_sync_seconds
    from codes_agg ca
    left join sync_agg sy on sy.asset_id = ca.asset_id
    where p_search is null or p_search = '' or ca.asset_id ilike '%' || p_search || '%'
  ),
  total_count as (select count(*) as n from filtered),
  paged as (
    select * from filtered
    order by
      case when v_desc then null else case v_sort when 'asset_id' then asset_id end end asc nulls last,
      case when v_desc then case v_sort when 'asset_id' then asset_id end end desc nulls last,
      case when v_sort = 'total' and not v_desc then total end asc nulls last,
      case when v_sort = 'total' and v_desc     then total end desc nulls last,
      asset_id
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total_count),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'assetId', asset_id, 'eventCodes', codes, 'total', total, 'avgSyncSeconds', avg_sync_seconds
      ))
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;

create or replace function public.dds_driver_event_summary(
  p_search text default null,
  p_sort text default 'total',
  p_dir text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_from date default null,
  p_to date default null,
  p_shift text default null,
  p_asset_id text default null,
  p_event_code text default null,
  p_hour integer default null,
  p_sync_bucket integer default null
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
set work_mem to '64MB'
as $function$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 50), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_desc boolean := lower(coalesce(p_dir, 'desc')) is distinct from 'asc';
  v_sort text := lower(coalesce(p_sort, 'total'));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with base as (
    select
      r.emp_no_norm as emp_no,
      coalesce(r.emp_name, case when r.emp_no is null then 'Unspecified' else r.emp_no end) as emp_name,
      r.event_code,
      r.event_count,
      r.is_unresolved_high_severity
    from public.dds_case_records r
    where (p_from is null or r.shift_date >= p_from)
      and (p_to   is null or r.shift_date <= p_to)
      and (p_shift is null or p_shift = '' or r.shift = p_shift)
      and (p_asset_id is null or r.asset_id = p_asset_id)
      and (p_event_code is null or r.event_code = p_event_code)
      and (p_hour is null or extract(hour from r.start_time)::int = p_hour)
      and (p_sync_bucket is null or (
             case
               when r.sync_seconds is null then null
               when r.sync_seconds < 10800 then 0
               when r.sync_seconds < 21600 then 1
               when r.sync_seconds < 28800 then 2
               when r.sync_seconds < 36000 then 3
               else 4
             end
           ) = p_sync_bucket)
  ),
  per_driver_code as (
    select emp_no, emp_name, event_code, sum(event_count) as code_count
    from base
    group by emp_no, emp_name, event_code
  ),
  codes_agg as (
    select emp_no, emp_name,
      jsonb_agg(jsonb_build_object('eventCode', event_code, 'count', code_count) order by code_count desc) as codes,
      sum(code_count) as total
    from per_driver_code
    group by emp_no, emp_name
  ),
  status_agg as (
    select emp_no, not bool_or(is_unresolved_high_severity) as done
    from base
    group by emp_no
  ),
  filtered as (
    select ca.emp_no, ca.emp_name, ca.codes, ca.total, coalesce(sa.done, true) as done
    from codes_agg ca
    left join status_agg sa on sa.emp_no = ca.emp_no
    where p_search is null or p_search = ''
       or ca.emp_name ilike '%' || p_search || '%'
       or ca.emp_no ilike '%' || p_search || '%'
  ),
  total_count as (select count(*) as n from filtered),
  paged as (
    select * from filtered
    order by
      case when v_desc then null else
        case v_sort
          when 'emp_name' then emp_name
          when 'emp_no'   then emp_no
        end
      end asc nulls last,
      case when v_desc then
        case v_sort
          when 'emp_name' then emp_name
          when 'emp_no'   then emp_no
        end
      end desc nulls last,
      case when v_sort = 'total' and not v_desc then total end asc nulls last,
      case when v_sort = 'total' and v_desc     then total end desc nulls last,
      emp_no
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total_count),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'empNo', emp_no, 'empName', emp_name, 'eventCodes', codes,
        'total', total, 'done', done
      ))
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;

revoke all on function public.dds_metrics from public;
grant execute on function public.dds_metrics to authenticated;
revoke all on function public.dds_asset_event_summary from public;
grant execute on function public.dds_asset_event_summary to authenticated;
revoke all on function public.dds_driver_event_summary from public;
grant execute on function public.dds_driver_event_summary to authenticated;
