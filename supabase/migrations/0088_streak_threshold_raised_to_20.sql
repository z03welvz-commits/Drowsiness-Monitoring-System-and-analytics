-- ============================================================================
-- DDS — 0088_streak_threshold_raised_to_20
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- NOTE: dds_driver_streaks() and dds_driver_asset_weekly() already carry this
-- change in this local tree (see 0082_driver_streaks_status_and_open_count.sql,
-- whose header documents the resync, and 0084_driver_asset_weekly_actioned_status.sql
-- above, both of which use `day_total >= 20`). This file exists only to record
-- the third call site: dds_current_streak()'s p_day_threshold default, which
-- previously was presumably 10 to match the old per-day qualifying count and
-- is now 20 — used by dds_entity_status_reopen() to decide whether a fresh
-- streak reopens an 'actioned'/'monitoring' entity_status back to 'required'.
-- ============================================================================

create or replace function public.dds_current_streak(
  p_entity_type text,
  p_entity_id text,
  p_day_threshold integer default 20,
  p_lookback_days integer default 90
)
returns integer
language sql
stable
set search_path to 'public'
as $function$
  with entity_days as (
    select shift_date, sum(event_count) as day_total
    from public.events
    where (p_entity_type = 'driver' and coalesce(emp_no, 'UNSPECIFIED') = p_entity_id)
       or (p_entity_type = 'asset' and asset_id = p_entity_id)
    group by shift_date
  ),
  last_day as (
    select max(shift_date) as d from entity_days
  ),
  cal as (
    select generate_series(
      (select d from last_day) - (greatest(coalesce(p_lookback_days, 90), 1) - 1) * interval '1 day',
      (select d from last_day),
      interval '1 day'
    )::date as cal_date
  ),
  joined as (
    select cal.cal_date,
           (coalesce(ed.day_total, 0) >= coalesce(p_day_threshold, 20)) as qualifies
    from cal
    left join entity_days ed on ed.shift_date = cal.cal_date
  ),
  ranked as (
    select row_number() over (order by cal_date desc) as rn, qualifies
    from joined
  ),
  first_break as (
    select min(rn) as rn from ranked where not qualifies
  )
  select coalesce(
    case
      when (select rn from first_break) is null then (select count(*) from ranked)
      else (select rn from first_break) - 1
    end,
    0
  );
$function$;
