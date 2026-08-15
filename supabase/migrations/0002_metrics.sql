-- ============================================================================
-- DDS — 0002_metrics
-- ----------------------------------------------------------------------------
-- Returns EXACTLY the shape of derive() in dds-state.js. The frontend swaps
-- store.load() for store.fetchMetrics() and nothing downstream changes —
-- charts, KPIs, and the a11y tables all consume the same object.
--
-- Measured baseline: the JS pipeline needs ~10.8s and 926MB for 1M rows.
-- This does the same work in one indexed pass and returns ~4KB, because
-- `derived` does not grow with row count.
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
begin
  -- Defence in depth. RLS already blocks the rows, but failing loudly beats
  -- returning a plausible-looking empty dashboard.
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
      avg(sync_seconds)                                                as avg_sync_seconds,
      coalesce(sum(event_count) filter (where actionable), 0)          as actionable_alerts,
      count(*)                                                         as row_count
    from filtered
  ),

  trend as (
    select shift_date,
           sum(event_count)          as units,
           count(*)                  as events,
           count(distinct asset_id)  as assets
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

  -- Dense 0..23 so the client always receives 24 slots, even for hours with
  -- no events. A sparse array would misalign every hourly chart.
  hours as (select generate_series(0, 23) as h),
  hourly as (
    select h.h,
           coalesce(sum(f.event_count) filter (where f.shift = 'DAY'),   0) as day_units,
           coalesce(sum(f.event_count) filter (where f.shift = 'NIGHT'), 0) as night_units
    from hours h
    left join filtered f on extract(hour from f.start_time)::int = h.h
    group by h.h order by h.h
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

  top_assets as (
    select asset_id,
           sum(event_count)                                       as total,
           coalesce(sum(event_count) filter (where actionable), 0) as actionable,
           coalesce(sum(event_count) filter (where not actionable), 0) as non_actionable
    from filtered group by asset_id order by 2 desc, asset_id limit 10
  ),

  top_operators as (
    select operator, sum(event_count) as total
    from filtered where operator is not null
    group by operator order by 2 desc, operator limit 10
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
      -- Unclassified rows are rejected at import and never reach this table,
      -- so these are structurally always 0 / true. Kept in the shape so the
      -- client contract is identical for locally-parsed and server data.
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
      'totalAlerts',     k.total_alerts,
      'distinctAssets',  k.distinct_assets,
      'avgSyncSeconds',  k.avg_sync_seconds,
      'actionableRatio',
        case when k.total_alerts > 0
          then (k.actionable_alerts::numeric / k.total_alerts) * 100 else 0 end
    ),

    'trend', coalesce((
      select jsonb_agg(jsonb_build_object(
        -- MM/DD/YYYY to match parseDateTime()'s expected format exactly.
        'date',   to_char(shift_date, 'MM/DD/YYYY'),
        'units',  units, 'events', events, 'assets', assets
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

    'syncBuckets', jsonb_build_object(
      'labels', '["<3h","3-6h","6-8h","8-10h","10h+"]'::jsonb,
      'actionable', b.sync_act, 'nonActionable', b.sync_non),

    'alertBuckets', jsonb_build_object(
      'labels', '["<5","5-10","10-15","15-20","20+"]'::jsonb,
      'actionable', b.alert_act, 'nonActionable', b.alert_non),

    'topAssets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', asset_id, 'total', total,
        'actionable', actionable, 'nonActionable', non_actionable
      ) order by total desc, asset_id) from top_assets), '[]'::jsonb),

    'topOperators', coalesce((
      select jsonb_agg(jsonb_build_object('id', operator, 'total', total)
        order by total desc, operator) from top_operators), '[]'::jsonb)
  )
  into result
  from kpis k, bucket_array b;

  return result;
end;
$$;

revoke all on function public.dds_metrics from public;
grant execute on function public.dds_metrics to authenticated;

-- ── Ingest ─────────────────────────────────────────────────────────────────
-- Called by the import worker with rows that already passed client-side
-- parsing. Rows whose timestamps cannot be parsed are rejected BEFORE this
-- point (agreed rule), so anything arriving here is expected to be valid;
-- malformed input still raises rather than silently inserting nulls.

create or replace function public.dds_ingest(
  p_import_id uuid,
  p_rows      jsonb        -- [{ UPDATE_TIME, START_TIME, END_TIME, ASSET_ID, ... }]
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inserted integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  if not exists (select 1 from public.imports where id = p_import_id) then
    raise exception 'UNKNOWN_IMPORT';
  end if;

  insert into public.events (
    import_id, update_time, start_time, end_time,
    asset_id, event_code, event_count, operator
  )
  select
    p_import_id,
    to_timestamp(r->>'UPDATE_TIME', 'MM/DD/YYYY HH24:MI:SS')::timestamp,
    to_timestamp(r->>'START_TIME',  'MM/DD/YYYY HH24:MI:SS')::timestamp,
    case when nullif(r->>'END_TIME', '') is not null
      then to_timestamp(r->>'END_TIME', 'MM/DD/YYYY HH24:MI:SS')::timestamp end,
    r->>'ASSET_ID',
    r->>'EVENT_CODE',
    coalesce((r->>'EVENT_COUNT')::integer, 0),
    nullif(r->>'OPERATOR', '')
  from jsonb_array_elements(p_rows) r
  on conflict (asset_id, start_time, event_code) do nothing;

  get diagnostics v_inserted = row_count;

  update public.imports
     set row_count = row_count + v_inserted,
         status = 'complete',
         completed_at = now()
   where id = p_import_id;

  return v_inserted;
end;
$$;

revoke all on function public.dds_ingest from public;
grant execute on function public.dds_ingest to authenticated;
