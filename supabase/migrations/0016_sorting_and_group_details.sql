-- ============================================================================
-- DDS — 0016_sorting_and_group_details
-- ----------------------------------------------------------------------------
-- Two additions driven by the Alert Logs / Summary UI work:
--
--   1. dds_alert_logs() gains p_sort / p_dir. Alert Logs holds 84,401 rows,
--      so sorting MUST happen server-side: the client only ever holds one
--      75-row page, and sorting that page would reorder 75 arbitrary rows
--      while claiming to sort the whole table — worse than no sorting,
--      because it looks like it worked.
--
--   2. dds_alert_group_details() — every individual alert behind one Summary
--      row. The Summary groups by (shift_date, shift, asset_id, event_code);
--      this returns the underlying events for exactly one such group, e.g.
--      "every Sleep Alert on DT-111 during the day shift of 08/18/2026".
--
-- SORT WHITELIST, not string interpolation. p_sort is matched against a fixed
-- set of column names in a CASE expression rather than concatenated into the
-- ORDER BY. A caller-supplied string reaching ORDER BY is a SQL-injection
-- vector even inside a SECURITY INVOKER function, and PostgREST exposes these
-- parameters directly to the browser. Anything unrecognised falls back to
-- start_time, so a bad value degrades instead of erroring or injecting.
--
-- Every sort is tie-broken on id. Without it, rows sharing a sort value (all
-- the DT-714s, every row in the same second) can come back in a different
-- order on each page fetch, so paging through a sorted table would show some
-- rows twice and skip others.
--
-- DRIVER SORTS ON THE MERGED VALUE. The UI shows one Driver column —
-- coalesce(nullif(driver_name,''), operator) — because the reviewer's entry
-- wins over the imported operator (see driverOf() in index.html). Sorting on
-- driver_name alone would order by a field the user cannot see, putting rows
-- with a blank case but a real operator name in the wrong place.
-- ============================================================================

create or replace function public.dds_alert_logs(
  p_from   date    default null,
  p_to     date    default null,
  p_shift  text    default null,
  p_status text    default null,
  p_search text    default null,
  p_limit  integer default 75,
  p_offset integer default 0,
  p_sort   text    default 'start_time',
  p_dir    text    default 'desc'
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 75), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  -- Normalised once so the CASE arms below stay simple, and so a caller
  -- sending 'DESC'/'Desc' behaves the same as 'desc'.
  v_desc boolean := lower(coalesce(p_dir, 'desc')) <> 'asc';
  v_sort text := lower(coalesce(p_sort, 'start_time'));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with filtered as (
    select e.id, e.update_time, e.start_time, e.end_time, e.asset_id, e.event_code,
           e.event_count, e.operator, e.shift, e.shift_date, e.actionable,
           c.id as case_id, c.driver_name, c.action_type, c.action_is_other,
           c.status_value, c.status_is_other, c.remarks, c.updated_at as case_updated_at,
           -- The value the Driver column actually displays; see header.
           coalesce(nullif(c.driver_name, ''), nullif(e.operator, '')) as driver_display
    from public.events e
    left join public.alert_cases c on c.event_id = e.id
    where (p_from   is null or e.shift_date >= p_from)
      and (p_to     is null or e.shift_date <= p_to)
      and (p_shift  is null or e.shift = p_shift)
      and (p_status is null or p_status = 'all'
           or (p_status = 'unset' and c.status_value is null)
           or c.status_value = p_status)
      and (p_search is null or p_search = '' or
           e.asset_id ilike '%' || p_search || '%' or
           coalesce(e.operator, '') ilike '%' || p_search || '%' or
           e.event_code ilike '%' || p_search || '%' or
           coalesce(c.driver_name, '') ilike '%' || p_search || '%')
  ),
  total as (select count(*) as n from filtered),
  paged as (
    select * from filtered
    order by
      -- Two parallel CASE ladders (one asc, one desc) rather than one ladder
      -- wrapped in a direction modifier: ORDER BY cannot take a dynamic
      -- ASC/DESC without building the statement as text, which is exactly
      -- the interpolation this design avoids.
      case when v_desc then null else
        case v_sort
          when 'asset_id'   then asset_id
          when 'event_code' then event_code
          when 'shift'      then shift
          when 'driver'     then driver_display
          when 'status'     then status_value
          when 'action'     then action_type
        end
      end asc nulls last,
      case when v_desc then
        case v_sort
          when 'asset_id'   then asset_id
          when 'event_code' then event_code
          when 'shift'      then shift
          when 'driver'     then driver_display
          when 'status'     then status_value
          when 'action'     then action_type
        end
      end desc nulls last,
      -- Timestamp arms are separate because they are not text; mixing them
      -- into the ladders above would force a cast and sort lexically
      -- ("2026-08-9" after "2026-08-10").
      case when v_sort = 'start_time' and not v_desc then start_time end asc nulls last,
      case when v_sort = 'start_time' and v_desc     then start_time end desc nulls last,
      -- Deterministic tiebreak — see header on why this is load-bearing.
      id desc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'startTime', start_time, 'updateTime', update_time, 'endTime', end_time,
        'assetId', asset_id, 'eventCode', event_code, 'eventCount', event_count,
        'operator', operator, 'shift', shift, 'shiftDate', shift_date, 'actionable', actionable,
        'caseId', case_id, 'driverName', driver_name,
        'actionType', action_type, 'actionIsOther', action_is_other,
        'statusValue', status_value, 'statusIsOther', status_is_other,
        'remarks', remarks, 'caseUpdatedAt', case_updated_at
      ))
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

revoke all on function public.dds_alert_logs from public;
grant execute on function public.dds_alert_logs to authenticated;

-- ── Group drill-down ───────────────────────────────────────────────────────
-- Returns every individual alert behind one Summary row. The Summary groups
-- by (shift_date, shift, asset_id, event_code) and shows only a total, so
-- "DT-111, day shift, Sleep Alert, 25 alerts" is currently a dead end — there
-- is no way to see which 25.
--
-- Capped at 500 rows. One group is a single unit on a single shift for one
-- event code, so it is normally tens of rows; the cap exists so a pathological
-- group cannot return an unbounded payload, consistent with the row limits
-- everywhere else in this schema.

create or replace function public.dds_alert_group_details(
  p_shift_date date,
  p_shift      text,
  p_asset_id   text,
  p_event_code text
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

  select jsonb_build_object(
    'group', jsonb_build_object(
      'shiftDate', to_char(p_shift_date, 'MM/DD/YYYY'),
      'shift',     p_shift,
      'assetId',   p_asset_id,
      'eventCode', p_event_code
    ),
    'total',  (select coalesce(sum(e.event_count), 0)
               from public.events e
               where e.shift_date = p_shift_date and e.shift = p_shift
                 and e.asset_id = p_asset_id and e.event_code = p_event_code),
    'rowCount', (select count(*)
                 from public.events e
                 where e.shift_date = p_shift_date and e.shift = p_shift
                   and e.asset_id = p_asset_id and e.event_code = p_event_code),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',         e.id,
        'startTime',  to_char(e.start_time, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
        'updateTime', to_char(e.update_time, 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
        'eventCount', e.event_count,
        'actionable', e.actionable,
        -- Same merged value the Alert Logs Driver column shows.
        'driver',     coalesce(nullif(c.driver_name, ''), nullif(e.operator, '')),
        'actionType', c.action_type,
        'statusValue', c.status_value,
        'remarks',    c.remarks
      ) order by e.start_time, e.id)
      from (
        select * from public.events e2
        where e2.shift_date = p_shift_date and e2.shift = p_shift
          and e2.asset_id = p_asset_id and e2.event_code = p_event_code
        order by e2.start_time, e2.id
        limit 500
      ) e
      left join public.alert_cases c on c.event_id = e.id
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

revoke all on function public.dds_alert_group_details from public;
revoke all on function public.dds_alert_group_details from anon;
grant execute on function public.dds_alert_group_details to authenticated;
