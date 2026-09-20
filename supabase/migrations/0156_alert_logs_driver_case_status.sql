-- ============================================================================
-- DDS — 0156_alert_logs_driver_case_status
-- ----------------------------------------------------------------------------
-- Part 4 of the action-logging/status redesign. Parts 2+3 stopped mirroring
-- driver/asset case actions into alert_cases — event-level review and
-- driver-level case management are now two separate, honestly-scoped
-- records. This migration is the other half of that decision: instead of a
-- copy, Alert Logs gets a read-only, LIVE view into the driver's current
-- case status — a `driverCaseStatus` field, left-joined against
-- entity_status/entity_action_log by the same emp_no_display key
-- dds_case_records already resolves (case's own emp_no, falling back to the
-- event's). No write path here — this is purely "is there already an open
-- case for this driver, and what was the most recent action," visible
-- without leaving the page, answering the same question a mirror used to
-- answer unreliably.
--
-- driverCaseStatus is null when the driver has no entity_status row and no
-- entity_action_log history at all (never monitored/actioned). Otherwise:
-- 'monitoring' (active, monitor_until in the future), 'resolved' (a past
-- monitor window that expired), or 'actioned' — same three-way label used
-- by dds_driver_streaks()/dds_driver_asset_weekly() for this same table, so
-- it reads consistently wherever it's shown.
-- ============================================================================

create or replace function public.dds_alert_logs(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_shift text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 75, p_offset integer DEFAULT 0, p_sort text DEFAULT 'start_time'::text, p_dir text DEFAULT 'desc'::text, p_severity text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
 SET work_mem TO '48MB'
AS $function$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 75), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_desc boolean := lower(coalesce(p_dir, 'desc')) <> 'asc';
  v_sort text := lower(coalesce(p_sort, 'start_time'));
  v_severity text := nullif(lower(coalesce(p_severity, '')), '');
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with driver_last_actions as (
    select distinct on (entity_id)
      entity_id, action_type, action_other_text, logged_by, created_at
    from public.entity_action_log
    where entity_type = 'driver'
    order by entity_id, created_at desc
  ),
  filtered as (
    select r.event_id as id, r.update_time, r.start_time, r.end_time, r.asset_id, r.event_code,
           r.event_count, r.operator, r.shift, r.shift_date, r.actionable,
           r.emp_no as event_emp_no, r.emp_name as event_emp_name,
           r.case_id, r.case_driver_name as driver_name, r.case_emp_no, r.case_emp_name,
           r.action_performed as action_type, r.action_is_other,
           r.status as status_value, r.status_is_other, r.remarks, r.case_updated_at,
           r.action_by,
           r.driver_display,
           r.emp_no_display,
           r.driver_needs_review,
           es.status as driver_case_status,
           es.monitor_until as driver_case_monitor_until,
           dla.action_type as driver_case_last_action_type,
           dla.action_other_text as driver_case_last_action_other_text,
           dla.logged_by as driver_case_last_action_by,
           dla.created_at as driver_case_last_action_at
    from public.dds_case_records r
    left join public.entity_status es on es.entity_type = 'driver' and es.entity_id = r.emp_no_display
    left join driver_last_actions dla on dla.entity_id = r.emp_no_display
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
      and (v_severity is null or v_severity = 'all' or
           (v_severity = 'critical' and r.event_code ilike '%sleep%') or
           (v_severity = 'high' and r.event_code ilike '%drowsi%' and r.event_code not ilike '%sleep%') or
           (v_severity = 'moderate' and r.event_code not ilike '%sleep%' and r.event_code not ilike '%drowsi%'))
  ),
  total as (select count(*) as n from filtered),
  agg as (
    select
      count(*) filter (where event_code ilike '%sleep%') as critical_total,
      count(*) filter (where case_id is not null)         as cased_total,
      count(*) filter (where actionable)                  as actionable_total
    from filtered
  ),
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
    'criticalTotal', (select critical_total from agg),
    'casedTotal', (select cased_total from agg),
    'actionableTotal', (select actionable_total from agg),
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
        'remarks', remarks, 'caseUpdatedAt', case_updated_at, 'actionBy', action_by,
        'driverCaseStatus', case when driver_case_status is null and driver_case_last_action_type is null then null
          else jsonb_build_object(
            'status', case
              when driver_case_status = 'monitoring' then
                case when driver_case_monitor_until is not null and driver_case_monitor_until >= current_date
                     then 'monitoring' else 'resolved' end
              when driver_case_status = 'actioned' then 'actioned'
              else null
            end,
            'monitorUntil', to_char(driver_case_monitor_until, 'YYYY-MM-DD'),
            'lastAction', case when driver_case_last_action_type is null then null else jsonb_build_object(
              'type', driver_case_last_action_type, 'otherText', driver_case_last_action_other_text,
              'by', driver_case_last_action_by,
              'at', to_char(driver_case_last_action_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z')
            ) end
          )
        end
      ))
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$
