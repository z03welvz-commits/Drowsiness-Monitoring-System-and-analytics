-- ============================================================================
-- DDS — 0069_reset_fleet_data_drop_missing_severity_table
-- ----------------------------------------------------------------------------
-- Live-database testing found dds_reset_fleet_data() (0053) fails with
-- "relation public.driver_asset_severity does not exist" the moment it's
-- actually invoked. Confirmed directly against the live project: no table
-- by that name exists in public (list_tables / pg_tables), despite 0053's
-- header comment describing it as one of the tables added by an earlier
-- migration. Root cause is a broader repo/live drift discovered the same
-- day — several migration files in this repo (0052, 0053 included) were
-- never actually applied to the live database at all; dds_reset_fleet_data
-- itself didn't exist live until this drift was found and 0053 was applied
-- directly. driver_asset_severity appears to be a table that existed only
-- in an earlier draft of the schema and was dropped or never created on
-- the live side, while the reset function's source kept referencing it.
--
-- Fix: drop driver_asset_severity from both the pre-delete count snapshot
-- and the truncate list. Every other table this function references was
-- individually re-verified against live pg_tables (see MIGRATION_STATUS.md
-- if present, or re-run the same check: a table named here that isn't in
-- `select tablename from pg_tables where schemaname='public'` is a bug).
-- No other table is affected — driver_asset_severity had no inbound FKs
-- from anything else in this schema (per 0053's own trace), so dropping it
-- from the list doesn't change delete order or cascade behavior for
-- anything that remains.
-- ============================================================================

create or replace function public.dds_reset_fleet_data()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_counts jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'imports',                  (select count(*) from public.imports),
    'events',                   (select count(*) from public.events),
    'alertCases',                (select count(*) from public.alert_cases),
    'importNameReview',          (select count(*) from public.import_name_review),
    'minestatNameReview',        (select count(*) from public.minestat_name_review),
    'empNoAttributionConflicts', (select count(*) from public.emp_no_attribution_conflicts),
    'contributingFactors',       (select count(*) from public.contributing_factors),
    'driverAssetActions',        (select count(*) from public.driver_asset_actions),
    'driverMaster',              (select count(*) from public.driver_master),
    'drivers',                   (select count(*) from public.drivers),
    'driverAliases',             (select count(*) from public.driver_aliases),
    'minestatShifts',            (select count(*) from public.minestat_shifts),
    'entityStatus',              (select count(*) from public.entity_status),
    'entityActionLog',           (select count(*) from public.entity_action_log)
  ) into v_counts;

  -- imports cascades into: events -> alert_cases, events -> emp_no_
  -- attribution_conflicts, import_name_review, minestat_name_review.
  truncate table
    public.imports,
    public.driver_master,
    public.contributing_factors,
    public.driver_asset_actions
    cascade;

  -- minestat_shifts is NOT reachable via the imports cascade above (its FK
  -- is ON DELETE SET NULL, not CASCADE) — must be listed here explicitly.
  truncate table public.minestat_shifts cascade;

  -- Neither has any FK to anything else in this schema (entity_type/
  -- entity_id are free-form text) — nothing else can cascade into them.
  truncate table
    public.entity_status,
    public.entity_action_log
    cascade;

  -- Split out so TRUNCATE (not DELETE, and not swept into the imports/
  -- drivers CASCADE) means trg_driver_alias_audit (AFTER DELETE on
  -- driver_aliases) never fires and repopulates driver_alias_log with rows
  -- describing the reset itself.
  truncate table
    public.drivers,
    public.driver_aliases,
    public.driver_alias_log
    cascade;

  return v_counts;
end;
$$;

revoke all on function public.dds_reset_fleet_data() from public, anon;
grant execute on function public.dds_reset_fleet_data() to authenticated;
