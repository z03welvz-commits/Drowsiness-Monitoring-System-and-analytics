-- ============================================================================
-- DDS — 0059_alert_cases_action_type_check
-- ----------------------------------------------------------------------------
-- Backfills another migration that was never committed to this repo, in the
-- same "reconstructed from live" family as 0058. 0005_alert_cases.sql (itself
-- a live-catalog reconstruction, per its own header) created
-- public.alert_cases with an `action_type text` column but no CHECK
-- constraint on it at all. Yet 0098_alert_cases_action_type_add_replace.sql's
-- own comment states the constraint "only ever allowed 'Reviewed',
-- 'Escalated', 'Coached', 'Dismissed', 'Spare', 'Continue', 'Other' — no
-- 'Replace'" before it ran — so `alert_cases_action_type_check` demonstrably
-- existed on the live database before 0098 added 'Replace' to it. No
-- committed migration between 0005 and 0098 ever creates it (confirmed by
-- grep across supabase/migrations/*.sql), so a from-scratch replay fails at
-- 0098's `drop constraint alert_cases_action_type_check` with "constraint
-- ... does not exist" — the same missing-history pattern as entity_status/
-- 0058, just for a different table.
--
-- Like 0058, this is written to the CURRENT live constraint definition
-- (checked directly via pg_get_constraintdef on the real project) rather
-- than the older pre-0098 vocabulary, specifically so it is a safe no-op if
-- ever applied to the already-migrated production database, where 0098 has
-- already run and is recorded as applied (and so would not run again to
-- restore 'Replace' if this migration reset the list without it). On a
-- fresh from-scratch replay, 0098 still runs afterward and harmlessly drops
-- + recreates the identical 8-value constraint this migration already put
-- in place.
-- ============================================================================

alter table public.alert_cases
  drop constraint if exists alert_cases_action_type_check;

alter table public.alert_cases
  add constraint alert_cases_action_type_check check (
    action_type is null or action_type = any (array[
      'Reviewed', 'Escalated', 'Coached', 'Dismissed',
      'Spare', 'Continue', 'Other', 'Replace'
    ])
  );
