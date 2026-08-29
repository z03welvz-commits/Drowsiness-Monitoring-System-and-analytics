-- DDS — 0026_alert_cases_emp_no
--
-- Records, as a real tracked migration, two changes that were already
-- applied directly to the live database (project rispydfovrnvnwvfwrnw)
-- outside the normal migration flow — found 2026-08-29 while reconciling a
-- newer index.html (written against a schema that already had these) with
-- supabase/migrations/, which had neither. Both changes were live and
-- correct in substance; this migration only makes them properly tracked
-- and fixes one real gap the untracked path introduced (see part 2).
--
-- 1. alert_cases.emp_no — the resolved employee number for a reviewed
--    case, separate from driver_name (free text). Lets a reviewer's
--    explicit case-level match win over the event's own system-resolved
--    emp_no, same precedence driver_name already had over operator.
--    `add column if not exists` makes this a no-op on the live DB (the
--    column already exists there) while still being a real, from-scratch
--    migration for anyone rebuilding the project via supabase/migrations/.
--
-- 2. dds_alert_logs() gains emp_no_display (the same case-over-event
--    precedence as driver_display, applied to the ID rather than the
--    name) so the case modal and bulk-edit have something to carry
--    forward and save back as empNo, not just render. This reissues the
--    function's full body from 0016 (the version already recorded in this
--    repo) plus the emp_no join/column/precedence logic already live —
--    NOT a new change to what the function returns, only to how it's
--    tracked.
--
--    The untracked path that first shipped this live also left
--    `grant execute ... to anon` in place (visible on the live function's
--    ACL: postgres/anon/authenticated/service_role all hold EXECUTE).
--    Every other RPC in this schema is deliberately anon-revoked — 0016's
--    own `revoke all ... from public` + `grant ... to authenticated` follows
--    that pattern, and a bare `create or replace function` does not
--    automatically restore a revoke that a later, unrelated privilege
--    change altered. auth.uid() is null still rejects an anon caller at
--    runtime, so this was never a live data-access hole, but it's needless
--    attack surface (timing/error-shape probing against an unauthenticated
--    RPC) inconsistent with the rest of the schema — this migration closes
--    it by reissuing the same revoke/grant pair 0016 always intended.

alter table public.alert_cases
  add column if not exists emp_no text;

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
set search_path to 'public'
as $function$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 75), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_desc boolean := lower(coalesce(p_dir, 'desc')) <> 'asc';
  v_sort text := lower(coalesce(p_sort, 'start_time'));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with filtered as (
    select e.id, e.update_time, e.start_time, e.end_time, e.asset_id, e.event_code,
           e.event_count, e.operator, e.shift, e.shift_date, e.actionable,
           e.emp_no as event_emp_no, d.full_name as event_emp_name,
           c.id as case_id, c.driver_name, c.emp_no as case_emp_no, dc.full_name as case_emp_name,
           c.action_type, c.action_is_other,
           c.status_value, c.status_is_other, c.remarks, c.updated_at as case_updated_at,
           -- Precedence for the one display name shown in the table/search:
           -- a human-confirmed case (driver_name, then case emp_no's resolved
           -- name) outranks the system-resolved event link, which outranks
           -- the raw operator string off the DDS file. A reviewer's explicit
           -- confirmation should win over an automatic match even when both
           -- are present and agree — this mirrors the case-over-event
           -- precedence driver_display already had for driver_name/operator,
           -- now extended to include both emp_no sources at their matching
           -- rungs rather than only the two free-text ends of that ladder.
           coalesce(nullif(c.driver_name, ''), dc.full_name, d.full_name, nullif(e.operator, '')) as driver_display,
           -- Same precedence, but the ID rather than the name — what the
           -- case modal/bulk-edit actually need to carry forward and save
           -- back as empNo, not just render.
           coalesce(c.emp_no, e.emp_no) as emp_no_display
    from public.events e
    left join public.alert_cases c on c.event_id = e.id
    left join public.drivers d  on d.emp_no = e.emp_no
    left join public.drivers dc on dc.emp_no = c.emp_no
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
           coalesce(c.driver_name, '') ilike '%' || p_search || '%' or
           coalesce(dc.full_name, '') ilike '%' || p_search || '%' or
           coalesce(d.full_name, '') ilike '%' || p_search || '%' or
           coalesce(c.emp_no, '') ilike '%' || p_search || '%' or
           coalesce(e.emp_no, '') ilike '%' || p_search || '%')
  ),
  total as (select count(*) as n from filtered),
  paged as (
    select * from filtered
    order by
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
      case when v_sort = 'start_time' and not v_desc then start_time end asc nulls last,
      case when v_sort = 'start_time' and v_desc     then start_time end desc nulls last,
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
        'empNo', emp_no_display, 'driverDisplayName', driver_display,
        'actionType', action_type, 'actionIsOther', action_is_other,
        'statusValue', status_value, 'statusIsOther', status_is_other,
        'remarks', remarks, 'caseUpdatedAt', case_updated_at
      ))
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;

revoke all on function public.dds_alert_logs from public, anon;
grant execute on function public.dds_alert_logs to authenticated;
