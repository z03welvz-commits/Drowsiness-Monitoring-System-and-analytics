-- ============================================================================
-- DDS — 0055_client_side_normalization_columns
-- ----------------------------------------------------------------------------
-- ARCHITECTURE CHANGE: normalization, shift/date derivation, sync-interval
-- calculation, and employee-name resolution move from the database to the
-- browser. The client (index.html's DDS_LINK module) now computes shift,
-- shift_date, actionable, sync_seconds and emp_no/operator BEFORE calling
-- dds_ingest()/dds_minestat_ingest(), using an exact JS port of the same
-- dds_shift()/dds_shift_date()/dds_actionable()/dds_resolve_name() logic
-- these columns used to compute server-side (ported from 0001, 0031, 0018,
-- 0029, 0054 — verified against those bodies, not re-derived).
--
-- Supabase's role changes from "normalization engine" to "clean persistent
-- data store": it stores whatever fully-resolved values the client sends,
-- validates them at the boundary (NOT NULL / CHECK constraints, unchanged),
-- and no longer computes them itself on the normal ingest path.
--
-- WHY THIS IS ADDITIVE, NOT A RENAME
--   events.shift/shift_date/actionable/sync_seconds keep their existing
--   names — every RPC and every JS render path that already reads them
--   (dds_metrics, dds_alert_logs, dds_driver_asset_weekly, and a dozen
--   more catalogued in the pre-migration audit) keeps working unmodified.
--   Only the COLUMN KIND changes: from `GENERATED ALWAYS AS (...) STORED`
--   (computed by Postgres, cannot be written directly) to an ordinary
--   column the client now populates explicitly. Existing rows are
--   UNCHANGED by this migration — `ALTER COLUMN ... DROP EXPRESSION`
--   freezes each row's already-computed value in place as a plain value;
--   it does not recompute or NULL anything.
--
--   dds_shift()/dds_shift_date()/dds_actionable() themselves are NOT
--   dropped. They remain available for: (a) dds_ingest()/
--   dds_minestat_ingest() to compute a server-side fallback if a client
--   ever sends a row without these fields (old app versions, direct API
--   callers, or a client bug), so a malformed upload degrades to "computed
--   server-side, same as before" rather than "silently wrong data", and
--   (b) a one-off consistency check between client- and server-computed
--   values while the new client-side path is still bedding in.
--
-- WHAT THIS MIGRATION DOES NOT DO
--   It does not touch alert_cases' real columns (updated_by/status_value/
--   action_type stay exactly as they are — see the alert_actions view
--   below for the spec's requested field names) and does not create a
--   second operational table. Per the additive-migration decision, nothing
--   existing is renamed or dropped.
-- ============================================================================

-- ── events: drop the GENERATED expression, keep the column ────────────────
-- `DROP EXPRESSION` (not `DROP COLUMN` + re-`ADD COLUMN`) preserves every
-- existing row's already-computed value, the column's position, and every
-- index/RLS policy/RPC that references it by name — nothing downstream
-- needs to change for this step alone.
alter table public.events
  alter column shift        drop expression if exists,
  alter column shift_date   drop expression if exists,
  alter column actionable   drop expression if exists,
  alter column sync_seconds drop expression if exists;

-- Now that these are plain columns, restate the NOT-NULL expectations the
-- generated expressions used to guarantee implicitly. shift/shift_date are
-- always derivable from start_time (never null in practice) and every
-- consumer (dds_metrics's GROUP BY, idx_events_shiftdate) assumes a value —
-- but to stay strictly additive and not risk rejecting a historical row
-- that somehow has a null, this only adds a DEFAULT via trigger, not a
-- hard NOT NULL constraint. See the trigger below.

-- ── events: server-side fallback trigger ───────────────────────────────────
-- BEFORE INSERT OR UPDATE trigger that fills shift/shift_date/actionable/
-- sync_seconds ONLY when the client left them null — never overwrites a
-- client-supplied value, even if it disagrees with what the server would
-- have computed (the client is now the source of truth; this is a safety
-- net for incomplete rows, not a silent correction of a client that
-- computed something different on purpose, e.g. a manually corrected
-- shift assignment). emp_no is deliberately NOT touched here — an
-- unresolved emp_no is a legitimate outcome (see Name Review), not a gap
-- to paper over automatically.
create or replace function public.dds_fill_missing_derived_columns()
returns trigger
language plpgsql
as $$
begin
  if new.shift is null then
    new.shift := public.dds_shift(new.start_time);
  end if;
  if new.shift_date is null then
    new.shift_date := public.dds_shift_date(new.start_time);
  end if;
  if new.actionable is null then
    new.actionable := public.dds_actionable(new.start_time, new.update_time);
  end if;
  if new.sync_seconds is null and new.end_time is not null and new.update_time >= new.end_time then
    new.sync_seconds := extract(epoch from (new.update_time - new.end_time))::integer;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_dds_fill_missing_derived_columns on public.events;
create trigger trg_dds_fill_missing_derived_columns
  before insert or update on public.events
  for each row execute function public.dds_fill_missing_derived_columns();

-- ── alert_actions: spec-named read view over alert_cases ───────────────────
-- alert_cases (0005) already IS the action table the architecture calls
-- for — one row per reviewed event, action/status/remarks, who and when —
-- just under names chosen before this spec existed. Rather than rename
-- those columns (which would require updating dds_alert_logs,
-- dds_bulk_log_case_action, dds_bulk_log_case_action_by_driver and every
-- JS caller in the same migration), this view exposes the same rows under
-- the field names the architecture spec uses, so new code can be written
-- against performed_by/status/action_taken without touching what already
-- works. It is a VIEW, not a table: no data is duplicated, and a write to
-- alert_cases through any existing path is immediately visible here.
--
-- alert_id (not event_id) is used as the column name here to match the
-- spec's "alert_id" terminology exactly — it is the same value as
-- alert_cases.event_id, i.e. a foreign key to events.id.
-- security_invoker = true is required, not decorative: without it, a view
-- defaults to running with the CREATING role's privileges rather than the
-- querying user's, silently bypassing alert_cases' RLS policies for every
-- reader of this view — the exact ERROR-level security lint dds_case_records
-- (an unrelated, pre-existing view) was flagged and dropped for elsewhere in
-- this same cleanup. Confirmed live: omitting this clause on first deploy
-- reintroduced that identical lint against alert_actions before this fix.
create or replace view public.alert_actions
with (security_invoker = true)
as
select
  c.id,
  c.event_id as alert_id,
  c.updated_by as performed_by,
  c.status_value as status,
  c.action_type as action_taken,
  c.driver_name,
  c.emp_no,
  c.remarks,
  c.action_date,
  c.created_at,
  c.updated_at
from public.alert_cases c;

comment on view public.alert_actions is
  'Read-oriented alias of alert_cases exposing the architecture spec''s field names (performed_by/status/action_taken/alert_id). Not a separate table — writes still go through alert_cases via dds_bulk_log_case_action()/dds_bulk_log_case_action_by_driver(), same RLS/RPC boundary as before.';

grant select on public.alert_actions to authenticated;
