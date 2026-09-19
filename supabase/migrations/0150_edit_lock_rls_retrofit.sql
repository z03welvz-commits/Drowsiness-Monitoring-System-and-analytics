-- ============================================================================
-- DDS — 0150_edit_lock_rls_retrofit
-- ----------------------------------------------------------------------------
-- Follow-up to 0149. A SECURITY DEFINER RPC (guarded in 0151) bypasses RLS
-- on the tables it touches internally, so guarding the RPC layer alone
-- doesn't stop a direct REST call that skips the RPC entirely and writes to
-- the underlying table directly. This migration closes that path: every
-- table with a raw client-writable policy that currently allows any
-- signed-in user to write (`auth.uid() is not null`, confirmed live, no
-- other restriction) now also requires `public.dds_edit_lock_ok()`.
--
-- `events`/`minestat_shifts`/`drivers` need no changes here — confirmed
-- live they have no direct insert/update/delete policy at all; writes only
-- happen through SECURITY DEFINER RPCs, guarded in 0151 instead.
--
-- `profiles` (Access Management) is deliberately left untouched — see
-- 0149's header for why gating it would create a bootstrapping deadlock.
--
-- Every clause below restates the table's full current expression (not
-- just appending the new condition) so the policy's own conditions stay
-- explicit and readable — this repo's own preference, per 0033/0139's
-- style. `entity_status`'s es_update already carries a USING clause
-- distinct from its WITH CHECK (unlike every other policy touched here,
-- where PostgreSQL reuses USING for an omitted WITH CHECK) — both are
-- altered explicitly so neither is left ungated by accident.
-- ============================================================================

-- ---- alert_cases (the Alert Logs case table) ----
alter policy alert_cases_insert on public.alert_cases
  with check (auth.uid() is not null and updated_by = auth.uid() and public.dds_edit_lock_ok());
alter policy alert_cases_update on public.alert_cases
  using (auth.uid() is not null and public.dds_edit_lock_ok())
  with check (auth.uid() is not null and public.dds_edit_lock_ok());
alter policy alert_cases_delete on public.alert_cases
  using (auth.uid() is not null and public.dds_edit_lock_ok());

-- ---- contributing_factors ----
alter policy factors_insert on public.contributing_factors
  with check (auth.uid() is not null and logged_by = auth.uid() and public.dds_edit_lock_ok());
alter policy factors_update on public.contributing_factors
  using (auth.uid() is not null and public.dds_edit_lock_ok())
  with check (auth.uid() is not null and public.dds_edit_lock_ok());
alter policy factors_delete on public.contributing_factors
  using (auth.uid() is not null and public.dds_edit_lock_ok());

-- ---- imports ----
alter policy imports_insert on public.imports
  with check (auth.uid() is not null and uploaded_by = auth.uid() and public.dds_edit_lock_ok());
alter policy imports_delete on public.imports
  using (auth.uid() is not null and public.dds_edit_lock_ok());
-- No update policy exists on imports — nothing to alter.

-- ---- entity_status (driver/asset monitoring status) ----
alter policy es_upsert on public.entity_status
  with check (auth.uid() is not null and updated_by = auth.uid() and public.dds_edit_lock_ok());
alter policy es_update on public.entity_status
  using (auth.uid() is not null and public.dds_edit_lock_ok())
  with check (updated_by = auth.uid() and public.dds_edit_lock_ok());

-- ---- entity_action_log (append-only; no update/delete policy exists) ----
alter policy eal_insert on public.entity_action_log
  with check (auth.uid() is not null and actor_user_id = auth.uid() and public.dds_edit_lock_ok());

-- ---- driver_asset_actions (append-only; no update/delete policy exists) ----
alter policy daa_insert on public.driver_asset_actions
  with check (auth.uid() is not null and actor_user_id = auth.uid() and public.dds_edit_lock_ok());
