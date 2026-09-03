-- ============================================================================
-- DDS — 0052_dds_reset_fleet_data_admin_gate
-- ----------------------------------------------------------------------------
-- Security fix: dds_reset_fleet_data() (0022) truncates every fleet-data
-- table in the schema (events, imports, drivers, driver_master, alert_cases,
-- contributing_factors, driver_asset_actions/severity, driver_aliases +
-- audit log) but only ever checked `auth.uid() is not null` — the same bar
-- as a normal read. It is granted to `authenticated`, not gated by role, so
-- any signed-in user regardless of role ('oa'/'b2b', not just 'admin') could
-- call it directly (e.g. `supabase.rpc('dds_reset_fleet_data')` from
-- devtools — the publishable key is public by design, RLS/grants are the
-- real boundary) and irreversibly wipe the fleet's entire history. Nothing
-- in the UI calls this function today (Settings > System Management's
-- "Delete all data" button is a client-side simulation, not wired to it —
-- see index.html), so this was a live, invisible gap rather than a visible
-- bug.
--
-- Every other privileged action in this schema already checks the caller's
-- own profile before doing anything destructive/administrative
-- (profiles_update_admin, 0004; the invite-user Edge Function). This
-- migration brings dds_reset_fleet_data() in line with that same pattern:
-- require the caller to be an approved admin, not just signed in.
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

  if not exists (
    select 1 from public.profiles p
    where p.user_id = auth.uid() and p.role = 'admin' and p.status = 'approved'
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
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
