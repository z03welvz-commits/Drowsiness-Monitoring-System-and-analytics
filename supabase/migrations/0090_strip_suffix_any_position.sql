-- ============================================================================
-- DDS — 0090_strip_suffix_any_position
-- ----------------------------------------------------------------------------
-- dds_strip_suffix (0018, widened by 0054) already handles three shapes of
-- a generational suffix (JR/SR/II/III/IV): trailing ("..., JUAN JR"),
-- comma-segment ("SANTOS, JUAN, JR"), and before-comma ("SANTOS JR, JUAN").
-- Live MineStat imports surfaced two more real shapes it still misses,
-- confirmed against the current open Name Review queue:
--   - suffix as a MIDDLE comma segment with more content after it:
--       "JAPITANA, JR, RAMIL Z"          (0054's comma-segment rule only
--                                          matches a suffix as the LAST
--                                          segment, not a middle one)
--   - suffix embedded mid-string with words on both sides (often from a
--     stray comma already inside the source LAST_NAME cell, e.g.
--     "CABIGAS," as the raw cell value, which the app's own
--     `LAST_NAME + ', ' + FIRST_NAME` template then turns into a double
--     comma): "CABIGAS,, JOEVANIE JR. HELECAME", "MAHINAY, JR., FERNANDO
--     CANOY" — neither the trailing, comma-segment, nor before-comma rule
--     fires because the suffix isn't at the string end, isn't the LAST
--     comma segment, and has real content immediately after it.
-- Two confirmed against the live masterlist: the raw import "MERABELES,,
-- ROGER JR. SILVESTRE" and "APARILLA,, VICENTE JR. BRANDARES" now
-- normalize to an EXACT match on "MERABELES, ROGER SILVESTRE" (emp_no
-- 8153957) and "APARILLA, VICENTE BRANDARES" (emp_no 9091459) respectively
-- — both sat in Name Review, unresolved, purely because of suffix
-- placement, not because the person was missing from the masterlist.
--
-- Fix: strip the suffix wherever it appears as a standalone token (`\m`/`\M`
-- are Postgres's word-boundary escapes — see the ARE docs; `\b` means
-- backspace here, not boundary), then clean up whatever comma/space
-- artifact removing it leaves behind, in the order: stray space before a
-- comma, a resulting double comma, a resulting double space, then trim any
-- leading/trailing comma-space. This one general rule provably subsumes
-- all three of 0054's positional rules (verified against every existing
-- shape live before applying — SANTOS,JUAN,JR / SANTOS JR,JUAN / SANTOS,
-- JUAN JR all still collapse to "SANTOS, JUAN"), so it replaces them
-- rather than running alongside them.
--
-- `drivers.bare_name`/`surname_first_key`/`name_skeleton`/
-- `surname_first_letter`/`bare_name_len` (0071) are GENERATED ALWAYS ...
-- STORED columns — redefining the function they're built from does NOT
-- retroactively recompute already-stored values (Postgres only recomputes
-- a stored generated column on that row's own next INSERT/UPDATE). The
-- no-op UPDATE below forces every existing driver row to rewrite and pick
-- up the new dds_strip_suffix() output; skipping it would leave every
-- existing masterlist row matching on the OLD suffix logic while only
-- newly-resolved incoming names (computed fresh, not from a stored column)
-- saw the fix — a one-sided change the two sides of dds_resolve_name()
-- would have silently disagreed about.
-- ============================================================================

create or replace function public.dds_strip_suffix(s text)
returns text
language sql immutable parallel safe
set search_path = public
as $$
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
$$;

-- Force every existing drivers row to regenerate bare_name/surname_first_key/
-- name_skeleton/surname_first_letter/bare_name_len under the new function.
update public.drivers set full_name = full_name;
