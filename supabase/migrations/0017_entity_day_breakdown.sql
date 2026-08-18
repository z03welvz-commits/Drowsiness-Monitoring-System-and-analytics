-- ============================================================================
-- DDS — 0017_entity_day_breakdown
-- ----------------------------------------------------------------------------
-- Per-day alert totals for one driver or unit, so the Driver & Asset
-- Monitoring detail modal can SHOW the days behind the High flag instead of
-- only asserting the ratio in prose.
--
-- The flag says "33 of 37 active days were over threshold". Until now there
-- was no way to see WHICH 37 days, which of them breached, or how badly —
-- the number had to be taken on faith. This returns exactly the day buckets
-- the flag is computed from.
--
-- THRESHOLD MUST MATCH THE CLIENT. HIGH_DAY_THRESHOLD is 10 in
-- withConsistency() (index.html) and in 0006_driver_asset_consistency.sql.
-- It is repeated here as a parameter defaulting to 10 rather than hardcoded
-- a fourth time, so a caller can pass the same constant and the three
-- implementations cannot silently disagree about which days are "high".
--
-- Driver lookup mirrors the client's merge rule exactly: OPERATOR from the
-- import falls back to 'Unspecified', matching UNSPECIFIED_OPERATOR and the
-- operator_days CTE in 0011. Matching on raw operator alone would return
-- nothing for the Unspecified bucket, which is the largest group whenever a
-- file arrives without a driver column.
-- ============================================================================

create or replace function public.dds_entity_day_breakdown(
  p_entity_type text,                    -- 'driver' | 'asset'
  p_entity_id   text,
  p_threshold   integer default 10,
  p_from        date    default null,
  p_to          date    default null
)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  result jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with day_totals as (
    select e.shift_date,
           sum(e.event_count)                              as units,
           count(*)                                        as events,
           count(distinct e.event_code)                    as codes,
           min(e.shift)                                    as first_shift
    from public.events e
    where (p_from is null or e.shift_date >= p_from)
      and (p_to   is null or e.shift_date <= p_to)
      and (
        (p_entity_type = 'asset'  and e.asset_id = p_entity_id)
        or
        (p_entity_type = 'driver' and
         coalesce(nullif(e.operator, ''), 'Unspecified') = p_entity_id)
      )
    group by e.shift_date
  ),
  agg as (
    select count(*)                                        as active_days,
           count(*) filter (where units > p_threshold)     as high_days,
           coalesce(sum(units), 0)                         as total,
           coalesce(max(units), 0)                         as worst_day
    from day_totals
  )
  select jsonb_build_object(
    'entityType', p_entity_type,
    'entityId',   p_entity_id,
    'threshold',  p_threshold,
    'activeDays', a.active_days,
    'highDays',   a.high_days,
    'total',      a.total,
    'worstDay',   a.worst_day,
    -- Percentage and flag computed HERE as well as client-side so the modal
    -- can never disagree with the row that opened it.
    'highDayRatio', case when a.active_days > 0
      then round((a.high_days::numeric / a.active_days) * 100, 1) else 0 end,
    'flagged', a.active_days > 0 and a.high_days::numeric / a.active_days > 0.5,
    -- Newest first: the recent days are what a reviewer acts on. Capped at
    -- 400 so a unit active every day for a year cannot return an unbounded
    -- payload -- consistent with the row caps elsewhere in this schema.
    'days', coalesce((
      select jsonb_agg(jsonb_build_object(
        'date',   to_char(d.shift_date, 'MM/DD/YYYY'),
        'units',  d.units,
        'events', d.events,
        'codes',  d.codes,
        'shift',  d.first_shift,
        'high',   d.units > p_threshold
      ) order by d.shift_date desc)
      from (select * from day_totals order by shift_date desc limit 400) d
    ), '[]'::jsonb)
  ) into result
  from agg a;

  return result;
end;
$$;

revoke all on function public.dds_entity_day_breakdown(text, text, integer, date, date) from public;
revoke all on function public.dds_entity_day_breakdown(text, text, integer, date, date) from anon;
grant execute on function public.dds_entity_day_breakdown(text, text, integer, date, date) to authenticated;
