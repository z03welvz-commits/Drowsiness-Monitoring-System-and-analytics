-- ============================================================================
-- DDS — 0165_dds_driver_alert_totals_all
-- ----------------------------------------------------------------------------
-- The Analytics "Alerts by Driver" -> View all modal (added this session)
-- needs EVERY driver matching the page's current filters, not just a top-N
-- page — but dds_driver_event_summary() (0143) is the wrong tool for that:
-- its per-driver `codes` field needs a nested aggregation (group by driver
-- AND event_code, then re-aggregate into one jsonb array per driver), and
-- its p_limit is clamped to 200 server-side, so getting "everyone" meant
-- paging through it client-side — RE-RUNNING that whole expensive nested
-- aggregation from scratch on every page, since p_limit/p_offset are only
-- applied at the very end, after the full aggregation already ran.
--
-- Confirmed live: a single 200-row page of dds_driver_event_summary(),
-- all-time, no filters, already takes ~4.5s (EXPLAIN ANALYZE, 108k buffer
-- hits) — paging through it for the live driver count (734) multiplies
-- that cost per page and was timing out in production ("canceling
-- statement due to statement timeout").
--
-- This function skips the per-event-code breakdown entirely — the totals
-- report doesn't need it, only empNo/empName/total — which removes the
-- nested aggregation. Confirmed live: the equivalent single-pass query
-- (one group by emp_no, emp_name) runs in ~280ms for the same all-time,
-- no-filter case and returns all 734 drivers directly, so this needs no
-- pagination at all — one call returns everyone. The 5000-row cap is a
-- sanity ceiling (over 6x the live driver count), never a real limit.
--
-- Same filter predicates as dds_driver_event_summary() (0143) so this
-- always narrows in lockstep with the panel it's attached to. Deliberately
-- does NOT filter out the 'UNSPECIFIED' emp_no_norm sentinel row server-
-- side — the client already does that (same as fetchTopDrivers() already
-- does for the top-6 panel), so this stays consistent with the existing
-- pattern rather than duplicating that sentinel string into SQL too.
-- ============================================================================

create or replace function public.dds_driver_alert_totals_all(
  p_from date default null,
  p_to date default null,
  p_shift text default null,
  p_asset_id text default null,
  p_event_code text default null,
  p_hour integer default null,
  p_sync_bucket integer default null,
  p_emp_no text default null
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
set work_mem to '64MB'
as $function$
declare
  result jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with base as (
    select
      r.emp_no_norm as emp_no,
      coalesce(r.emp_name, case when r.emp_no is null then 'Unspecified' else r.emp_no end) as emp_name,
      r.event_count
    from public.dds_case_records r
    where (p_from is null or r.shift_date >= p_from)
      and (p_to   is null or r.shift_date <= p_to)
      and (p_shift is null or p_shift = '' or r.shift = p_shift)
      and (p_asset_id is null or r.asset_id = p_asset_id)
      and (p_event_code is null or r.event_code = p_event_code)
      and (p_hour is null or extract(hour from r.start_time)::int = p_hour)
      and (p_emp_no is null or r.emp_no_norm = p_emp_no)
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
  totals as (
    select emp_no, emp_name, sum(event_count) as total
    from base
    group by emp_no, emp_name
  )
  select jsonb_build_object(
    'total', (select count(*) from totals),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object('empNo', emp_no, 'empName', emp_name, 'total', total) order by total desc)
      from (select * from totals order by total desc limit 5000) t
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;

revoke all on function public.dds_driver_alert_totals_all from public;
grant execute on function public.dds_driver_alert_totals_all to authenticated;
