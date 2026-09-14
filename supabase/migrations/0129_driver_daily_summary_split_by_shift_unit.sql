-- ============================================================================
-- DDS — 0129_driver_daily_summary_split_by_shift_unit
-- ----------------------------------------------------------------------------
-- 0128 added a `units` array to each day row, but kept one row per calendar
-- date — so a date where the driver worked NIGHT on DT-602 then DAY on
-- DT-600 rendered as a single "Night + Day / DT-602 + DT-600" row, hiding
-- which alerts went with which shift and which unit. Per direct correction:
-- a new shift OR a new unit, even on the same date, is its own row.
--
-- Grain moves from (shift_date) to (shift_date, shift, asset_id); `shift`
-- and `unit` become plain scalars instead of arrays. `qualifies` per row is
-- true when either holds: this row itself contains a single event_count>10
-- entry, or the row's (date, shift) — summed across every unit on that
-- shift, matching 0127's own per-shift threshold, not per-asset — exceeds
-- 20. So two rows for the same shift split across two units still both
-- read "Qualifies" when their COMBINED shift total clears 20, even though
-- neither unit alone does; a >10 single alert only flags the row it
-- actually happened on.
-- ============================================================================
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
  per_row as (
    select shift_date, shift, asset_id,
      sum(event_count) as row_total,
      count(*) as num_events,
      bool_or(event_count > 10) as has_acute
    from scoped
    group by shift_date, shift, asset_id
  )
  select jsonb_build_object(
    'empNo', p_emp_no,
    'totalDays', coalesce((select count(distinct shift_date) from scoped), 0),
    'grandTotal', coalesce((select sum(event_count) from scoped), 0),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'shiftDate',  to_char(pr.shift_date, 'MM/DD/YYYY'),
        'shift',      pr.shift,
        'unit',       coalesce(pr.asset_id, '—'),
        'numEvents',  pr.num_events,
        'rowTotal',   pr.row_total,
        'qualifies',  pr.has_acute or coalesce(ps.shift_total, 0) > 20
      ) order by pr.shift_date desc, pr.shift, pr.asset_id)
      from (
        select * from per_row
        order by shift_date desc, shift, asset_id
        limit v_limit offset v_offset
      ) pr
      left join per_shift ps on ps.shift_date = pr.shift_date and ps.shift = pr.shift
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;
