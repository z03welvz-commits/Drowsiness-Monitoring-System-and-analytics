-- ============================================================================
-- DDS — 0012_alert_summary_total
-- ----------------------------------------------------------------------------
-- Fixes `total` in dds_alert_summary() collapsing to 0 whenever the requested
-- page is past the end of the result set.
--
-- 0009 computed the count as `count(*) over()` INSIDE the `paged` CTE and then
-- read it back with `(select full_count from paged limit 1)`. A window function
-- is evaluated before LIMIT/OFFSET, so the value itself was right — but it can
-- only be read off a row that survived the paging. Overrun the offset, `paged`
-- comes back empty, there is no row to read it from, and the coalesce turns the
-- whole thing into 0.
--
-- The client believes that 0: the Summary page renders "of 0" and disables
-- Next while the user is sitting on an empty page with no way back into the
-- data except changing a filter. Most reachable by narrowing the status filter
-- while already several pages deep — the result set shrinks under a fixed
-- offset, which is exactly when a user is most likely to be paging.
--
-- Fix: split the status predicate out of `paged` into its own `matched` CTE, so
-- the count comes from the full filtered relation and no longer depends on any
-- row surviving LIMIT/OFFSET. `paged` keeps only ORDER BY + LIMIT/OFFSET. The
-- returned `total` is now the honest match count on every page, in range or
-- not, and an overrun page correctly reports "rows 0, total N" so the client
-- can keep Prev enabled.
--
-- Only that count changes. The grouping, the closed-vs-pending derivation, the
-- filters, the ordering and the row payload are all carried over from 0009
-- verbatim — same "verify against the live pg_get_functiondef before applying"
-- caveat the other dds_* migrations carry, in case of undocumented drift.
-- ============================================================================

create or replace function public.dds_alert_summary(
  p_from        date    default null,
  p_to          date    default null,
  p_shift       text    default null,   -- 'DAY' | 'NIGHT' | null
  p_asset_ids   text[]  default null,
  p_event_codes text[]  default null,
  p_status      text    default null,   -- 'closed' | 'pending' | null (all)
  p_limit       integer default 500,
  p_offset      integer default 0
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

  with filtered as (
    select e.*, ac.status_value
    from public.events e
    left join public.alert_cases ac on ac.event_id = e.id
    where (p_from        is null or e.shift_date >= p_from)
      and (p_to          is null or e.shift_date <= p_to)
      and (p_shift       is null or e.shift = p_shift)
      and (p_asset_ids   is null or e.asset_id   = any(p_asset_ids))
      and (p_event_codes is null or e.event_code = any(p_event_codes))
  ),

  grouped as (
    select
      shift_date, shift, asset_id, event_code,
      sum(event_count) as total,
      -- LOAD-BEARING, not defensive: a group where every alert has no case
      -- at all (status_value IS NULL on every row, e.g. never reviewed)
      -- makes `status_value = 'Completed'` NULL per row, and bool_and()
      -- over all-NULL input returns NULL — not false. Without this coalesce,
      -- `closed` would be NULL for an unreviewed group, and the p_status =
      -- 'pending' filter below (`not closed`) evaluates `not NULL` = NULL,
      -- which WHERE treats as false — silently dropping never-reviewed
      -- groups out of the Pending filter entirely. The "no case = pending"
      -- rule the summary is supposed to enforce depends on this line.
      coalesce(bool_and(status_value = 'Completed'), false) as closed
    from filtered
    group by shift_date, shift, asset_id, event_code
  ),

  -- Every group matching the status filter, UNPAGED. Split out of `paged`
  -- (where 0009 had it) purely so `total` below can be counted off the whole
  -- match set rather than off whatever survived LIMIT/OFFSET — see header.
  matched as (
    select * from grouped
    where p_status is null
       or (p_status = 'closed'  and closed)
       or (p_status = 'pending' and not closed)
  ),

  paged as (
    select * from matched
    order by shift_date desc, shift, asset_id, event_code
    limit p_limit offset p_offset
  )

  select jsonb_build_object(
    -- Counted from `matched`, not `paged`: independent of the requested
    -- window, so an out-of-range offset still reports the true total instead
    -- of 0.
    'total', (select count(*) from matched),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'shiftDate',  to_char(shift_date, 'MM/DD/YYYY'),
        'shift',      shift,
        'assetId',    asset_id,
        'eventCode',  event_code,
        'total',      total,
        'actionStatus', case when closed then 'Closed' else 'Pending' end
      ) order by shift_date desc, shift, asset_id, event_code)
      from paged
    ), '[]'::jsonb)
  )
  into result;

  return result;
end;
$$;

revoke all on function public.dds_alert_summary from public;
grant execute on function public.dds_alert_summary to authenticated;
