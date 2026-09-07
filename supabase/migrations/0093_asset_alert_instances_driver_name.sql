-- ============================================================================
-- DDS — 0093_asset_alert_instances_driver_name
-- ----------------------------------------------------------------------------
-- "Who was driving asset X on a particular day" had no direct answer in the
-- app: Flagged Assets' "See details" modal (dds_asset_alert_instances)
-- listed each alert's time/event/count but never who was behind the wheel,
-- even though that answer was already computed one join away — the
-- dds_case_records view this function already reads from carries
-- driver_display/emp_no_display (case override -> case's own resolved
-- emp_no -> the event's own resolved emp_no -> raw operator text), the same
-- resolution Alert Logs' own Emp Name column and its group-detail modal
-- already show. This just adds those two fields (plus shiftDate/shift, so
-- the client can label which day/shift each row belongs to) to the rows
-- this RPC already returns — no new join, no new table.
-- ============================================================================

create or replace function public.dds_asset_alert_instances(
  p_asset_id text, p_from date default null, p_to date default null,
  p_limit integer default 100, p_offset integer default 0
)
returns jsonb
language plpgsql
set search_path to 'public'
as $$
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
        'driverName', r.driver_display
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
$$;
