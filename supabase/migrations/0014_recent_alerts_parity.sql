-- ============================================================================
-- DDS — 0014_recent_alerts_parity
-- ----------------------------------------------------------------------------
-- Closes the last shape gap between derive() in dds-state.js and dds_metrics()
-- in Postgres. Three fields existed only on the local-import path:
--
--   recentAlerts                    (top-level; SQL had no equivalent at all)
--   topOperators[].primaryEventCode
--   topOperators[].lastAlertTime
--
-- WHY THIS MATTERS EVEN THOUGH NOTHING RENDERS THEM TODAY. Both consumers —
-- charts.recentAlerts() and charts.topOperators() — are currently unreachable
-- from any PAGES entry (see their own comments in index.html: "Currently
-- unused by any PAGES entry... left in place rather than deleted since prior
-- redesign passes on this page have added widgets back after removing them").
--
-- That is exactly the trap. The renderers read `d.recentAlerts ?? []`, so
-- re-enabling either widget would silently show an EMPTY list when signed in
-- and a populated one after a local import — no error, no warning, just two
-- different answers depending on how the data arrived. The whole design rule
-- of the API contract is that the two paths return the same shape; a field
-- that only one path produces is a latent bug waiting for the next redesign
-- pass to trip over it.
--
-- ── recentAlerts: a row list, not an aggregate ──────────────────────────────
-- Every other field dds_metrics() returns is an aggregate whose size is fixed
-- regardless of row count — that flatness is the entire premise of
-- DDS_SCALING_PLAN.md ("derived is flat... 100x the rows produced 0.3 KB more
-- output"). recentAlerts is the one exception: it returns individual rows.
--
-- It is safe here ONLY because it is hard-capped at 8 rows, matching
-- derive()'s own `.slice(0, 8)`. That cap is load-bearing, not cosmetic — it
-- is what keeps the response flat. Do not parameterise it into a caller-
-- supplied limit; an unbounded row fetch is precisely the payload the scaling
-- plan says must never reach the browser, and this function has no paging.
--
-- ── Ordering must match derive() exactly ────────────────────────────────────
-- derive() sorts by _startTime descending, breaking ties on ASSET_ID:
--     .sort((a, b) => b._startTime - a._startTime ||
--        String(field(a,'ASSET_ID')).localeCompare(String(field(b,'ASSET_ID'))))
-- Mirrored below as `order by start_time desc, asset_id`. Without the
-- secondary key, two rows sharing a millisecond could come back in either
-- order and the two engines would disagree on which 8 rows are "the most
-- recent" — the same tie-break reasoning 0002_metrics.sql already applies to
-- topAssets/topOperators.
--
-- ── Timestamp format ────────────────────────────────────────────────────────
-- derive() emits `_startTime.toISOString()`, e.g. 2025-03-10T23:30:00.000Z.
-- to_char with the same mask reproduces it. events.start_time is a naive
-- `timestamp` already holding UTC (see 0001_init.sql's time-semantics note),
-- so NO `at time zone` conversion is applied — adding one would promote it to
-- timestamptz and render it in the session's TimeZone, which is the identical
-- trap 0011's header documents for the hourlyByMonth month key.
--
-- ── Unspecified operator ────────────────────────────────────────────────────
-- derive() falls back to UNSPECIFIED_OPERATOR ('Unspecified') for a blank or
-- missing OPERATOR. recentAlerts.operator and primaryEventCode's tally below
-- both apply the same coalesce(nullif(operator,''), 'Unspecified') that
-- operator_days already uses in 0011.
--
-- Note topOperators itself still EXCLUDES null operators entirely (0011's
-- operator_all has `where operator is not null`) — long-standing behavior,
-- deliberately left alone here. Only the two NEW per-operator fields are
-- added; which operators appear in the list does not change.
--
-- Only additive: every field dds_metrics() already returned is unchanged.
-- Based on 0011_hourly_by_month.sql's full body (the latest known-good
-- definition — no migration between it and this one touches dds_metrics()),
-- same "verify against the live pg_get_functiondef before applying" caveat
-- 0006/0010/0011 all carried, in case of further undocumented drift.
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
  -- Mirrors derive()'s `.slice(0, 8)`. See header: this cap is what keeps the
  -- response flat, and must not become a caller-supplied parameter.
  v_recent_limit       constant integer := 8;
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

  -- NEW (this migration): per-operator EVENT_CODE tally and most recent
  -- alert time, feeding topOperators[].primaryEventCode / .lastAlertTime.
  --
  -- derive() counts ROWS per code (`o.codeCounts[code] = ... + 1`), not summed
  -- EVENT_COUNT — a code appearing on 3 rows of 1 alert each outranks one
  -- appearing on a single row of 50. count(*) below matches that deliberately;
  -- sum(event_count) here would produce a different "primary" code and break
  -- parity in a way no test would catch unless it had a fixture where the two
  -- disagree.
  operator_code_counts as (
    select coalesce(nullif(operator, ''), 'Unspecified') as operator,
           event_code,
           count(*) as code_rows
    from filtered
    where event_code is not null
    group by 1, 2
  ),
  -- Ties broken on event_code ascending, mirroring derive()'s
  -- `b[1] - a[1] || a[0].localeCompare(b[0])`, so two codes with equal row
  -- counts resolve to the same winner in both engines.
  operator_primary_code as (
    select distinct on (operator) operator, event_code as primary_event_code
    from operator_code_counts
    order by operator, code_rows desc, event_code
  ),
  operator_last_alert as (
    select coalesce(nullif(operator, ''), 'Unspecified') as operator,
           max(start_time) as last_alert_time
    from filtered
    group by 1
  ),

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

  -- Joins the two new per-operator CTEs onto the existing capped top-10.
  -- LEFT joins: an operator with no non-null event_code has no row in
  -- operator_primary_code, and must still appear with primaryEventCode null
  -- (derive() emits null there too, via `codes.length ? ... : null`).
  top_operators as (
    select o.*, pc.primary_event_code, la.last_alert_time
    from (select * from operator_all order by total desc, operator limit 10) o
    left join operator_primary_code pc on pc.operator = o.operator
    left join operator_last_alert    la on la.operator = o.operator
  ),

  -- NEW (this migration): the 8 most recent individual rows. See header on
  -- why this is the one non-aggregate field and why the cap is load-bearing.
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

    -- primaryEventCode / lastAlertTime are NEW here; every other key is
    -- carried over from 0011 unchanged.
    'topOperators', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', operator, 'total', total,
        'actionable', actionable, 'nonActionable', non_actionable,
        'activeDays', active_days,
        'primaryEventCode', primary_event_code,
        'lastAlertTime', case when last_alert_time is not null
          then to_char(last_alert_time, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') end
      ) order by total desc, operator) from top_operators), '[]'::jsonb),

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
      from operator_consistency_all), '[]'::jsonb),

    -- NEW (this migration). Mirrors derive()'s recentAlerts exactly:
    -- newest first, tie-broken on asset id, capped at 8, with the blank
    -- OPERATOR falling back to 'Unspecified'. `count` is EVENT_COUNT for
    -- that single row, not a sum — this is a log view, not an aggregate.
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

revoke all on function public.dds_metrics from public;
grant execute on function public.dds_metrics to authenticated;
