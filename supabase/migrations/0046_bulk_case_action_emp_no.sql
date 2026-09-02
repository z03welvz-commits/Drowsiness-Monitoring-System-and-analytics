-- ============================================================================
-- DDS — 0046_bulk_case_action_emp_no
-- ----------------------------------------------------------------------------
-- Alert Logs' Emp ID column is becoming an inline, per-row editable field
-- (type an employee number, the Emp Name cell resolves it from the
-- masterlist) and the bulk-edit bar is gaining the same field so a driver
-- can be assigned across every selected row in one action — "applying an
-- action or drivers will apply and update all selected with that values".
--
-- dds_bulk_log_case_action() (0035, partial-update-safed in 0045) had no way
-- to write emp_no at all — alert_cases.emp_no (0026) existed only as a
-- system-resolved read path (coalesce(c.emp_no, e.emp_no) in
-- dds_alert_logs()), never as something this RPC could set. Adds p_emp_no
-- with the same coalesce-on-null protection 0045 gave the other mutable
-- fields, so a single-row Emp ID edit (one-element p_event_ids, everything
-- else null) can't accidentally wipe action_type/status_value/remarks, and a
-- bulk action/status edit across many rows can't accidentally wipe an
-- already-assigned emp_no.
--
-- Same accepted limitation 0045 already flagged: this coalesce-on-null
-- convention has no way to explicitly CLEAR emp_no back to "unassigned"
-- (passing null means "leave it alone", not "blank it"). Not needed by the
-- inline edit (an empty Emp ID input just never calls this RPC — see
-- index.html's commitEmpIdEdit) or the bulk bar (an empty field is simply
-- not included in what gets applied), so still not solved here.
-- ============================================================================

create or replace function public.dds_bulk_log_case_action(
  p_event_ids bigint[],
  p_action_type text,
  p_action_is_other boolean,
  p_action_date date,
  p_status_value text,
  p_remarks text default null,
  p_status_is_other boolean default null,
  p_emp_no text default null
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
  if p_event_ids is null or array_length(p_event_ids, 1) is null then
    raise exception 'NO_EVENT_IDS' using errcode = '22023';
  end if;

  insert into public.alert_cases (
    event_id, action_type, action_is_other, action_date, status_value, status_is_other, remarks, emp_no, updated_by
  )
  select ev, p_action_type, coalesce(p_action_is_other, false), p_action_date,
         p_status_value, coalesce(p_status_is_other, false), p_remarks, p_emp_no, v_uid
  from unnest(p_event_ids) as ev
  on conflict (event_id) do update set
    action_type     = coalesce(excluded.action_type, public.alert_cases.action_type),
    action_is_other = coalesce(excluded.action_is_other, public.alert_cases.action_is_other),
    action_date     = coalesce(excluded.action_date, public.alert_cases.action_date),
    status_value    = coalesce(excluded.status_value, public.alert_cases.status_value),
    status_is_other = coalesce(excluded.status_is_other, public.alert_cases.status_is_other),
    remarks         = coalesce(excluded.remarks, public.alert_cases.remarks),
    emp_no          = coalesce(excluded.emp_no, public.alert_cases.emp_no),
    updated_by      = excluded.updated_by,
    updated_at      = now();

  get diagnostics v_updated = row_count;
  return jsonb_build_object('updated', v_updated);
end;
$function$;

-- New parameter list (added p_emp_no) — the old 7-arg signature is dropped
-- so PostgREST doesn't keep serving a stale overload that can't set emp_no
-- alongside this one.
drop function if exists public.dds_bulk_log_case_action(bigint[], text, boolean, date, text, text, boolean);

revoke all on function public.dds_bulk_log_case_action(bigint[], text, boolean, date, text, text, boolean, text) from public, anon;
grant execute on function public.dds_bulk_log_case_action(bigint[], text, boolean, date, text, text, boolean, text) to authenticated;
