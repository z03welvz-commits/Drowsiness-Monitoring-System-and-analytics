-- ============================================================================
-- DDS — 0097_driver_daily_summary
-- ----------------------------------------------------------------------------
-- Driver Streaks' "See details" modal listed every individual alert event
-- (up to 500, one row each) for a driver's complete history. Per direct
-- instruction, replace that with a per-day summary — and it fixes a real
-- source of confusion along the way: dds_driver_streaks()'s qualifying-day
-- rule is `sum(event_count) per day >= 20` (0088), not "any single alert
-- >= 20". A flat event list makes that invisible — scanning individual rows
-- each showing a small count (1, 2, 5...) makes a qualifying day look like
-- it shouldn't have qualified, when the day's TOTAL across all of them
-- clears 20 easily. Confirmed live before this change: emp_no 9639446's
-- flagged streak (01/19-01/23/2026) has zero individual events >= 20 on any
-- of those days (max single event is 13), but each day's sum is 51, 37, 38,
-- 90, 37 — correctly over the threshold. Not a bug; a per-day summary
-- makes the real rule visible instead of requiring the reader to mentally
-- sum a dozen scattered rows.
--
-- New RPC aggregates in SQL (group by shift_date) rather than the client
-- summing whatever page of dds_driver_alert_instances happened to be
-- fetched — that RPC caps at 500 rows, which would under-count a heavily-
-- alerted driver's older days; aggregating server-side stays correct
-- regardless of how much history exists.
-- ============================================================================

create or replace function public.dds_driver_daily_summary(
  p_emp_no text, p_from date default null, p_to date default null,
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
    'empNo', p_emp_no,
    'totalDays', coalesce((
      select count(distinct shift_date) from public.events
      where emp_no = p_emp_no
        and (p_from is null or shift_date >= p_from)
        and (p_to   is null or shift_date <= p_to)
    ), 0),
    'grandTotal', coalesce((
      select sum(event_count) from public.events
      where emp_no = p_emp_no
        and (p_from is null or shift_date >= p_from)
        and (p_to   is null or shift_date <= p_to)
    ), 0),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'shiftDate',  to_char(d.shift_date, 'MM/DD/YYYY'),
        'shifts',     d.shifts,
        'numEvents',  d.num_events,
        'dayTotal',   d.day_total,
        'qualifies',  d.day_total >= 20
      ) order by d.shift_date desc)
      from (
        select shift_date, sum(event_count) as day_total, count(*) as num_events,
               array_agg(distinct shift order by shift) as shifts
        from public.events
        where emp_no = p_emp_no
          and (p_from is null or shift_date >= p_from)
          and (p_to   is null or shift_date <= p_to)
        group by shift_date
        order by shift_date desc
        limit v_limit offset v_offset
      ) d
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

revoke all on function public.dds_driver_daily_summary(text, date, date, integer, integer) from public, anon;
grant execute on function public.dds_driver_daily_summary(text, date, date, integer, integer) to authenticated;
