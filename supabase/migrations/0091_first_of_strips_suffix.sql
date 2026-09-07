-- ============================================================================
-- DDS — 0091_first_of_strips_suffix
-- ----------------------------------------------------------------------------
-- Follow-up to 0090, found while verifying it against the live Name Review
-- queue: dds_surname_first_key() combines dds_surname_of(s) (which already
-- strips a suffix from the surname segment) with dds_first_of(s) — but
-- dds_first_of() blindly took the SECOND comma-delimited segment as "the
-- given name" with no suffix-stripping of its own. For "JAPITANA, JR,
-- RAMIL Z" (suffix as its own middle comma segment) that segment IS the
-- suffix "JR", so dds_first_of() returned "JR" as if it were the person's
-- given name — surname_first_key came out "JAPITANA JR" instead of
-- "JAPITANA RAMIL", missing the masterlist's real "JAPITANA JR, RAMIL
-- SUROPIA" (emp_no 8945152, surname_first_key "JAPITANA RAMIL") even after
-- 0090's fix to dds_strip_suffix itself.
--
-- Fix: dds_first_of() strips the suffix from its OWN input first, the same
-- way dds_surname_of() already does, before picking the second comma
-- segment — for "JAPITANA, JR, RAMIL Z" that collapses to "JAPITANA, RAMIL
-- Z" first, so segment 2 becomes "RAMIL Z" and the first token "RAMIL" is
-- correctly returned. Verified live before applying: JAPITANA now resolves
-- via the surname_first tier to emp_no 8945152; SANTOS/MERABELES/DELA
-- CRUZ/a plain no-suffix name all produce the same surname_first_key as
-- before (no regression).
--
-- drivers.surname_first_key (0071) is a GENERATED ALWAYS ... STORED column
-- built from dds_first_of() via dds_surname_first_key() — same reasoning as
-- 0090's forced backfill: redefining the function doesn't retroactively
-- recompute rows already written, so every driver row is force-rewritten
-- again here.
-- ============================================================================

create or replace function public.dds_first_of(s text)
returns text
language sql immutable parallel safe
set search_path = public
as $$
  select case when position(',' in coalesce(public.dds_strip_suffix(s), '')) > 0
    then split_part(trim(split_part(public.dds_strip_suffix(s), ',', 2)), ' ', 1)
  end;
$$;

-- Force every existing drivers row to regenerate surname_first_key (and the
-- other dds_strip_suffix()-derived columns, harmlessly re-applied) under
-- the corrected dds_first_of().
update public.drivers set full_name = full_name;
