-- ============================================================================
-- DDS — 0058_entity_status_streak_and_recurrence
-- ----------------------------------------------------------------------------
-- Backfills a migration file that was never committed to this repo. Per
-- 0085_entity_status_restore_actioned.sql's own comment: "Some later
-- migration added the 'monitoring'/monitor_until/recurrence_count columns
-- (applied live as 'entity_status_streak_and_recurrence', 2026-09-04 — no
-- corresponding file was ever committed to this repo, a separate repo/live
-- drift issue) and rewrote this CHECK to add 'monitoring' but dropped
-- 'actioned' in the process." 0085 fixed the CHECK constraint's dropped
-- 'actioned' value, but never added the file for the columns/constraint
-- change it was reacting to — this migration is that missing file,
-- reconstructed from the live schema (`information_schema.columns` /
-- `pg_constraint` on the real project, checked directly), so a from-scratch
-- rebuild (test/parity.sh, or a real disaster-recovery restore) is possible
-- again. `if not exists`/idempotent throughout: this is a no-op against the
-- already-patched live database.
-- ============================================================================

alter table public.entity_status
  add column if not exists monitor_until date,
  add column if not exists recurrence_count integer not null default 0;

do $$ begin
  if exists (
    select 1 from pg_constraint
    where conrelid = 'public.entity_status'::regclass
      and conname = 'entity_status_status_check'
  ) then
    alter table public.entity_status drop constraint entity_status_status_check;
  end if;
  alter table public.entity_status
    add constraint entity_status_status_check check (status in ('required', 'monitoring', 'actioned'));
end $$;
