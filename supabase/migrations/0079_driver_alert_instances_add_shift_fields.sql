-- ============================================================================
-- DDS — 0079_driver_alert_instances_add_shift_fields
-- ----------------------------------------------------------------------------
-- dds_driver_alert_instances() reads from dds_case_records, which already
-- carries shift_date and shift columns, but its rows payload never
-- selected them. The "Driver Streaks" page's history drill-down needs a
-- Date and Shift column, which this RPC is otherwise a perfect fit for (it
-- already returns asset_id, start/end/update time, event_code,
-- event_count, and every action-related field). Pure additive change to
-- the returned jsonb shape — every existing field/behavior is unchanged,
-- signature unchanged, so existing callers (Driver & Asset Monitoring's
-- instances popup) are unaffected.
-- ============================================================================

create or replace function public.dds_driver_alert_instances(
  p_emp_no text,
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
    'empNo', p_emp_no,
    'total', coalesce((
      select sum(r.event_count) from public.dds_case_records r
      where r.emp_no_norm = p_emp_no
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
    ), 0),
    'rowCount', coalesce((
      select count(*) from public.dds_case_records r
      where r.emp_no_norm = p_emp_no
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
    ), 0),
    'allHighSeverityActioned', not exists (
      select 1 from public.dds_case_records r
      where r.emp_no_norm = p_emp_no
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
        and r.is_unresolved_high_severity
    ),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'eventId',         r.event_id,
        'unit',            r.asset_id,
        'shiftDate',       to_char(r.shift_date, 'MM/DD/YYYY'),
        'shift',           r.shift,
        'startTime',       to_char(r.start_time, 'MM/DD/YYYY HH24:MI:SS'),
        'endTime',         to_char(r.end_time, 'MM/DD/YYYY HH24:MI:SS'),
        'updateTime',      to_char(r.update_time, 'MM/DD/YYYY HH24:MI:SS'),
        'eventCode',       r.event_code,
        'eventCount',      r.event_count,
        'severityTier',    case
                              when r.event_code ilike '%sleep%' then 'critical'
                              when r.event_code ilike '%drowsi%' then 'high'
                              else 'moderate'
                            end,
        'actionType',      r.action_performed,
        'actionOtherText', r.action_is_other,
        'actionDate',      to_char(r.action_date, 'MM/DD/YYYY'),
        'statusValue',     r.status,
        'remarks',         r.remarks,
        'actionBy',        r.action_by
      ) order by r.start_time desc, r.event_id desc)
      from (
        select * from public.dds_case_records r2
        where r2.emp_no_norm = p_emp_no
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
