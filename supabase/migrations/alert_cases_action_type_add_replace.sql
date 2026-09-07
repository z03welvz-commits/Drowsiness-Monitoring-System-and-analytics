-- ============================================================================
-- DDS — alert_cases_action_type_add_replace
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- Inferred intent: alert_cases.action_type's CHECK constraint gains 'Replace'
-- (alongside a pre-existing 'Spare' presumably added earlier), aligning the
-- per-event Alert Logs action vocabulary with the equivalent values already
-- allowed on entity_action_log.action_type (see
-- 0083_entity_action_log_add_streak_types.sql), so the same short
-- resolution actions can be logged consistently at both the event level
-- (alert_cases) and the entity level (entity_action_log).
-- The live constraint (alert_cases_action_type_check) currently allows (when
-- not null): 'Reviewed', 'Escalated', 'Coached', 'Dismissed', 'Spare',
-- 'Continue', 'Other', 'Replace'.
-- ============================================================================

alter table public.alert_cases
  drop constraint if exists alert_cases_action_type_check;

alter table public.alert_cases
  add constraint alert_cases_action_type_check
  check (
    action_type is null
    or action_type = any (array[
      'Reviewed', 'Escalated', 'Coached', 'Dismissed',
      'Spare', 'Continue', 'Other', 'Replace'
    ])
  );
