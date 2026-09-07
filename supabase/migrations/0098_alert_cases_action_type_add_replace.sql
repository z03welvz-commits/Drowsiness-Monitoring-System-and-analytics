-- ============================================================================
-- DDS — 0098_alert_cases_action_type_add_replace
-- ----------------------------------------------------------------------------
-- Driver Streaks' "Log an action" logs to TWO tables in one operation
-- (applyStreakAction() in index.html): first alert_cases, via
-- dds_bulk_log_case_action_by_driver(), then entity_action_log, via
-- dds_log_entity_action(). Its dropdown (ACTION_OPTIONS: 'Spare', 'Replace',
-- 'Continue', + free-text 'Other') was extended into entity_action_log's
-- vocabulary back in 0083 ("Per explicit instruction: extend the vocabulary
-- to include 'Spare' and 'Replace' as their own first-class values") — but
-- that migration only touched entity_action_log_action_type_check. It never
-- touched alert_cases_action_type_check, which alert_cases write hits FIRST.
-- That check only ever allowed 'Reviewed', 'Escalated', 'Coached',
-- 'Dismissed', 'Spare', 'Continue', 'Other' — no 'Replace'. So selecting
-- "Replace" on Driver Streaks has been broken since 0083: the alert_cases
-- insert throws a check-constraint violation before entity_action_log is
-- ever reached, surfaced to the user as "Could not log action: new row for
-- relation alert_cases violates check constraint
-- alert_cases_action_type_check".
--
-- Fix: extend alert_cases_action_type_check the same way 0083 already
-- extended entity_action_log's, so both tables accept the same vocabulary
-- for an action logged from the same UI action.
-- ============================================================================

alter table public.alert_cases
  drop constraint alert_cases_action_type_check;

alter table public.alert_cases
  add constraint alert_cases_action_type_check check (
    action_type is null or action_type = any (array[
      'Reviewed', 'Escalated', 'Coached', 'Dismissed',
      'Spare', 'Continue', 'Other', 'Replace'
    ])
  );
