-- ============================================================================
-- DDS — 0168_reset_fleet_data_require_admin
-- ----------------------------------------------------------------------------
-- SECURITY FIX. dds_reset_fleet_data() — the RPC behind Settings' "Delete
-- All Data" button, which truncates imports/driver_master/contributing_
-- factors/minestat_shifts/entity_status/entity_action_log/drivers/
-- driver_aliases/driver_alias_log — had NO admin check server-side. Its
-- only gates were `auth.uid() is not null` and dds_require_edit_lock(),
-- which is a collaboration mechanism (acquirable by any signed-in user,
-- deliberately not authorization-gated per its own design — see 0149's
-- comments), not an authorization check. Confirmed live via
-- pg_get_functiondef(): the button's visibility (accessState.isAdmin) was
-- the ONLY thing standing between any authenticated session — including a
-- non-admin, or even a still-pending, not-yet-approved invited user who
-- already has a live Supabase session before an admin ever approves them —
-- and an irreversible full-fleet data wipe via a direct
-- supabase.rpc('dds_reset_fleet_data') call, no UI involved.
--
-- Fix: add the exact same server-side admin re-check every other
-- admin-gated write RPC in this app already uses (dds_edit_lock_override(),
-- profiles_update_admin, alert_recipients_admin_all — verified live via
-- pg_get_functiondef()/pg_policies) — role='admin' AND status='approved' on
-- the caller's own profiles row. No signature change. Body otherwise
-- unchanged from the current live definition (confirmed via
-- pg_get_functiondef() immediately before writing this migration).
-- ============================================================================

create or replace function public.dds_reset_fleet_data()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_counts jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.user_id = auth.uid() and p.role = 'admin' and p.status = 'approved'
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  perform public.dds_require_edit_lock();

  select jsonb_build_object(
    'imports',                  (select count(*) from public.imports),
    'events',                   (select count(*) from public.events),
    'alertCases',                (select count(*) from public.alert_cases),
    'importNameReview',          (select count(*) from public.import_name_review),
    'minestatNameReview',        (select count(*) from public.minestat_name_review),
    'empNoAttributionConflicts', (select count(*) from public.emp_no_attribution_conflicts),
    'contributingFactors',       (select count(*) from public.contributing_factors),
    'driverMaster',              (select count(*) from public.driver_master),
    'drivers',                   (select count(*) from public.drivers),
    'driverAliases',             (select count(*) from public.driver_aliases),
    'minestatShifts',            (select count(*) from public.minestat_shifts),
    'entityStatus',              (select count(*) from public.entity_status),
    'entityActionLog',           (select count(*) from public.entity_action_log)
  ) into v_counts;

  truncate table
    public.imports,
    public.driver_master,
    public.contributing_factors
    cascade;

  truncate table public.minestat_shifts cascade;

  truncate table
    public.entity_status,
    public.entity_action_log
    cascade;

  truncate table
    public.drivers,
    public.driver_aliases,
    public.driver_alias_log
    cascade;

  return v_counts;
end;
$function$;
