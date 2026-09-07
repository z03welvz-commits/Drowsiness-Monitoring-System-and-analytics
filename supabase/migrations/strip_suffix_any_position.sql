-- ============================================================================
-- DDS — strip_suffix_any_position
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- Inferred intent: dds_strip_suffix()'s regex previously likely only matched
-- a JR/SR/II/III/IV suffix token at the end of the string (anchored). The
-- live definition uses \m...\M (word boundaries) with no start/end anchor,
-- so the suffix token is stripped "at any position" in the name, then
-- cleans up any stray comma/space left behind by the removal.
-- ============================================================================

create or replace function public.dds_strip_suffix(s text)
returns text
language sql
immutable parallel safe
set search_path to 'public'
as $function$
  select nullif(
    trim(both ', ' from
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(
              coalesce(s, ''),
              '\m(JR|SR|II|III|IV)\M', '', 'g'  -- strip the suffix token wherever it sits
            ),
            '\s+,', ',', 'g'                     -- collapse a stray space left before a comma
          ),
          '\s*,\s*,', ',', 'g'                   -- collapse a double comma left behind
        ),
        '\s+', ' ', 'g'                          -- collapse a double space left behind
      )
    ),
  '');
$function$;
