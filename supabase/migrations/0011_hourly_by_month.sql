-- ============================================================================
-- DDS — 0011_hourly_by_month
-- ----------------------------------------------------------------------------
-- Adds a new `hourlyByMonth` array: one 24-hour bucket set per calendar
-- month present in the filtered range, so the client's Alert Activity by
-- Hour chart can plot one line per month (charts.hourlyMonthly() in
-- index.html) instead of the existing Day/Night shift split. The existing
-- `hourly` field (DAY/NIGHT, 24 buckets each) is left completely untouched —
-- several other consumers (insightBullets.peakHour, CSV export, the
-- describe.hourly a11y entry) still read that shape unchanged, so this is a
-- new, additive field alongside it, not a replacement.
--
-- Month grouping uses UTC (date_trunc('month', start_time)), matching the
-- client's own hourlyByMonth accumulator in derive() (keyed off
-- _startTime.getUTCFullYear()/getUTCMonth(), the same UTC clock _startHour
-- already reads from — see that field's own comment in annotate()). Key
-- format is 'YYYY-MM', matching the client's own key shape exactly so the
-- JSON round-trips into the identical object shape derive() produces.
--
-- DO NOT add `at time zone 'utc'` here. events.start_time is a naive
-- `timestamp` already holding UTC, so no conversion is needed to get a UTC
-- month. Worse, the conversion is actively wrong: `AT TIME ZONE 'utc'`
-- promotes the naive value to timestamptz, which date_trunc/to_char then
-- render in the SESSION's TimeZone — while the hour bucket beside it
-- (extract(hour from start_time)) stays naive. The two halves of the same
-- bucket would then read different clocks, filing rows near a month
-- boundary under the wrong month and disagreeing with the client's
-- getUTCMonth() key under any non-UTC session TimeZone.
--
-- Only additive: every field dds_metrics() already returned is unchanged.
-- Based on 0010_trend_sync.sql's full body (the latest known-good
-- definition — no migration between it and this one touches dds_metrics()),
-- same "verify against the live pg_get_functiondef before applying" caveat
-- 0006/0010 both carried, in case of further undocumented drift.
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
      count(distinct operator) filter (where operator is not null)     as distinct_operators,
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
    select shift,
           sum(event_count)         as units,
           count(distinct asset_id) as assets
    from filtered group by shift
  ),

  by_code as (
    select event_code,
           sum(event_count) as units,
           count(*)         as events
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

  -- One row per (calendar month, hour-of-day) present in the filtered
  -- range — the source for the new hourlyByMonth array below. Month key
  -- read straight off the naive-UTC start_time to match the client's own
  -- grouping and the hour bucket beside it — no timezone conversion (see
  -- header comment). Only months/hours that actually have data get a row here;
  -- the JSON assembly below fills in the missing hours as 0 per month via
  -- the same generate_series(0,23) x months cross join pattern the
  -- existing `hourly` CTE uses for its own dense 0..23 array.
  months as (
    select distinct to_char(date_trunc('month', f.start_time), 'YYYY-MM') as month_key
    from filtered f
  ),
  hourly_by_month as (
    select to_char(date_trunc('month', f.start_time), 'YYYY-MM') as month_key,
           extract(hour from f.start_time)::int as h,
           sum(f.event_count) as units
    from filtered f
    group by 1, 2
  ),

  sync_buckets as (
    select
      case
        when sync_seconds < 10800 then 0   -- <3h
        when sync_seconds < 21600 then 1   -- 3-6h
        when sync_seconds < 28800 then 2   -- 6-8h
        when sync_seconds < 36000 then 3   -- 8-10h
        else 4                             -- 10h+
      end as bucket,
      actionable,
      count(*) as n
    from filtered where sync_seconds is not null
    group by 1, 2
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
      actionable,
      count(*) as n
    from filtered group by 1, 2
  ),

  -- Per-asset / per-operator rollups, each carrying its distinct active-day
  -- count. asset_all/operator_all are the FULL (uncapped) versions that feed
  -- assetConsistency/operatorConsistency; top_assets/top_operators stay
  -- capped at 10 for the existing topAssets/topOperators fields.
  asset_all as (
    select asset_id,
           sum(event_count)                                           as total,
           coalesce(sum(event_count) filter (where actionable), 0)     as actionable,
           coalesce(sum(event_count) filter (where not actionable), 0) as non_actionable,
           count(distinct shift_date)                                  as active_days
    from filtered group by asset_id
  ),
  operator_all as (
    select operator,
           sum(event_count)                                           as total,
           coalesce(sum(event_count) filter (where actionable), 0)     as actionable,
           coalesce(sum(event_count) filter (where not actionable), 0) as non_actionable,
           count(distinct shift_date)                                  as active_days
    from filtered where operator is not null
    group by operator
  ),

  -- Separate from operator_all: topOperators (existing field, pre-dating
  -- this migration) has always excluded blank/null OPERATOR entirely, and
  -- that long-standing behavior is left untouched here. operatorConsistency
  -- is a NEW field with no such precedent, so it must match dds-state.js's
  -- withConsistency() exactly — which buckets a blank/missing OPERATOR
  -- under the literal 'Unspecified' (UNSPECIFIED_OPERATOR) rather than
  -- dropping those rows.
  --
  -- Per-day totals (one row per asset_id/operator x shift_date) are needed
  -- here — not just the per-entity total above — because the flag counts
  -- how many INDIVIDUAL DAYS exceeded the threshold, which asset_all/
  -- operator_all's single summed total per entity can't answer.
  asset_days as (
    select asset_id, shift_date, sum(event_count) as day_total
    from filtered group by asset_id, shift_date
  ),
  operator_days as (
    select coalesce(nullif(operator, ''), 'Unspecified') as operator,
           shift_date, sum(event_count) as day_total
    from filtered group by 1, shift_date
  ),

  asset_consistency_all as (
    select a.asset_id, a.total, a.actionable, a.non_actionable, a.active_days,
           coalesce(hd.high_days, 0) as high_days
    from asset_all a
    left join (
      select asset_id, count(*) as high_days
      from asset_days where day_total > v_high_day_threshold
      group by asset_id
    ) hd on hd.asset_id = a.asset_id
  ),
  operator_consistency_all as (
    select o.operator,
           sum(f.event_count)                                           as total,
           coalesce(sum(f.event_count) filter (where f.actionable), 0)   as actionable,
           coalesce(sum(f.event_count) filter (where not f.actionable), 0) as non_actionable,
           count(distinct f.shift_date)                                  as active_days,
           coalesce(hd.high_days, 0)                                     as high_days
    from (select distinct coalesce(nullif(operator, ''), 'Unspecified') as operator from filtered) o
    join filtered f on coalesce(nullif(f.operator, ''), 'Unspecified') = o.operator
    left join (
      select operator, count(*) as high_days
      from operator_days where day_total > v_high_day_threshold
      group by operator
    ) hd on hd.operator = o.operator
    group by o.operator, hd.high_days
  ),

  top_assets as (
    select * from asset_all order by total desc, asset_id limit 10
  ),

  top_operators as (
    select * from operator_all order by total desc, operator limit 10
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

    -- One entry per calendar month, sorted chronologically ('YYYY-MM'
    -- sorts correctly as a plain string) — mirrors derive()'s own
    -- hourlyByMonth shape exactly: [{ month: 'YYYY-MM', hours: number[24] }].
    -- Dense 0..23 per month via the same hours(h) x months cross join the
    -- existing `hourly` CTE already uses for its own dense array, so a
    -- month with no events in a given hour still reports 0, not a missing
    -- array slot.
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
        'id', operator, 'total', total,
        'actionable', actionable, 'nonActionable', non_actionable,
        'activeDays', active_days
      ) order by total desc, operator) from top_operators), '[]'::jsonb),

    -- Full (uncapped) per-entity breakdown, sorted flagged-first — feeds
    -- the Driver & Asset Monitoring page. flagged = true when highDays is
    -- MORE THAN HALF of activeDays (mirrors withConsistency() in
    -- dds-state.js / index.html exactly, including the tie-break order).
    'assetConsistency', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', asset_id, 'total', total,
        'actionable', actionable, 'nonActionable', non_actionable,
        'activeDays', active_days,
        'highDays', high_days,
        'highDayRatio', case when active_days > 0
          then (high_days::numeric / active_days) * 100 else 0 end,
        'flagged', active_days > 0 and high_days::numeric / active_days > 0.5,
        'consistencyRate', total::numeric / greatest(active_days, 1),
        'actionableRatio', case when total > 0
          then (actionable::numeric / total) * 100 else 0 end
      ) order by
        (active_days > 0 and high_days::numeric / active_days > 0.5) desc,
        (case when active_days > 0 then (high_days::numeric / active_days) else 0 end) desc,
        (total::numeric / greatest(active_days, 1)) desc,
        asset_id)
      from asset_consistency_all), '[]'::jsonb),

    'operatorConsistency', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', operator, 'total', total,
        'actionable', actionable, 'nonActionable', non_actionable,
        'activeDays', active_days,
        'highDays', high_days,
        'highDayRatio', case when active_days > 0
          then (high_days::numeric / active_days) * 100 else 0 end,
        'flagged', active_days > 0 and high_days::numeric / active_days > 0.5,
        'consistencyRate', total::numeric / greatest(active_days, 1),
        'actionableRatio', case when total > 0
          then (actionable::numeric / total) * 100 else 0 end
      ) order by
        (active_days > 0 and high_days::numeric / active_days > 0.5) desc,
        (case when active_days > 0 then (high_days::numeric / active_days) else 0 end) desc,
        (total::numeric / greatest(active_days, 1)) desc,
        operator)
      from operator_consistency_all), '[]'::jsonb)
  )
  into result
  from kpis k, bucket_array b;

  return result;
end;
$$;

revoke all on function public.dds_metrics from public;
grant execute on function public.dds_metrics to authenticated;
