-- ============================================================================
-- DDS — 0045_bulk_case_action_partial_update
-- ----------------------------------------------------------------------------
-- dds_bulk_log_case_action() (0035) already protects `remarks` from being
-- wiped when a caller passes null for it (`coalesce(excluded.remarks,
-- public.alert_cases.remarks)`), but action_type/action_is_other/
-- action_date/status_value are all overwritten unconditionally on conflict
-- — passing null for any of them (e.g. "I'm only setting Status, leave
-- Action Performed alone") silently erases the existing value instead of
-- leaving it untouched. This was a latent bug in the already-shipped bulk
-- bar (a status-only edit already wipes action_type today) and would make
-- a per-row single-field inline edit actively dangerous to build on top of.
--
-- Applies the same coalesce-on-null protection remarks already had to the
-- other three mutable fields, and adds a p_status_is_other parameter that
-- was simply never plumbed through before (status_is_other has existed on
-- alert_cases since 0005 but nothing ever wrote it via this RPC).
--
-- A caller that means to actually CLEAR a field (not just leave it alone)
-- has no way to express that anymore with this coalesce-null convention —
-- not needed by any current caller (bulk bar / inline edit), so not solved
-- here; flag it if a real "clear this field" affordance is ever needed.
-- ============================================================================

create or replace function public.dds_bulk_log_case_action(
  p_event_ids bigint[],
  p_action_type text,
  p_action_is_other boolean,
  p_action_date date,
  p_status_value text,
  p_remarks text default null,
  p_status_is_other boolean default null
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
    event_id, action_type, action_is_other, action_date, status_value, status_is_other, remarks, updated_by
  )
  select ev, p_action_type, coalesce(p_action_is_other, false), p_action_date,
         p_status_value, coalesce(p_status_is_other, false), p_remarks, v_uid
  from unnest(p_event_ids) as ev
  on conflict (event_id) do update set
    action_type     = coalesce(excluded.action_type, public.alert_cases.action_type),
    action_is_other = coalesce(excluded.action_is_other, public.alert_cases.action_is_other),
    action_date     = coalesce(excluded.action_date, public.alert_cases.action_date),
    status_value    = coalesce(excluded.status_value, public.alert_cases.status_value),
    status_is_other = coalesce(excluded.status_is_other, public.alert_cases.status_is_other),
    remarks         = coalesce(excluded.remarks, public.alert_cases.remarks),
    updated_by      = excluded.updated_by,
    updated_at      = now();

  get diagnostics v_updated = row_count;
  return jsonb_build_object('updated', v_updated);
end;
$function$;

-- New parameter list (added p_status_is_other) — the old 6-arg signature is
-- dropped so PostgREST doesn't keep serving a stale overload with the wipe
-- bug alongside this one.
drop function if exists public.dds_bulk_log_case_action(bigint[], text, boolean, date, text, text);

revoke all on function public.dds_bulk_log_case_action(bigint[], text, boolean, date, text, text, boolean) from public, anon;
grant execute on function public.dds_bulk_log_case_action(bigint[], text, boolean, date, text, text, boolean) to authenticated;
