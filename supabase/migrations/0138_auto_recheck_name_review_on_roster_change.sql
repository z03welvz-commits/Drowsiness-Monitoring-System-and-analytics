-- ============================================================================
-- DDS — 0138_auto_recheck_name_review_on_roster_change
-- ----------------------------------------------------------------------------
-- Gap analysis finding: dds_reresolve_all() (DDS import_name_review backlog)
-- and dds_minestat_reresolve_all() (MineStat minestat_name_review backlog,
-- currently 1,072 open rows live) are ONLY ever invoked by the "Re-check
-- unresolved names" buttons in the Name Review tabs — whose own tooltip
-- says "useful after correcting a name or adding an alias", i.e. the app
-- already expects this to matter after a masterlist/alias edit, but nothing
-- ever does it automatically. Same shape of gap as 0137 (events.emp_no),
-- one stage earlier in the pipeline: a masterlist correction or a new alias
-- can turn a stuck review row resolvable, but it stays stuck until a human
-- remembers to click re-check.
--
-- Fix: a statement-level trigger on drivers and driver_aliases (INSERT or
-- UPDATE — a new roster row or alias, or a name correction on an existing
-- one) calls the two EXISTING re-check RPCs directly, capped at 500 rows
-- each exactly like the buttons already are, rather than duplicating their
-- resolution logic.
--
-- One real wrinkle, confirmed live before writing this: dds_reresolve_all()
-- and dds_minestat_reresolve_all() each do
-- `create temporary table _reresolved on commit drop as select ...` — fine
-- when called from separate client round-trips (separate transactions, as
-- the two buttons already do), but calling both within ONE transaction (as
-- this trigger must) makes the second CREATE TEMPORARY TABLE collide with
-- the first's still-open one, since ON COMMIT DROP only drops at COMMIT,
-- not when the function returns ("relation _reresolved already exists").
-- Fixed by dropping it explicitly between the two calls, rather than
-- editing either already-working function's internals.
-- ============================================================================
create or replace function public.trg_reresolve_name_review_on_roster_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  perform public.dds_reresolve_all(500);
  drop table if exists pg_temp._reresolved;
  perform public.dds_minestat_reresolve_all(500);
  return null;
end;
$function$;

drop trigger if exists trg_drivers_reresolve on public.drivers;
create trigger trg_drivers_reresolve
after insert or update on public.drivers
for each statement
execute function public.trg_reresolve_name_review_on_roster_change();

drop trigger if exists trg_driver_aliases_reresolve on public.driver_aliases;
create trigger trg_driver_aliases_reresolve
after insert or update on public.driver_aliases
for each statement
execute function public.trg_reresolve_name_review_on_roster_change();
