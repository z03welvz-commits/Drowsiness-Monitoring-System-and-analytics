-- ============================================================================
-- DDS — 0155_retire_driver_asset_actions
-- ----------------------------------------------------------------------------
-- Part 3 of the action-logging/status redesign (Part 2, shipped in the same
-- deployment, stopped the client from calling dds_log_driver_asset_action()
-- — Alert Logs' bulk-edit bar was its only remaining caller).
--
-- driver_asset_actions was a 2023-era feature (0007) superseded by
-- entity_status/entity_action_log (0033) — confirmed live it has had zero
-- read call sites anywhere in the app; dds_entity_actions()/
-- dds_latest_entity_actions(), its own read RPCs, no longer exist in this
-- database at all (already dropped some time before this migration).
-- Confirmed live the table itself is EMPTY (0 rows) — the "reflect to all"
-- mirror Part 2 removed was in practice never producing surviving history
-- to preserve, so there is no data migration step here, only the drop.
--
-- dds_reset_fleet_data() (0053) is updated to stop counting/truncating a
-- table that no longer exists.
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

drop function if exists public.dds_log_driver_asset_action(text, text, text, boolean, text, text);

drop table if exists public.driver_asset_actions cascade;
