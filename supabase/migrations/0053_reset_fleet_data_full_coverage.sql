-- ============================================================================
-- DDS — 0053_reset_fleet_data_full_coverage
-- ----------------------------------------------------------------------------
-- dds_reset_fleet_data() (0022) predates entity_status, entity_action_log,
-- minestat_shifts, and emp_no_attribution_conflicts — running the original
-- version today would leave all four populated with orphaned data (rows
-- pointing at driver/event records that no longer exist) after a "reset".
-- Confirmed by tracing every table's FK relationships:
--   - emp_no_attribution_conflicts.event_id -> events(id) ON DELETE CASCADE,
--     so it WAS already covered transitively via `truncate imports cascade`
--     (imports -> events cascade, events has no direct child here, but this
--     table's FK is to events directly) — included explicitly below anyway,
--     for the same "easier to reason about than relying on multi-hop
--     cascade" principle 0022's own comment used for driver_aliases.
--   - minestat_shifts.import_id -> imports(id) ON DELETE SET NULL, not
--     CASCADE — rows SURVIVE an imports truncate with import_id nulled out.
--     This table was never wiped by the original function. Must be
--     truncated explicitly.
--   - entity_status / entity_action_log have no FK to imports/drivers/events
--     at all (entity_type/entity_id are free-form text, not real foreign
--     keys) — cannot be caught by any CASCADE. Must be truncated explicitly.
--   - minestat_name_review.import_id -> imports(id) ON DELETE CASCADE — was
--     already correctly covered by the original function's `truncate
--     imports ... cascade`, no change needed for this one.
--
-- Same two-statement split as 0022 (driver_aliases/driver_alias_log must be
-- TRUNCATEd, not swept into a CASCADE from a table that doesn't reference
-- them, so the AFTER DELETE audit trigger on driver_aliases doesn't fire and
-- immediately repopulate driver_alias_log with the reset itself).
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
    'driverAssetSeverity',       (select count(*) from public.driver_asset_severity),
    'driverMaster',              (select count(*) from public.driver_master),
    'drivers',                   (select count(*) from public.drivers),
    'driverAliases',             (select count(*) from public.driver_aliases),
    'minestatShifts',            (select count(*) from public.minestat_shifts),
    'entityStatus',              (select count(*) from public.entity_status),
    'entityActionLog',           (select count(*) from public.entity_action_log)
  ) into v_counts;

  -- imports cascades into: events -> alert_cases, events -> emp_no_
  -- attribution_conflicts, import_name_review, minestat_name_review.
  -- driver_master/contributing_factors/driver_asset_actions/driver_asset_
  -- severity have no inbound FKs from anything in this list; CASCADE is a
  -- no-op safety net for them, matching 0022's original reasoning.
  truncate table
    public.imports,
    public.driver_master,
    public.contributing_factors,
    public.driver_asset_actions,
    public.driver_asset_severity
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

  -- Split out per 0022's original reasoning: TRUNCATE (not DELETE, and not
  -- swept into the imports/drivers CASCADE) so trg_driver_alias_audit
  -- (AFTER DELETE on driver_aliases) never fires and repopulates
  -- driver_alias_log with rows describing the reset itself.
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
