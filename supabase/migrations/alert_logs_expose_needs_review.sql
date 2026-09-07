-- ============================================================================
-- DDS — alert_logs_expose_needs_review
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- Inferred intent: dds_alert_logs()'s rows payload previously didn't select
-- dds_case_records.driver_needs_review. The live definition selects it as
-- r.driver_needs_review in the CTE and exposes it as 'needsReview' in each
-- row's jsonb output, so the Alert Logs table can flag/filter rows whose
-- driver name still needs manual review (i.e. resolved only via the
-- raw-operator/MineStat-raw-name fallback added in
-- case_records_minestat_raw_name_fallback, not a confirmed driver match).
-- ============================================================================

create or replace function public.dds_alert_logs(
  p_from date default null,
  p_to date default null,
  p_shift text default null,
  p_status text default null,
  p_search text default null,
  p_limit integer default 75,
  p_offset integer default 0,
  p_sort text default 'start_time',
  p_dir text default 'desc'
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
set work_mem to '48MB'
as $function$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 75), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_desc boolean := lower(coalesce(p_dir, 'desc')) <> 'asc';
  v_sort text := lower(coalesce(p_sort, 'start_time'));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with filtered as (
    select r.event_id as id, r.update_time, r.start_time, r.end_time, r.asset_id, r.event_code,
           r.event_count, r.operator, r.shift, r.shift_date, r.actionable,
           r.emp_no as event_emp_no, r.emp_name as event_emp_name,
           r.case_id, r.case_driver_name as driver_name, r.case_emp_no, r.case_emp_name,
           r.action_performed as action_type, r.action_is_other,
           r.status as status_value, r.status_is_other, r.remarks, r.case_updated_at,
           r.action_by,
           r.driver_display,
           r.emp_no_display,
           r.driver_needs_review
    from public.dds_case_records r
    where (p_from   is null or r.shift_date >= p_from)
      and (p_to     is null or r.shift_date <= p_to)
      and (p_shift  is null or r.shift = p_shift)
      and (p_status is null or p_status = 'all'
           or (p_status = 'unset' and r.status is null)
           or r.status = p_status)
      and (p_search is null or p_search = '' or
           r.asset_id ilike '%' || p_search || '%' or
           coalesce(r.operator, '') ilike '%' || p_search || '%' or
           r.event_code ilike '%' || p_search || '%' or
           coalesce(r.case_driver_name, '') ilike '%' || p_search || '%' or
           coalesce(r.case_emp_name, '') ilike '%' || p_search || '%' or
           coalesce(r.emp_name, '') ilike '%' || p_search || '%' or
           coalesce(r.case_emp_no, '') ilike '%' || p_search || '%' or
           coalesce(r.emp_no, '') ilike '%' || p_search || '%')
  ),
  total as (select count(*) as n from filtered),
  paged as (
    select * from filtered
    order by
      case when v_desc then null else
        case v_sort
          when 'asset_id'   then asset_id
          when 'event_code' then event_code
          when 'shift'      then shift
          when 'driver'     then driver_display
          when 'status'     then status_value
          when 'action'     then action_type
          when 'emp_no'     then emp_no_display
          when 'action_by'  then action_by
          when 'remarks'    then remarks
        end
      end asc nulls last,
      case when v_desc then
        case v_sort
          when 'asset_id'   then asset_id
          when 'event_code' then event_code
          when 'shift'      then shift
          when 'driver'     then driver_display
          when 'status'     then status_value
          when 'action'     then action_type
          when 'emp_no'     then emp_no_display
          when 'action_by'  then action_by
          when 'remarks'    then remarks
        end
      end desc nulls last,
      case when v_sort = 'shift_date' and not v_desc then shift_date end asc nulls last,
      case when v_sort = 'shift_date' and v_desc     then shift_date end desc nulls last,
      case when v_sort = 'start_time'  and not v_desc then start_time  end asc nulls last,
      case when v_sort = 'start_time'  and v_desc     then start_time  end desc nulls last,
      case when v_sort = 'end_time'    and not v_desc then end_time    end asc nulls last,
      case when v_sort = 'end_time'    and v_desc     then end_time    end desc nulls last,
      case when v_sort = 'update_time' and not v_desc then update_time end asc nulls last,
      case when v_sort = 'update_time' and v_desc     then update_time end desc nulls last,
      case when v_sort = 'event_count' and not v_desc then event_count end asc nulls last,
      case when v_sort = 'event_count' and v_desc     then event_count end desc nulls last,
      id desc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'startTime', start_time, 'updateTime', update_time, 'endTime', end_time,
        'assetId', asset_id, 'eventCode', event_code, 'eventCount', event_count,
        'operator', operator, 'shift', shift, 'shiftDate', shift_date, 'actionable', actionable,
        'caseId', case_id, 'driverName', driver_name,
        'empNo', emp_no_display, 'driverDisplayName', driver_display,
        'needsReview', driver_needs_review,
        'actionType', action_type, 'actionIsOther', action_is_other,
        'statusValue', status_value, 'statusIsOther', status_is_other,
        'remarks', remarks, 'caseUpdatedAt', case_updated_at, 'actionBy', action_by
      ))
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;
