-- ============================================================================
-- DDS — 0028_dds_metrics_emp_no
-- ----------------------------------------------------------------------------
-- PHASE 4 of the employee-number identity work begun in 0018_driver_masterlist
-- ("dds_metrics()/derive() switch to grouping by emp_no", deferred at the time
-- because nothing yet populated emp_no reliably). It is done now because it
-- no longer is deferred: 0024_minestat added the (asset_id, shift_date,
-- shift) join that resolves emp_no from MineStat data, and the client wiring
-- that actually calls it after a DDS upload ships alongside this migration.
-- Without this half of the fix, emp_no would be populated correctly and every
-- chart on screen would keep ignoring it.
--
-- THE BUG THIS FIXES
--   Every driver-facing metric — topOperators, operatorConsistency, and
--   kpis.distinctOperators — has always grouped by the RAW `operator` text
--   column, never by emp_no. This is the exact problem 0018's own header
--   describes: "DELA CRUZ, JUAN", "Dela Cruz Juan", "DELACRUZ, J." and
--   "DE LA CRUZ, JUAN JR" are four different drivers in every number the app
--   produces, which is precisely what dilutes the high-consistency flag this
--   whole feature exists to make trustworthy.
--
-- THE UNSPECIFIED-SENTINEL DESIGN
--   Reproduces dds_metrics()'s entire body from 0025_dds_metrics_dow.sql
--   verbatim except the operator-keyed CTEs, which now group on
--   coalesce(e.emp_no, 'UNSPECIFIED') — a literal sentinel string, chosen
--   because it can never collide with a real emp_no (those come from the
--   conso and are never literally the word UNSPECIFIED).
--
--   This also fixes a pre-existing asymmetry: operator_all used to say
--   `where operator is not null`, silently DROPPING every null-operator row
--   from topOperators/operatorConsistency, while operator_days/
--   operator_code_counts/operator_last_alert instead coalesced null to
--   'Unspecified' and kept the row. Grouping on the emp_no sentinel is
--   symmetric across every CTE: nothing is ever dropped, and the unattributed
--   slice of history collapses into ONE clean bucket instead of fragmenting
--   across however many raw-text spellings (or one 'Unspecified' vs the
--   dropped-entirely null rows) happened to exist before. An unattributed
--   alert is still visibly unattributed — just as one bucket, not scattered
--   evidence that looks like many different unmatched people.
--
-- DISPLAY NAME, NOT BARE emp_no
--   The 'id' field client code already renders directly as a driver's name in
--   every table/chart. Changing it to a bare emp_no would silently break
--   every one of those renders. Instead this joins to public.drivers and
--   returns full_name — the masterlist's real name, resolved once no matter
--   how many different raw spellings fed into that employee's alerts — with
--   'Unspecified' for the sentinel bucket and a bare emp_no fallback for the
--   rare case of an emp_no whose driver row was since removed (a masterlist
--   should never remove rows in normal operation, see 0018 — deactivate,
--   don't delete — so this is defence-in-depth, not an expected path).
--
-- kpis.distinctOperators NOW COUNTS REAL DRIVERS ONLY
--   Previously `count(distinct operator) filter (where operator is not
--   null)`. "Distinct operators" has always meant distinct PEOPLE; the
--   Unspecified bucket is not a person, so it is explicitly excluded here
--   rather than counted as one more "operator" the way a stray raw-text
--   spelling used to be.
--
-- recentAlerts IS UNCHANGED ON PURPOSE
--   It is a per-row listing, not an aggregation — no fragmentation risk from
--   raw operator text there, and changing its shape is an unrelated concern
--   outside this migration's scope.
-- ============================================================================

create or replace function public.dds_metrics(
  p_from            date    default null,
  p_to              date    default null,
  p_shift           text    default null,   -- 'DAY' | 'NIGHT' | null
  p_asset_ids       text[]  default null,
  p_event_codes     text[]  default null,
  p_actionable_only boolean default false
)
returns jsonb
language plpgsql
stable
security invoker            -- RLS still applies; this is not a bypass
set search_path = public
as $$
declare
  result jsonb;
  v_high_day_threshold constant integer := 10;
  v_recent_limit       constant integer := 8;
  c_unspecified        constant text    := 'UNSPECIFIED';
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
           avg(sync_seconds)         as avg_sync_seconds
    from filtered group by shift_date order by shift_date
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
    select o.emp_key,
           sum(f.event_count)                                           as total,
           coalesce(sum(f.event_count) filter (where f.actionable), 0)   as actionable,
           coalesce(sum(f.event_count) filter (where not f.actionable), 0) as non_actionable,
           count(distinct f.shift_date)                                  as active_days,
           coalesce(hd.high_days, 0)                                     as high_days
    from (select distinct coalesce(emp_no, c_unspecified) as emp_key from filtered) o
    join filtered f on coalesce(f.emp_no, c_unspecified) = o.emp_key
    left join (
      select emp_key, count(*) as high_days
      from operator_days where day_total > v_high_day_threshold group by emp_key
    ) hd on hd.emp_key = o.emp_key
    group by o.emp_key, hd.high_days
  ),
  top_assets as (
    select * from asset_all order by total desc, asset_id limit 10
  ),
  top_operators as (
    select o.*, pc.primary_event_code, la.last_alert_time,
           -- 'Unspecified' for the sentinel bucket, the masterlist's real
           -- name when one resolves, and a bare emp_no fallback for the rare
           -- case of an emp_no whose driver row no longer exists (drivers are
           -- deactivated, never deleted, by 0018's own design — so this is
           -- defence-in-depth, not an expected path).
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
      'filters', jsonb_build_object(
        'from', p_from, 'to', p_to, 'shift', p_shift,
        'assetIds', coalesce(to_jsonb(p_asset_ids), '[]'::jsonb),
        'eventCodes', coalesce(to_jsonb(p_event_codes), '[]'::jsonb),
        'actionableOnly', p_actionable_only
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
          then (k.actionable_alerts::numeric / k.total_alerts) * 100 else 0 end
    ),
    'trend', coalesce((
      select jsonb_agg(jsonb_build_object(
        'date',   to_char(shift_date, 'MM/DD/YYYY'),
        'units',  units, 'events', events, 'assets', assets,
        'avgSyncSeconds', avg_sync_seconds
      ) order by shift_date) from trend), '[]'::jsonb),
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

    -- Full (uncapped) per-entity breakdown — feeds the Driver & Asset
    -- Monitoring page. RAW NUMBERS ONLY as of this migration: no
    -- severity/severityRank/flagged. Those are now computed client-side
    -- (applySeverity()/SEVERITY_BANDS in index.html) from the SAME
    -- highDayRatio this still returns, then upserted straight to
    -- driver_asset_severity — see that table's own section above — rather
    -- than recomputed a second, independent way here. Sort order changed
    -- from severity-first to highDayRatio-first: the underlying signal
    -- driving both is identical, just no longer bucketed at this layer.
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
  from kpis k, bucket_array b;

  return result;
end;
$$;
