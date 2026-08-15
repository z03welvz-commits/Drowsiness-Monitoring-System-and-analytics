-- ============================================================================
-- DDS — 0009_alert_summary
-- ----------------------------------------------------------------------------
-- New "Summary" page: one row per (shift_date, shift, asset_id, event_code),
-- with the sum of alerts (event_count) in that group and an action_status
-- derived from alert_cases — 'Closed' when EVERY alert in the group has
-- status_value = 'Completed', 'Pending' otherwise (including groups with no
-- case recorded at all, since an unreviewed alert cannot be "closed").
--
-- Server-side grouping, same reasoning as dds_metrics()/dds_alert_logs():
-- summing potentially many thousands of event rows client-side doesn't scale
-- and this table is meant to answer "what's outstanding" at a glance, not
-- ship every underlying row to the browser.
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

  paged as (
    select *, count(*) over() as full_count
    from grouped
    where p_status is null
       or (p_status = 'closed'  and closed)
       or (p_status = 'pending' and not closed)
    order by shift_date desc, shift, asset_id, event_code
    limit p_limit offset p_offset
  )

  select jsonb_build_object(
    'total', coalesce((select full_count from paged limit 1), 0),
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
