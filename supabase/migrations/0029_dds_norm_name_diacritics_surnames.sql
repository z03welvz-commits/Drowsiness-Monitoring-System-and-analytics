-- ============================================================================
-- DDS — 0029_dds_norm_name_diacritics_surnames
-- ----------------------------------------------------------------------------
-- Closes two confirmed gaps in the name-matching ladder from 0018:
--
--   1. DIACRITICS BEYOND Ñ. dds_norm_name() already folds Ñ/ñ/the mangled '?'
--      to N, but no other accented Latin character was ever handled — "JOSÉ"
--      and "JOSE" normalized to two different strings, matching only if they
--      happened to be close enough to survive to the bounded-fuzzy tier (T5).
--
--   2. HYPHENATED / MULTI-WORD SURNAME PREFIXES. "DE LA CRUZ" and
--      "DELA CRUZ" are the same surname spelled with different internal
--      spacing, but nothing normalized them to the same key — same failure
--      mode as (1), relying on T5 to happen to catch it.
--
-- Both are real, observed classes of name variance in this workforce's data,
-- not speculative. Neither touches dds_resolve_name()'s tier ladder, the
-- ambiguity-refusal logic, or the DUP_FLAG-equivalent "two employees, one
-- key -> review, never guess" rule — they only change what the normalization
-- functions output as a KEY, which is what T0-T4 compare on.
-- ============================================================================

-- ── Gap 1 — diacritics ────────────────────────────────────────────────────
-- Extends the existing translate() call. upper() already runs before this
-- translate (line below), which folds lowercase accented letters to their
-- uppercase form in a UTF8 database — the lowercase entries in the source set
-- are kept anyway as a defensive no-cost redundancy, exactly the same
-- reasoning the existing Ññ? segment already applies.
--
-- POSITIONAL BALANCE, same requirement the file's own original comment
-- insists on: source and target must be the same length, or Postgres
-- silently DELETES trailing unmapped characters rather than erroring.
-- ÁÉÍÓÚáéíóúÜü (12 chars) -> AEIOUaeiouUu (12 chars), verified 1:1 before
-- shipping.
--
-- ALSO FIXES A PRE-EXISTING BUG found while re-verifying this function live
-- ahead of this migration: the comma-spacing regexes were written as the
-- literal characters `s*,s*` / `s+` (a bare lowercase "s"), not `\s*,\s*` /
-- `\s+` (whitespace). Since no literal "s" sits next to a comma in a typical
-- name, `s*` matched zero characters on each side and still inserted its own
-- ', ' — so 'NUNEZ, JOSE' (already single-spaced) became 'NUNEZ,  JOSE'
-- (double-spaced) instead of staying unchanged, and 'SANTOS ,  MARIA'
-- normalized to 'SANTOS ,   MARIA' rather than the intended 'SANTOS, MARIA'
-- — confirmed live, not a re-derivation: this migration's own pre-flight
-- test run caught it. Both keys still round-trip consistently against
-- THEMSELVES (the bug is symmetric, so two inputs that already matched each
-- other before this fix still match each other after), which is why it
-- shipped invisibly for as long as it did — but a literal double space is a
-- real, unnecessary difference from the same name written normally, so it is
-- corrected here now that this function is already being touched.

create or replace function public.dds_norm_name(s text)
returns text
language sql immutable parallel safe
set search_path = public
as $$
  select nullif(
    trim(regexp_replace(
      regexp_replace(
        translate(
          upper(coalesce(s, '')),
          -- Ñ, ñ and the mangled '?' fold to N (unchanged from 0018). Then
          -- the other Latin diacritics this workforce's data actually
          -- carries fold to their plain-letter form. Then punctuation that
          -- varies freely between typists, plus the non-breaking space
          -- (U+00A0) that spreadsheet exports scatter through name cells and
          -- that trim() does not touch, all fold to a plain space.
          --
          -- THE COMMA IS DELIBERATELY NOT IN THIS SET — see 0018's own
          -- comment; unchanged here, tier 3 still depends on it surviving.
          --
          -- POSITIONAL: character i of the first string maps to character i
          -- of the second, so the two MUST stay the same length. Split and
          -- aligned below so balance is visible, not counted.
          E'Ññ?' || E'ÁÉÍÓÚáéíóúÜü' || E'.-/''' || E' ',
          'NNN'      || 'AEIOUaeiouUu'    || '    '    || ' '
        ),
        '\s*,\s*', ', ', 'g'
      ),
      '\s+', ' ', 'g'
    )),
  '');
$$;

-- ── Gap 2 — hyphenated / multi-word surname prefixes ───────────────────────
-- Deliberately narrow: an enumerable, bounded prefix list, the same shape
-- dds_strip_suffix() already uses for JR/SR/II/III/IV rather than a general
-- heuristic. A general "collapse any internal space in a surname" rule would
-- risk merging genuinely different surnames (e.g. "SAN JUAN" and
-- "SAN PEDRO" both start with "SAN" but must NEVER become the same key) — so
-- this only ever collapses the INTERNAL space of a matched two-word prefix
-- token itself, never touches the boundary space before the rest of the
-- surname, and never truncates to the prefix alone. A missed prefix is no
-- worse than today (falls through to the fuzzy tier); an over-eager one
-- would be a new, worse failure mode this design avoids.
--
-- Only DE LA / DE LOS / VDA DE are two-word prefixes with an internal space
-- to collapse in the first place — DEL/SAN/SANTA/STO/STA are already single
-- tokens, so "SAN JUAN" and "SAN PEDRO" are untouched by this function and
-- stay distinct, exactly as required. Verified against a scratch query
-- before shipping: 'DE LA CRUZ' and 'DELA CRUZ' both -> 'DELA CRUZ';
-- 'SAN JUAN'/'SAN PEDRO' both pass through unchanged and distinct.
--
-- Applied only to the surname side, inside dds_surname_of() below — never to
-- dds_norm_name() itself, which stays a general-purpose key also used by the
-- trigram index. Scoping the collapse to where surname comparison actually
-- happens (tier 3's dds_surname_first_key(), and indirectly tier 2 via
-- dds_strip_suffix on the already-normalized string) keeps the blast radius
-- to exactly the ladder rungs that reason about surnames.

create or replace function public.dds_collapse_surname_prefix(s text)
returns text
language sql immutable parallel safe
set search_path = public
as $$
  select
    regexp_replace(
      regexp_replace(
        regexp_replace(
          coalesce(s, ''),
          '^DE\s+LA(\s+)',  'DELA\1',  'g'
        ),
        '^DE\s+LOS(\s+)', 'DELOS\1', 'g'
      ),
      '^VDA\s+DE(\s+)', 'VDADE\1', 'g'
    );
$$;

create or replace function public.dds_surname_of(s text)
returns text
language sql immutable parallel safe
set search_path = public
as $$
  select public.dds_collapse_surname_prefix(
    public.dds_strip_suffix(
      case when position(',' in coalesce(s, '')) > 0
        then split_part(s, ',', 1)
        else s
      end
    )
  );
$$;

-- Re-pin search_path on dds_strip_suffix too, since this migration already
-- touches the surname-comparison call chain and the function was never
-- pinned live (confirmed via pg_proc.proconfig before this migration) —
-- body is byte-identical to 0018's original, only the missing clause added.
create or replace function public.dds_strip_suffix(s text)
returns text
language sql immutable parallel safe
set search_path = public
as $$
  select nullif(trim(regexp_replace(
    coalesce(s, ''), '\s+(JR|SR|II|III|IV)$', '', 'g'
  )), '');
$$;

-- ── Re-seed aliases against the new normalization ──────────────────────────
-- A stale driver_aliases row keyed on the OLD norm_name would produce a false
-- T0 alias hit that bypasses the fresh tier ladder entirely — the exact
-- inconsistency the ambiguity-safety guarantee cannot protect against, since
-- T0 is a direct lookup, not a re-resolve. Re-running the seed insert gives
-- every newly-collapsed name (an accented or hyphenated-surname roster entry)
-- a fresh seed alias immediately. Never overwrites a human confirmation —
-- same `where a.source <> 'human'` guard dds_upsert_drivers() already uses.
insert into public.driver_aliases as a (norm_name, raw_name, emp_no, tier, source)
select public.dds_norm_name(d.full_name), d.full_name, d.emp_no, 'seed', 'seed'
from public.drivers d
where public.dds_norm_name(d.full_name) is not null
on conflict (norm_name) do update
  set emp_no     = excluded.emp_no,
      raw_name   = excluded.raw_name,
      updated_at = now()
  where a.source <> 'human';
