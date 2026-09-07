-- ============================================================================
-- DDS — 0085_entity_status_restore_actioned
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- Inferred intent: entity_status.status's CHECK constraint gains ('restores')
-- the 'actioned' value alongside 'required'/'monitoring', so
-- dds_log_entity_action() can upsert entity_status to 'actioned' when a
-- driver/asset is logged with a resolving action, and downstream readers
-- (dds_driver_streaks, dds_driver_asset_weekly) can branch on it.
-- ============================================================================

alter table public.entity_status
  drop constraint if exists entity_status_status_check;

alter table public.entity_status
  add constraint entity_status_status_check
  check (status = any (array['required', 'monitoring', 'actioned']));
