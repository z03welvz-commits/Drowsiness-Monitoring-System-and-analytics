-- ============================================================================
-- DDS — asset_alert_instances_driver_name
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time (which also folds in the later
-- asset_alert_instances_expose_needs_review touch below), not necessarily
-- the original diff.
--
-- Inferred intent: dds_asset_alert_instances()'s rows payload previously
-- likely lacked a driverName field (its sibling dds_driver_alert_instances
-- doesn't need one — the driver is already the query parameter — but the
-- asset-scoped instances popup needs to show who was operating during each
-- event). The live definition adds 'driverName', r.driver_display sourced
-- from dds_case_records.driver_display, which already coalesces
-- case-logged name, resolved driver name, raw event operator text, and the
-- MineStat raw-name fallback (see case_records_minestat_raw_name_fallback).
-- ============================================================================

create or replace function public.dds_asset_alert_instances(
  p_asset_id text,
  p_from date default null,
  p_to date default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 100), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'assetId', p_asset_id,
    'total', coalesce((
      select sum(r.event_count) from public.dds_case_records r
      where r.asset_id = p_asset_id
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
    ), 0),
    'rowCount', coalesce((
      select count(*) from public.dds_case_records r
      where r.asset_id = p_asset_id
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
    ), 0),
    'avgSyncSeconds', (
      select avg(r.sync_seconds)::int from public.dds_case_records r
      where r.asset_id = p_asset_id
        and r.sync_seconds is not null
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
    ),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'eventId',    r.event_id,
        'shiftDate',  to_char(r.shift_date, 'MM/DD/YYYY'),
        'shift',      r.shift,
        'startTime',  to_char(r.start_time, 'MM/DD/YYYY HH24:MI:SS'),
        'endTime',    to_char(r.end_time, 'MM/DD/YYYY HH24:MI:SS'),
        'updateTime', to_char(r.update_time, 'MM/DD/YYYY HH24:MI:SS'),
        'eventCode',  r.event_code,
        'eventCount', r.event_count,
        'empNo',      r.emp_no_display,
        'driverName', r.driver_display,
        'needsReview', r.driver_needs_review
      ) order by r.start_time desc, r.event_id desc)
      from (
        select * from public.dds_case_records r2
        where r2.asset_id = p_asset_id
          and (p_from is null or r2.shift_date >= p_from)
          and (p_to   is null or r2.shift_date <= p_to)
        order by r2.start_time desc, r2.event_id desc
        limit v_limit offset v_offset
      ) r
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;
