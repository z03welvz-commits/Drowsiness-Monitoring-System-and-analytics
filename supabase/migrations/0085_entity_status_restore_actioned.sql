-- ============================================================================
-- DDS — 0085_entity_status_restore_actioned
-- ----------------------------------------------------------------------------
-- Found while verifying the 0084 fix: entity_status.status's live CHECK
-- constraint only allows ('required', 'monitoring') — 'actioned' is missing.
-- 0033's original definition was `check (status in ('required', 'actioned'))`.
-- Some later migration added the 'monitoring'/monitor_until/recurrence_count
-- columns (applied live as "entity_status_streak_and_recurrence",
-- 2026-09-04 — no corresponding file was ever committed to this repo, a
-- separate repo/live drift issue) and rewrote this CHECK to add 'monitoring'
-- but dropped 'actioned' in the process.
--
-- Impact, confirmed by testing directly against the live database: EVERY
-- call to dds_log_entity_action() — Driver & Asset Monitoring's "Log an
-- action" modal, and Driver Streaks' action dropdown after its own recent
-- fix — has been failing with a 23514 CHECK violation the instant it tries
-- to write status = 'actioned'. This is the real root cause of entity_status
-- being completely empty in production and of "View resolved / history"
-- always showing nothing — not just the dds_driver_asset_weekly() status
-- computation fixed in 0084, but the write path underneath it never
-- succeeding at all.
--
-- Fix: restore 'actioned' as a valid value alongside 'required'/'monitoring'.
-- ============================================================================

alter table public.entity_status
  drop constraint entity_status_status_check;

alter table public.entity_status
  add constraint entity_status_status_check check (status in ('required', 'monitoring', 'actioned'));
