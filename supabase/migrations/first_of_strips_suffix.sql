-- ============================================================================
-- DDS — first_of_strips_suffix
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- Inferred intent: dds_first_of() (extracts a first-name token from a
-- "Last, First Middle" string) now runs its input through
-- dds_strip_suffix() first, so a JR/SR/II/III/IV suffix embedded before the
-- comma (e.g. "Smith Jr, John") doesn't leak into the surname portion or
-- shift the comma-split, keeping this function consistent with
-- strip_suffix_any_position above.
-- ============================================================================

create or replace function public.dds_first_of(s text)
returns text
language sql
immutable parallel safe
set search_path to 'public'
as $function$
  select case when position(',' in coalesce(public.dds_strip_suffix(s), '')) > 0
    then split_part(trim(split_part(public.dds_strip_suffix(s), ',', 2)), ' ', 1)
  end;
$function$;
