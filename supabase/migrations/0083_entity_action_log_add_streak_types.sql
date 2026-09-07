-- ============================================================================
-- DDS — 0083_entity_action_log_add_streak_types
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- Inferred intent: entity_action_log.action_type's CHECK constraint gained
-- new allowed values so drivers/assets flagged by the streak-monitoring flow
-- (Driver Streaks / Driver & Asset Monitoring "actioned" status introduced in
-- 0084/0085) can be logged with the same short action vocabulary already used
-- by alert_cases ('Spare', 'Replace'), alongside the pre-existing action set.
-- The live constraint (entity_action_log_action_type_check) currently allows:
--   'Counseled', 'Suspended', 'Reassigned', 'Cleared', 'Spare 3 Days',
--   'Monitor', 'Continue', 'Other', 'Spare', 'Replace'
-- ============================================================================

alter table public.entity_action_log
  drop constraint if exists entity_action_log_action_type_check;

alter table public.entity_action_log
  add constraint entity_action_log_action_type_check
  check (action_type = any (array[
    'Counseled', 'Suspended', 'Reassigned', 'Cleared', 'Spare 3 Days',
    'Monitor', 'Continue', 'Other', 'Spare', 'Replace'
  ]));
