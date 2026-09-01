-- Driver & Asset Monitoring: bulk-edit from the main Flagged Drivers table
-- (as opposed to the existing per-driver drawer bulk-edit, which stays
-- unchanged) needs to write action/status across every selected driver's
-- events in one shot. The client-side approach shipped first — fetch each
-- selected driver's event ids via dds_driver_alert_instances (one RPC call
-- per driver, run in parallel), then pass the merged id array into the
-- existing dds_bulk_log_case_action(bigint[], ...) — failed live with 100
-- drivers selected (one of them "Unspecified", 235k+ events on its own):
-- 100 concurrent per-driver fetches, each capped at 500 rows (nowhere near
-- enough for the high-volume rows), feeding a bigint[] payload of unknown
-- but potentially huge size into one INSERT ... ON CONFLICT, which hit
-- Postgres's statement timeout.
--
-- Fix: do the selection AND the write in one set-based SQL statement,
-- driven by driver criteria (emp_no list + date/shift filters) instead of
-- a client-supplied id array. idx_events_emp_no_date (emp_no, shift_date)
-- covers exactly this filter shape, so the whole thing is one indexed
-- insert-select regardless of how many drivers or events are involved —
-- no per-driver round trips, no unbounded per-driver row cap, no giant
-- array serialized over the wire.
--
-- 'UNSPECIFIED' is the client's placeholder for "emp_no is null" (see
-- dds_driver_event_summary, 0037) — not a real emp_no value that could
-- ever match a row via `= any(...)`, so it's special-cased below via
-- p_include_unspecified rather than passed through as a literal.
create or replace function public.dds_bulk_log_case_action_by_driver(
  p_emp_nos text[],
  p_include_unspecified boolean,
  p_from date,
  p_to date,
  p_shift text,
  p_action_type text,
  p_action_is_other boolean,
  p_action_date date,
  p_status_value text,
  p_remarks text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_updated int;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  if (p_emp_nos is null or array_length(p_emp_nos, 1) is null) and not coalesce(p_include_unspecified, false) then
    raise exception 'NO_DRIVERS' using errcode = '22023';
  end if;

  with target_events as (
    select e.id
    from public.events e
    where (
        (p_emp_nos is not null and e.emp_no = any(p_emp_nos))
        or (coalesce(p_include_unspecified, false) and e.emp_no is null)
      )
      and (p_from is null or e.shift_date >= p_from)
      and (p_to   is null or e.shift_date <= p_to)
      and (p_shift is null or p_shift = '' or e.shift = p_shift)
  )
  insert into public.alert_cases (event_id, action_type, action_is_other, action_date, status_value, remarks, updated_by)
  select te.id, p_action_type, coalesce(p_action_is_other, false), p_action_date, p_status_value, p_remarks, v_uid
  from target_events te
  on conflict (event_id) do update set
    action_type = excluded.action_type,
    action_is_other = excluded.action_is_other,
    action_date = excluded.action_date,
    status_value = excluded.status_value,
    remarks = coalesce(excluded.remarks, public.alert_cases.remarks),
    updated_by = excluded.updated_by,
    updated_at = now();

  get diagnostics v_updated = row_count;
  return jsonb_build_object('updated', v_updated);
end;
$function$;

grant execute on function public.dds_bulk_log_case_action_by_driver(text[], boolean, date, date, text, text, boolean, date, text, text) to authenticated;
