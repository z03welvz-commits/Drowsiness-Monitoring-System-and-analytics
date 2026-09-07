-- ============================================================================
-- DDS — driver_daily_summary
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- Inferred intent: new RPC dds_driver_daily_summary(emp_no, from, to, limit,
-- offset) — a per-driver day-by-day breakdown (shifts worked, event count,
-- day total, and whether the day qualifies against the >= 20 streak
-- threshold) plus totalDays/grandTotal summary figures. Likely backs a
-- drill-down/detail view for a single driver on the Driver Streaks or Driver
-- & Asset Monitoring page, complementing dds_driver_alert_instances (which
-- lists individual alert events) with a daily-aggregate view.
-- ============================================================================

create or replace function public.dds_driver_daily_summary(
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
$function$;
