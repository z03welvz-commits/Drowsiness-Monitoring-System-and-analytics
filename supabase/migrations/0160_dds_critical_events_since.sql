-- ============================================================================
-- DDS — 0160_dds_critical_events_since
-- ----------------------------------------------------------------------------
-- Read-only RPC for the critical-alert-digest Edge Function: every critical
-- event (event_code ilike '%sleep%' — the same severity rule already used
-- throughout this app, e.g. dds_alert_logs()'s v_severity = 'critical'
-- branch, 0156_alert_logs_driver_case_status.sql) newer than p_since,
-- joined to driver name the same way public.dds_case_records already
-- resolves it (masterlist name, falling back through case override / raw
-- operator text / MineStat raw name — see 0094's driver_display column).
-- No new severity or name-resolution logic — this only re-exposes what
-- already exists, filtered and shaped for an email digest.
--
-- security definer for the same reason dds_metrics() and every other read
-- RPC in this app is: it reads across events/alert_cases/drivers/
-- minestat_shifts directly, rather than relying on each table's own RLS.
-- The Edge Function itself calls this with the service-role key (it holds
-- no user session — it runs on a schedule, not on behalf of a signed-in
-- person), which bypasses grants entirely; execute is still revoked from
-- anon and granted only to authenticated so this can't be called
-- unauthenticated directly via PostgREST — this returns driver names, the
-- same PII bar every other read RPC in this app already sits behind.
-- ============================================================================

create or replace function public.dds_critical_events_since(p_since timestamptz)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'eventId', event_id,
    'startTime', to_char(start_time, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'assetId', asset_id,
    'driverDisplayName', driver_display,
    'empNo', emp_no_display,
    'eventCode', event_code,
    'eventCount', event_count,
    'shift', shift,
    'shiftDate', shift_date
  ) order by start_time asc), '[]'::jsonb)
  from public.dds_case_records
  where event_code ilike '%sleep%'
    and start_time > p_since;
$$;

revoke all on function public.dds_critical_events_since(timestamptz) from public;
revoke all on function public.dds_critical_events_since(timestamptz) from anon;
grant execute on function public.dds_critical_events_since(timestamptz) to authenticated;
