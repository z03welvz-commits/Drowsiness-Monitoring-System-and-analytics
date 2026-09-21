-- ============================================================================
-- DDS — 0163_fix_reresolve_trigger_double_fire_on_conflict
-- ----------------------------------------------------------------------------
-- Bug report: "Confirm Match" in Data Management (Minestat tab) failed with
-- Could not confirm match: relation "_reresolved" already exists
--
-- Root cause: dds_confirm_alias() (called by dds_resolve_review() and
-- dds_minestat_resolve_review(), the RPCs behind the Confirm Match modal)
-- does `insert into driver_aliases (...) on conflict (norm_name) do update
-- ...`. That hits the ON CONFLICT DO UPDATE path whenever the raw name
-- already has an alias row (re-confirming a name, or correcting an earlier
-- auto/fuzzy alias to a different employee) — both realistic, common cases,
-- not an edge case.
--
-- Per Postgres statement-trigger semantics, an INSERT ... ON CONFLICT DO
-- UPDATE that actually hits the conflict path fires BOTH the AFTER INSERT
-- statement-level trigger AND the AFTER UPDATE statement-level trigger for
-- that same statement. trg_driver_aliases_reresolve (0138) is registered
-- on both events, calling the same function, so it fires TWICE in that
-- case, within the same transaction:
--   1st firing: dds_reresolve_all() creates _reresolved, drops it,
--               dds_minestat_reresolve_all() creates _reresolved again and
--               leaves it open (ON COMMIT DROP only drops at COMMIT).
--   2nd firing: dds_reresolve_all() tries to create _reresolved again and
--               collides with the one still open from the 1st firing's
--               dds_minestat_reresolve_all() call — "already exists".
--
-- 0138 already guarded against the two calls WITHIN one firing colliding
-- with each other; it did not guard against a second firing (which wasn't
-- anticipated) colliding with the previous firing's leftover table. Fix:
-- drop pg_temp._reresolved defensively at the very start of the trigger
-- function too, so a second firing in the same transaction always starts
-- clean regardless of what an earlier firing left behind.
-- ============================================================================
create or replace function public.trg_reresolve_name_review_on_roster_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  drop table if exists pg_temp._reresolved;
  perform public.dds_reresolve_all(500);
  drop table if exists pg_temp._reresolved;
  perform public.dds_minestat_reresolve_all(500);
  drop table if exists pg_temp._reresolved;
  return null;
end;
$function$;
