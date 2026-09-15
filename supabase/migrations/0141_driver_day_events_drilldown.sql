-- ============================================================================
-- DDS — 0141_driver_day_events_drilldown
-- ----------------------------------------------------------------------------
-- Driver Streaks' "See details" modal shows a day-by-day summary (one row
-- per emp_no/shift_date/shift/asset_id, per 0129), but a user's most common
-- follow-up question is "what time did the alert happen, and how many
-- events per alert" — answerable only from the raw events, not the summary.
--
-- Scoped to the SAME grouping key the summary row already used
-- (emp_no, shift_date, shift, asset_id) rather than just the date, so the
-- individual events returned here always sum to exactly that row's own
-- numEvents/rowTotal — the same data-integrity principle the detail modal
-- itself was just fixed to follow (0140-era fix): a drill-down must foot to
-- the row it drills from, never a wider or narrower slice of it.
-- ============================================================================
create or replace function public.dds_driver_day_events(
  p_emp_no     text,
  p_shift_date date,
  p_shift      text,
  p_asset_id   text,
  p_limit      integer default 200,
  p_offset     integer default 0
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  result   jsonb;
  v_limit  integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'total', (
      select count(*) from public.events
      where emp_no = p_emp_no and shift_date = p_shift_date
        and shift = p_shift and asset_id = p_asset_id
    ),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'startTime',  to_char(e.start_time, 'YYYY-MM-DD"T"HH24:MI:SS'),
        'endTime',    case when e.end_time is null then null
                           else to_char(e.end_time, 'YYYY-MM-DD"T"HH24:MI:SS') end,
        'assetId',    e.asset_id,
        'eventCode',  e.event_code,
        'eventCount', e.event_count
      ) order by e.start_time asc)
      from (
        select * from public.events
        where emp_no = p_emp_no and shift_date = p_shift_date
          and shift = p_shift and asset_id = p_asset_id
        order by start_time asc
        limit v_limit offset v_offset
      ) e
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;
