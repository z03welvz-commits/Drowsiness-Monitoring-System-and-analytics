-- ============================================================================
-- DDS — 0128_driver_daily_summary_unit_and_filters
-- ----------------------------------------------------------------------------
-- Per direct instruction: Driver Streaks' "See details" modal (0097) should
-- (1) show which unit/asset the driver actually used, and (2) only show data
-- consistent with whatever filters are active on the Driver Streaks page
-- itself, rather than always pulling the driver's complete history. This
-- deliberately reverses part of 0097's own "full record, not scoped to the
-- filtered window" decision — the filter bar (0120) didn't exist yet when
-- that call was made, so there was no page-level scope to inherit.
--
-- Adds p_asset_id (the page's Unit filter, `ds-asset`) alongside the
-- existing p_from/p_to (the page's date-range filter) — index.html now
-- passes all three from `state` instead of null,null. p_search/p_status/
-- p_min_streak stay page-level row-selection filters with no meaning once a
-- specific driver's row is already open, so they don't carry over.
--
-- Also adds a `units` array per day (which asset(s) the driver logged
-- events against that day — usually one, occasionally more if they swapped
-- equipment mid-shift) so "what unit did the driver use" is answerable at
-- the day level, not just the row's own single primary-asset summary.
--
-- `qualifies` is corrected to match 0127's Driver Streaks definition (a
-- single event_count>10 row, or one shift's own sum >20) instead of the
-- stale pooled day_total>=20 test — otherwise this modal's "Qualifies" tag
-- would silently disagree with the very status badge that sent the reader
-- here.
-- ============================================================================
drop function if exists public.dds_driver_daily_summary(text, date, date, integer, integer);

create or replace function public.dds_driver_daily_summary(
  p_emp_no   text,
  p_from     date default null,
  p_to       date default null,
  p_asset_id text default null,
  p_limit    integer default 100,
  p_offset   integer default 0
)
returns jsonb
language plpgsql
set search_path to 'public'
as $$
declare
  result  jsonb;
  v_limit integer := least(coalesce(p_limit, 100), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with scoped as (
    select *
    from public.events
    where emp_no = p_emp_no
      and (p_from is null or shift_date >= p_from)
      and (p_to   is null or shift_date <= p_to)
      and (p_asset_id is null or asset_id = p_asset_id)
  ),
  per_shift as (
    select shift_date, shift, sum(event_count) as shift_total
    from scoped
    group by shift_date, shift
  ),
  day_shift_over20 as (
    select shift_date, bool_or(shift_total > 20) as any_shift_over20
    from per_shift
    group by shift_date
  ),
  per_day as (
    select shift_date,
      sum(event_count) as day_total,
      count(*) as num_events,
      array_agg(distinct shift order by shift) as shifts,
      array_agg(distinct asset_id order by asset_id) filter (where asset_id is not null) as units,
      bool_or(event_count > 10) as has_acute
    from scoped
    group by shift_date
  )
  select jsonb_build_object(
    'empNo', p_emp_no,
    'totalDays', (select count(*) from per_day),
    'grandTotal', coalesce((select sum(day_total) from per_day), 0),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'shiftDate',  to_char(pd.shift_date, 'MM/DD/YYYY'),
        'shifts',     pd.shifts,
        'units',      coalesce(pd.units, '{}'::text[]),
        'numEvents',  pd.num_events,
        'dayTotal',   pd.day_total,
        'qualifies',  pd.has_acute or coalesce(dso.any_shift_over20, false)
      ) order by pd.shift_date desc)
      from (select * from per_day order by shift_date desc limit v_limit offset v_offset) pd
      left join day_shift_over20 dso on dso.shift_date = pd.shift_date
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

revoke all on function public.dds_driver_daily_summary(text, date, date, text, integer, integer) from public, anon;
grant execute on function public.dds_driver_daily_summary(text, date, date, text, integer, integer) to authenticated;
