-- ============================================================================
-- DDS — 0022_reset_fleet_data
-- ----------------------------------------------------------------------------
-- A single "fresh start" RPC that wipes every table this app treats as FLEET
-- DATA — imported alerts, cases, contributing factors, and the driver
-- masterlist — while leaving account-level tables untouched.
--
-- WHY A SERVER-SIDE RESET IS NEEDED
--   The existing "Clear data" button (Data Management topbar) only ever
--   cleared the SIGNED-OUT/local-import store (imports[] + contributing
--   factors held in IndexedDB — see App.clearAllData() in index.html). It has
--   no effect on anything in Postgres. A signed-in user had no way to wipe a
--   test/demo import and start over; this function is that path.
--
-- WHAT IS WIPED (single-tenant fleet data — see each table's own migration)
--   driver_asset_actions, driver_asset_severity, contributing_factors,
--   alert_cases, import_name_review, events, imports, driver_master,
--   driver_aliases, driver_alias_log, drivers.
--
-- WHAT IS DELIBERATELY NOT TOUCHED
--   auth.users, profiles (0004) — account/role records; wiping these signs
--   everyone out or strips their access.
--   user_settings (0004) — per-user display name/preferences, unrelated to
--   fleet data.
--   username_lookup_attempts (0013) — a security rate-limit log; clearing it
--   would reset an attacker's throttling budget, the opposite of its purpose.
--
-- ORDER AND THE AUDIT-TRIGGER CAVEAT
--   driver_aliases has an AFTER DELETE trigger (trg_driver_alias_audit, 0018)
--   that inserts one row into driver_alias_log per deleted alias. TRUNCATE
--   does not fire row-level triggers (DELETE does), so both tables are
--   TRUNCATEd here rather than DELETEd — the point of a full reset is an
--   empty audit log, not one freshly repopulated with a thousand "delete"
--   entries by the reset itself.
--
--   TRUNCATE ... CASCADE is used so FK-dependent tables (events, alert_cases,
--   import_name_review, driver_aliases) are handled in the same statement as
--   their parents (imports, drivers) without hand-ordering every leaf —
--   Postgres computes the dependency order itself. driver_master and the
--   severity/actions/factors tables have no inbound FKs from anything else in
--   this list, so CASCADE is a no-op for them and only guards against a
--   future migration adding one.
--
-- SECURITY DEFINER, matching every other bulk-write RPC in this schema
-- (dds_replace_drivers, dds_upsert_drivers, dds_ingest): the writes are
-- scoped by this function's own logic, not by caller-supplied policies, and
-- execute is granted only to `authenticated`.
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
    'imports',             (select count(*) from public.imports),
    'events',              (select count(*) from public.events),
    'alertCases',          (select count(*) from public.alert_cases),
    'importNameReview',    (select count(*) from public.import_name_review),
    'contributingFactors', (select count(*) from public.contributing_factors),
    'driverAssetActions',  (select count(*) from public.driver_asset_actions),
    'driverAssetSeverity', (select count(*) from public.driver_asset_severity),
    'driverMaster',        (select count(*) from public.driver_master),
    'drivers',             (select count(*) from public.drivers),
    'driverAliases',       (select count(*) from public.driver_aliases)
  ) into v_counts;

  -- Two statements, not one: driver_aliases/driver_alias_log must both be
  -- TRUNCATEd (see comment above) rather than pulled into the same CASCADE
  -- as imports/drivers, which is otherwise harmless but easier to reason
  -- about split apart.
  truncate table
    public.imports,
    public.driver_master,
    public.contributing_factors,
    public.driver_asset_actions,
    public.driver_asset_severity
    cascade;

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
