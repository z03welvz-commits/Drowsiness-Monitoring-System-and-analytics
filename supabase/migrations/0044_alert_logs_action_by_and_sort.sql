-- ============================================================================
-- DDS — 0044_alert_logs_action_by_and_sort
-- ----------------------------------------------------------------------------
-- Alert Logs is being rebuilt into a full, bulk-editable table (Date, Asset,
-- Event Code, Event Count, Start/End/Update Time, Emp ID, Emp Name, Action
-- Performed, Action By, Status, Remarks — every column sortable). Two gaps
-- in dds_alert_logs() (0016/0026) block that:
--
-- 1. No "who performed the action" field. alert_cases.updated_by is stored
--    (a uuid) but was never joined/returned — the case modal only ever
--    rendered it, never needed to say who. Joins profiles the same way
--    dds_log_driver_asset_action() (0007) already resolves a username from
--    auth.uid(), and returns it as actionBy.
--
-- 2. The sort whitelist (asset_id/event_code/shift/driver/status/action/
--    start_time) doesn't cover most of the new columns. Extends it with
--    proper per-type ORDER BY clauses — shift_date (date), end_time/
--    update_time (timestamp), event_count (integer), emp_no/action_by/
--    remarks (text) — rather than casting everything to text, which would
--    sort event_count and the timestamps lexicographically instead of by
--    value (silently wrong for any input with mixed digit counts, or across
--    a DST-ish text boundary). Existing sort keys are untouched in shape.
--
-- No table/column changes — this only reissues dds_alert_logs()'s body.
-- ============================================================================

create or replace function public.dds_alert_logs(
  p_from   date    default null,
  p_to     date    default null,
  p_shift  text    default null,
  p_status text    default null,
  p_search text    default null,
  p_limit  integer default 75,
  p_offset integer default 0,
  p_sort   text    default 'start_time',
  p_dir    text    default 'desc'
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
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
    select e.id, e.update_time, e.start_time, e.end_time, e.asset_id, e.event_code,
           e.event_count, e.operator, e.shift, e.shift_date, e.actionable,
           e.emp_no as event_emp_no, d.full_name as event_emp_name,
           c.id as case_id, c.driver_name, c.emp_no as case_emp_no, dc.full_name as case_emp_name,
           c.action_type, c.action_is_other,
           c.status_value, c.status_is_other, c.remarks, c.updated_at as case_updated_at,
           pu.username as action_by,
           coalesce(nullif(c.driver_name, ''), dc.full_name, d.full_name, nullif(e.operator, '')) as driver_display,
           coalesce(c.emp_no, e.emp_no) as emp_no_display
    from public.events e
    left join public.alert_cases c on c.event_id = e.id
    left join public.drivers d   on d.emp_no = e.emp_no
    left join public.drivers dc  on dc.emp_no = c.emp_no
    left join public.profiles pu on pu.user_id = c.updated_by
    where (p_from   is null or e.shift_date >= p_from)
      and (p_to     is null or e.shift_date <= p_to)
      and (p_shift  is null or e.shift = p_shift)
      and (p_status is null or p_status = 'all'
           or (p_status = 'unset' and c.status_value is null)
           or c.status_value = p_status)
      and (p_search is null or p_search = '' or
           e.asset_id ilike '%' || p_search || '%' or
           coalesce(e.operator, '') ilike '%' || p_search || '%' or
           e.event_code ilike '%' || p_search || '%' or
           coalesce(c.driver_name, '') ilike '%' || p_search || '%' or
           coalesce(dc.full_name, '') ilike '%' || p_search || '%' or
           coalesce(d.full_name, '') ilike '%' || p_search || '%' or
           coalesce(c.emp_no, '') ilike '%' || p_search || '%' or
           coalesce(e.emp_no, '') ilike '%' || p_search || '%')
  ),
  total as (select count(*) as n from filtered),
  paged as (
    select * from filtered
    order by
      -- text-typed sort keys
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
      -- date-typed sort key
      case when v_sort = 'shift_date' and not v_desc then shift_date end asc nulls last,
      case when v_sort = 'shift_date' and v_desc     then shift_date end desc nulls last,
      -- timestamp-typed sort keys
      case when v_sort = 'start_time'  and not v_desc then start_time  end asc nulls last,
      case when v_sort = 'start_time'  and v_desc     then start_time  end desc nulls last,
      case when v_sort = 'end_time'    and not v_desc then end_time    end asc nulls last,
      case when v_sort = 'end_time'    and v_desc     then end_time    end desc nulls last,
      case when v_sort = 'update_time' and not v_desc then update_time end asc nulls last,
      case when v_sort = 'update_time' and v_desc     then update_time end desc nulls last,
      -- integer-typed sort key
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

revoke all on function public.dds_alert_logs from public, anon;
grant execute on function public.dds_alert_logs to authenticated;
