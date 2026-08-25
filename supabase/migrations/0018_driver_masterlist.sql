-- ============================================================================
-- DDS — 0018_driver_masterlist
-- ----------------------------------------------------------------------------
-- PHASE 1 of making the EMPLOYEE NUMBER — not the driver's name — the identity
-- the platform counts by. This migration is deliberately DORMANT: it adds the
-- masterlist and the resolver, but nothing in the app reads either yet. No
-- existing query, chart, KPI or consistency flag changes behaviour here.
--
-- WHY THIS EXISTS
--   events.operator is free text typed by whoever logged the alert, and both
--   dds_metrics() (0006) and derive() in dds-state.js group on it directly.
--   So "DELA CRUZ, JUAN", "Dela Cruz Juan", "DELACRUZ, J." and
--   "DE LA CRUZ, JUAN JR" are four drivers in every number the app produces.
--
--   That is worse than cosmetic. The high-consistency flag fires when MORE
--   THAN HALF of a driver's ACTIVE DAYS exceeded 10 alerts. Splitting one
--   driver across four spellings splits their active days too, so the pattern
--   dissolves and a driver who should be flagged is not. The flag's own
--   failure mode is silence, which is exactly the kind of bug nobody goes
--   looking for.
--
-- RELATIONSHIP TO driver_master (0005)
--   0005 already ships public.driver_master WITH an employee_id column, plus
--   pg_trgm and a trigram index. It is not promoted in place, for one blunt
--   reason: dds_replace_drivers() does `delete from driver_master` on every
--   upload. Hang a foreign key off that and each roster upload either blocks
--   on the FK or cascades away every alias a human ever confirmed — the exact
--   knowledge this design accumulates. driver_master therefore stays as-is,
--   still backing the alert-case name picker, and the new drivers table is
--   UPSERTED, never wiped. 0005's table can be retired in a later phase once
--   the picker reads drivers instead; doing both at once would mean changing
--   a live write path in the same migration that introduces its replacement.
--
-- WHAT IS DEFERRED (named here so the sequence is legible)
--   phase 2 — events.emp_no + resolution during dds_ingest(), observe only
--   phase 3 — import_name_review and the review queue UI
--   phase 4 — dds_metrics()/derive() switch to grouping by emp_no
-- ============================================================================

-- fuzzystrmatch supplies levenshtein_less_equal(), which tier 5 depends on.
-- pg_trgm is already installed by 0005 (into `public` on this project), and
-- the fuzzy shortlist below relies on it — declared there, not re-declared
-- here. fuzzystrmatch has no such precedent, so a fresh replay would fail on
-- an unknown function without this line.
create extension if not exists "fuzzystrmatch";

-- ── The masterlist ─────────────────────────────────────────────────────────
-- One row per real employee, sourced from the conso (manpower) file. Small,
-- authoritative, changes on HR's schedule rather than per-import.
--
-- emp_no is a natural TEXT primary key, not a surrogate uuid. Employee numbers
-- are how this workforce is actually identified on paper and in conso, they
-- are already unique, and events.emp_no (phase 2) is far more legible in a
-- debugging session carrying "10432" than an opaque uuid. Text rather than
-- integer because badge numbers carry leading zeros and occasional letter
-- prefixes, both of which an integer column would silently destroy.

create table if not exists public.drivers (
  emp_no      text primary key,
  full_name   text not null,

  -- 'active' | 'inactive'. A driver absent from the latest conso upload is
  -- marked inactive rather than deleted: their historical alerts must keep
  -- resolving, and a separated employee's past record is precisely what an
  -- investigation needs. Nothing is ever removed from this table by the
  -- normal upload path.
  status      text not null default 'active'
                check (status in ('active', 'inactive')),

  -- Whatever else conso carries. Kept loose on purpose — the conso layout is
  -- not fully known here, and inventing typed columns for fields nobody has
  -- confirmed would be guessing. Promote fields out of this jsonb once the
  -- real file has been seen.
  details     jsonb not null default '{}'::jsonb,

  -- REHIRE POINTER. If conso issues a NEW employee number to a returning
  -- driver, the old row stays (history still resolves through it) and points
  -- here at the current identity. Nullable and unused in phase 1; it exists
  -- now because adding it to an empty table is free, while retrofitting it
  -- after events carry emp_no means re-attributing rows. Whether conso
  -- actually reissues numbers is still an open question — this is the cheap
  -- insurance against the answer being "yes".
  merged_into text references public.drivers(emp_no) on delete set null
                check (merged_into is null or merged_into <> emp_no),

  uploaded_by uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists idx_drivers_status on public.drivers (status);

-- ── Normalization ──────────────────────────────────────────────────────────
-- Ported from Normalize() in the Excel/VBA resolver, which had already been
-- hardened against this data's real defects. Two details are carried over
-- verbatim because both are correct and easy to lose in a rewrite:
--
--   * Ñ handling, INCLUDING the literal '?' case. When a workbook is written
--     out through a codepage that cannot represent Ñ, it arrives as '?' —
--     "NUÑEZ" becomes "NU?EZ". Mapping '?' to 'N' is not a guess; it is the
--     observed corruption of a common Filipino surname. The cost of being
--     wrong is one review item, the cost of omitting it is that every such
--     name silently fails to match.
--   * Non-breaking space (U+00A0), which spreadsheet exports scatter through
--     name cells and which trim() does not touch.
--
-- IMMUTABLE is required, not decorative: the index above is an expression
-- index on this function, and Postgres will not build one over a merely
-- STABLE function.

create or replace function public.dds_norm_name(s text)
returns text
language sql immutable parallel safe
as $$
  select nullif(
    trim(regexp_replace(
      regexp_replace(
        translate(
          upper(coalesce(s, '')),
          -- Ñ, ñ and the mangled '?' fold to N. When a workbook is written
          -- through a codepage that cannot represent Ñ, it arrives as '?' --
          -- 'NUÑEZ' becomes 'NU?EZ'. An observed corruption of a common surname
          -- here, not a guess: the cost of the mapping being wrong is one review
          -- item, the cost of omitting it is that every such name silently fails
          -- to match. Then the punctuation that varies freely between typists,
          -- plus the non-breaking space (U+00A0) that spreadsheet exports scatter
          -- through name cells and that trim() does not touch, all fold to a
          -- plain space.
          --
          -- THE COMMA IS DELIBERATELY NOT IN THIS SET. It is the only surviving
          -- boundary between surname and given names, and dds_surname_first_key()
          -- (tier 3) splits on it. Folding it to a space -- as an earlier version
          -- of this function did -- makes surname_of() return the entire string
          -- and first_of() return null, so the tier silently degrades into an
          -- exact match and stops discarding middle names, which is its whole
          -- purpose. 'SANTOS, MARIA' then fails to match 'SANTOS, MARIA CLARA'.
          -- Verified against Postgres before and after; see the tier-3 case in
          -- test/masterlist-resolver.test.sql.
          --
          -- POSITIONAL: character i of the first string maps to character i of
          -- the second, so the two MUST stay the same length. Postgres silently
          -- DELETES any trailing character of the first that the second does not
          -- cover, turning a punctuation fold into a character drop. The pairs
          -- are split and aligned below so balance is visible, not counted.
          E'Ññ?' || E'.-/''' || E' ',
          'NNN'      || '    '    || ' '
        ),
        -- Normalize spacing AROUND the comma so 'SANTOS ,MARIA' and
        -- 'SANTOS,  MARIA' produce the same key as 'SANTOS, MARIA'.
        's*,s*', ', ', 'g'
      ),
      's+', ' ', 'g'
    )),
  '');
$$;

-- Fuzzy candidate shortlisting (tier 5) searches on the normalized name, so
-- the trigram index must match what that search actually filters on. Placed
-- here, immediately after dds_norm_name() rather than beside the table's own
-- definition above, because an expression index needs the function to exist
-- first — IMMUTABLE alone doesn't let Postgres forward-reference it.
create index if not exists idx_drivers_name_trgm
  on public.drivers using gin (public.dds_norm_name(full_name) gin_trgm_ops);

-- Strips generational suffixes. " JR" and " SR" are matched with a leading
-- space so a surname legitimately ENDING in those letters is untouched.
create or replace function public.dds_strip_suffix(s text)
returns text
language sql immutable parallel safe
as $$
  select nullif(trim(regexp_replace(
    coalesce(s, ''), '\s+(JR|SR|II|III|IV)$', '', 'g'
  )), '');
$$;

-- Consonant skeleton: drop vowels and H, drop spaces. Catches vowel-level
-- typos and doubled letters ("MARIANO" / "MARRIANO" / "MARIANNO") that
-- survive every earlier tier. Deliberately lossy, which is why a skeleton
-- collision is treated as ambiguity rather than a match — see dds_resolve_name.
create or replace function public.dds_name_skeleton(s text)
returns text
language sql immutable parallel safe
as $$
  select nullif(translate(coalesce(s, ''), 'AEIOUH ', ''), '');
$$;

-- Surname / first given name, for the tier-3 key. The conso convention is
-- "SURNAME, GIVEN MIDDLE"; when no comma is present the whole string is
-- treated as the surname, matching SurnameOf() in the VBA.
create or replace function public.dds_surname_of(s text)
returns text
language sql immutable parallel safe
as $$
  select public.dds_strip_suffix(
    case when position(',' in coalesce(s, '')) > 0
      then split_part(s, ',', 1)
      else s
    end
  );
$$;

create or replace function public.dds_first_of(s text)
returns text
language sql immutable parallel safe
as $$
  select case when position(',' in coalesce(s, '')) > 0
    then split_part(trim(split_part(s, ',', 2)), ' ', 1)
  end;
$$;

-- The tier-3 key: surname + first given name, middle names discarded. Middle
-- names are the single most inconsistently recorded part of a name in this
-- data — present, initialled, or absent for the same person across imports —
-- so a key that ignores them matches far more than it costs.
create or replace function public.dds_surname_first_key(s text)
returns text
language sql immutable parallel safe
as $$
  select nullif(concat_ws(' ',
    public.dds_surname_of(s),
    public.dds_first_of(s)
  ), '');
$$;

-- ── Aliases ────────────────────────────────────────────────────────────────
-- The learned mapping from a normalized raw spelling to an employee number.
-- This table is why the review queue shrinks over time instead of arriving
-- fresh every month: the second import of a recurring misspelling resolves at
-- tier 0 without asking a human again.
--
-- norm_name is the primary key, so an alias is global rather than per-import.
-- That is the intent — a spelling means the same person regardless of which
-- file it arrived in. The corollary is that a WRONG alias is durable too,
-- which is what driver_alias_log below exists to make reversible.

create table if not exists public.driver_aliases (
  norm_name    text primary key,

  -- The spelling exactly as it appeared, before normalization. Kept as
  -- evidence: reviewing whether an alias is correct is impossible if the
  -- only surviving record is the normalized form the resolver invented.
  raw_name     text,

  emp_no       text not null references public.drivers(emp_no) on delete cascade,

  -- Which rung of the ladder produced this. Auditable after the fact: if a
  -- tier turns out to over-match on real data, its aliases can be found and
  -- re-reviewed as a group rather than one at a time.
  tier         text not null
                 check (tier in ('seed', 'exact', 'suffix', 'surname_first',
                                 'skeleton', 'fuzzy', 'human')),

  -- 'seed'  — generated from the masterlist's own canonical names
  -- 'auto'  — the resolver was confident enough to decide alone
  -- 'human' — someone confirmed it in the review queue (phase 3)
  source       text not null default 'auto'
                 check (source in ('seed', 'auto', 'human')),

  -- Levenshtein distance for fuzzy matches; null for the exact tiers.
  distance     integer,

  confirmed_by uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists idx_driver_aliases_emp on public.driver_aliases (emp_no);
create index if not exists idx_driver_aliases_source on public.driver_aliases (source);

-- ── Alias history ──────────────────────────────────────────────────────────
-- APPEND-ONLY, following the driver_asset_actions (0007) pattern rather than
-- the overwrite-on-edit shape of alert_cases (0005). A confirmed alias is a
-- durable decision about who an alert belongs to, so a wrong one is durable
-- too. Without this table the first bad confirmation becomes permanent
-- folklore: nobody can see who decided it, when, or what it displaced.

create table if not exists public.driver_alias_log (
  id          bigint generated always as identity primary key,
  norm_name   text not null,
  old_emp_no  text,
  new_emp_no  text,
  action      text not null check (action in ('create', 'update', 'delete')),
  tier        text,
  source      text,
  actor       uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);

create index if not exists idx_driver_alias_log_name
  on public.driver_alias_log (norm_name, created_at desc);

create or replace function public.dds_driver_alias_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    insert into public.driver_alias_log (norm_name, old_emp_no, new_emp_no, action, tier, source, actor)
    values (old.norm_name, old.emp_no, null, 'delete', old.tier, old.source, auth.uid());
    return old;
  end if;

  if tg_op = 'UPDATE' then
    -- Only a change of ATTRIBUTION is worth a log line. Re-confirming an
    -- alias to the same employee (a later import re-asserting what is already
    -- known) would otherwise bury the real reassignments in noise.
    if old.emp_no is distinct from new.emp_no then
      insert into public.driver_alias_log (norm_name, old_emp_no, new_emp_no, action, tier, source, actor)
      values (new.norm_name, old.emp_no, new.emp_no, 'update', new.tier, new.source, auth.uid());
    end if;
    return new;
  end if;

  insert into public.driver_alias_log (norm_name, old_emp_no, new_emp_no, action, tier, source, actor)
  values (new.norm_name, null, new.emp_no, 'create', new.tier, new.source, auth.uid());
  return new;
end;
$$;

drop trigger if exists trg_driver_alias_audit on public.driver_aliases;
create trigger trg_driver_alias_audit
  after insert or update or delete on public.driver_aliases
  for each row execute function public.dds_driver_alias_audit();

-- ── The resolution ladder ──────────────────────────────────────────────────
-- Ported from ResolveName() in the VBA, cheapest and most certain first.
-- Returns (emp_no, tier, distance, candidates) — emp_no null means the caller
-- must send this name to review rather than guess.
--
-- THE RULE THAT MATTERS MOST, inherited from the VBA's DUP_FLAG: when a key
-- maps to two DIFFERENT employees, that key is unusable and the name goes to
-- review. It never picks one. Two drivers sharing a skeleton (brothers, or
-- simply similar names) must reach a human, because a silent wrong
-- attribution is worse than a visible unresolved one — the unresolved one is
-- in a queue somebody works, the wrong one is in a KPI nobody re-checks.
--
-- Fuzzy tolerance follows the VBA's split exactly: distance <= 2 decides on
-- its own, distance 3 is returned as a candidate for review rather than
-- applied. Ties at the best distance are ambiguity, not a preference.

create or replace function public.dds_resolve_name(p_raw text)
returns table (emp_no text, tier text, distance integer, candidates jsonb)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_norm  text;
  v_bare  text;   -- suffix-stripped
  v_sf    text;   -- surname + first
  v_skel  text;
  v_hit   text;
  v_n     integer;
  v_best  integer;
  v_ties  integer;
  v_cands jsonb;
  c_max_dist  constant integer := 3;   -- MAX_DIST
  c_auto_dist constant integer := 2;   -- AUTO_DIST
begin
  v_norm := public.dds_norm_name(p_raw);
  if v_norm is null then
    return query select null::text, 'blank'::text, null::integer, '[]'::jsonb;
    return;
  end if;

  -- T0 — a previously learned alias, including every human confirmation.
  select a.emp_no into v_hit from public.driver_aliases a where a.norm_name = v_norm;
  if v_hit is not null then
    return query select v_hit, 'alias'::text, null::integer, '[]'::jsonb;
    return;
  end if;

  -- T1 — exact match on the canonical name.
  select count(*), min(d.emp_no) into v_n, v_hit
  from public.drivers d
  where public.dds_norm_name(d.full_name) = v_norm;
  if v_n = 1 then
    return query select v_hit, 'exact'::text, null::integer, '[]'::jsonb;
    return;
  elsif v_n > 1 then
    -- Two masterlist rows normalize identically. Genuinely ambiguous, and a
    -- masterlist problem worth seeing rather than resolving away here.
    return query select null::text, 'ambiguous_exact'::text, null::integer,
      (select jsonb_agg(jsonb_build_object('emp_no', d.emp_no, 'name', d.full_name, 'tier', 'exact'))
       from public.drivers d where public.dds_norm_name(d.full_name) = v_norm);
    return;
  end if;

  -- T2 — equal once generational suffixes are stripped from both sides.
  v_bare := public.dds_strip_suffix(v_norm);
  select count(*), min(d.emp_no) into v_n, v_hit
  from public.drivers d
  where public.dds_strip_suffix(public.dds_norm_name(d.full_name)) = v_bare;
  if v_n = 1 then
    return query select v_hit, 'suffix'::text, null::integer, '[]'::jsonb;
    return;
  end if;

  -- T3 — surname + first given name, middle names discarded.
  v_sf := public.dds_surname_first_key(v_norm);
  if v_sf is not null then
    select count(*), min(d.emp_no) into v_n, v_hit
    from public.drivers d
    where public.dds_surname_first_key(public.dds_norm_name(d.full_name)) = v_sf;
    if v_n = 1 then
      return query select v_hit, 'surname_first'::text, null::integer, '[]'::jsonb;
      return;
    end if;
  end if;

  -- T4 — consonant skeleton.
  v_skel := public.dds_name_skeleton(v_bare);
  if v_skel is not null and length(v_skel) >= 3 then
    select count(*), min(d.emp_no) into v_n, v_hit
    from public.drivers d
    where public.dds_name_skeleton(
            public.dds_strip_suffix(public.dds_norm_name(d.full_name))) = v_skel;
    if v_n = 1 then
      return query select v_hit, 'skeleton'::text, null::integer, '[]'::jsonb;
      return;
    end if;
  end if;

  -- T5 — bounded edit distance.
  --
  -- The VBA scanned the entire roster per name; here pg_trgm shortlists first
  -- and levenshtein only scores what survives. Same guards as the VBA: the
  -- surname must start with the same letter (a first-letter typo is rare, and
  -- allowing it multiplies false candidates), and the length difference must
  -- be within tolerance before the distance is computed at all.
  with shortlist as (
    select d.emp_no as cand_emp_no, d.full_name,
           levenshtein_less_equal(
             v_bare,
             public.dds_strip_suffix(public.dds_norm_name(d.full_name)),
             c_max_dist
           ) as dist
    from public.drivers d
    where d.status = 'active'
      and left(public.dds_surname_of(public.dds_norm_name(d.full_name)), 1)
            = left(public.dds_surname_of(v_norm), 1)
      and abs(length(public.dds_strip_suffix(public.dds_norm_name(d.full_name)))
              - length(v_bare)) <= c_max_dist
  )
  -- s.* is qualified throughout, and the CTE column is named cand_emp_no
  -- rather than emp_no, because this function's RETURNS TABLE declares an
  -- output parameter called emp_no: an unqualified reference inside the body
  -- is ambiguous between the two and Postgres raises 42702 rather than
  -- guessing. That error only fires once execution reaches the fuzzy tier,
  -- so it is invisible to any test whose names all match on an earlier rung.
  select jsonb_agg(jsonb_build_object(
           'emp_no', s.cand_emp_no, 'name', s.full_name,
           'tier', 'fuzzy', 'distance', s.dist
         ) order by s.dist, s.cand_emp_no)
  into v_cands
  from shortlist s where s.dist <= c_max_dist;

  v_cands := coalesce(v_cands, '[]'::jsonb);

  if jsonb_array_length(v_cands) = 0 then
    return query select null::text, 'none'::text, null::integer, '[]'::jsonb;
    return;
  end if;

  v_best := (v_cands -> 0 ->> 'distance')::integer;
  select count(*) into v_ties
  from jsonb_array_elements(v_cands) c
  where (c ->> 'distance')::integer = v_best;

  -- A tie at the best distance is ambiguity. Two names equally close to the
  -- raw spelling means the raw spelling does not identify a person, and no
  -- ordering of the candidate list changes that fact.
  if v_ties = 1 and v_best <= c_auto_dist then
    return query select (v_cands -> 0 ->> 'emp_no')::text, 'fuzzy'::text, v_best, v_cands;
  else
    return query select null::text, 'fuzzy_review'::text, v_best, v_cands;
  end if;
end;
$$;

-- ── Roster upload ──────────────────────────────────────────────────────────
-- UPSERT, not replace. This is the single most important behavioural
-- difference from dds_replace_drivers() (0005), which deletes the whole table
-- on every upload. Deleting is incompatible with everything above: aliases
-- reference drivers, so a wipe would cascade away confirmed human decisions,
-- and historical events (phase 2) would lose the identity they resolved to.
--
-- Absent-from-file therefore means INACTIVE, never gone. A separated driver's
-- alerts must still attribute to them; that record is exactly what a later
-- investigation reads.
--
-- p_rows: [{ emp_no, name, status?, details? }]
-- Returns a summary rather than a bare count, because "inserted 3, updated
-- 240, deactivated 12" is what makes an upload's effect reviewable, while a
-- single number hides a roster that arrived half-empty.
--
-- SECURITY DEFINER, matching the other write RPCs in this schema: the writes
-- are scoped by this function's own logic, not by caller policies.

create or replace function public.dds_upsert_drivers(
  p_rows        jsonb,
  p_deactivate  boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seen        text[];
  v_inserted    integer := 0;
  v_updated     integer := 0;
  v_deactivated integer := 0;
  v_skipped     integer := 0;
  v_aliased     integer := 0;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  -- `on commit drop` alone is not enough: it fires at COMMIT, so a second
  -- call inside the SAME transaction hits a table that still exists and
  -- fails with 42P07. Dropping first makes the function re-entrant, which
  -- matters because a caller uploading two roster files back to back (or any
  -- future code path that wraps both in one transaction) would otherwise get
  -- an error on the second one for no reason a user could act on.
  drop table if exists _incoming;
  create temporary table _incoming (
    emp_no text primary key, full_name text, status text, details jsonb
  ) on commit drop;

  -- distinct on (emp_no) dedupes within the file itself. A conso export
  -- listing the same person twice must not abort the whole upload — the same
  -- defence dds_replace_drivers() applies with distinct on (lower(name)).
  --
  -- `with ordinality` is what makes "last row wins" true rather than merely
  -- hoped for: jsonb_array_elements has no inherent row order to ORDER BY, so
  -- without it the surviving duplicate would be whichever row the executor
  -- happened to emit last. ord desc picks the one furthest down the sheet,
  -- matching how a person reading top-to-bottom would resolve the conflict.
  insert into _incoming (emp_no, full_name, status, details)
  select distinct on (trim(r ->> 'emp_no'))
         trim(r ->> 'emp_no'),
         trim(r ->> 'name'),
         coalesce(nullif(trim(r ->> 'status'), ''), 'active'),
         coalesce(r -> 'details', '{}'::jsonb)
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) with ordinality as t(r, ord)
  where nullif(trim(r ->> 'emp_no'), '') is not null
    and nullif(trim(r ->> 'name'), '')   is not null
  order by trim(r ->> 'emp_no'), t.ord desc;

  select count(*) into v_skipped
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
  where nullif(trim(r ->> 'emp_no'), '') is null
     or nullif(trim(r ->> 'name'), '')   is null;

  -- A file that produced no usable rows is a mistake, not an instruction to
  -- deactivate the entire workforce. Refuse it outright.
  if (select count(*) from _incoming) = 0 then
    raise exception 'EMPTY_ROSTER';
  end if;

  select array_agg(emp_no) into v_seen from _incoming;

  with up as (
    insert into public.drivers as d (emp_no, full_name, status, details, uploaded_by)
    select i.emp_no, i.full_name,
           case when i.status in ('active', 'inactive') then i.status else 'active' end,
           i.details, auth.uid()
    from _incoming i
    on conflict (emp_no) do update
      set full_name  = excluded.full_name,
          status     = excluded.status,
          details    = excluded.details,
          updated_at = now()
    returning (xmax = 0) as was_insert
  )
  select count(*) filter (where was_insert),
         count(*) filter (where not was_insert)
  into v_inserted, v_updated
  from up;

  -- Anyone not in this file is inactive, not deleted. Optional so a partial
  -- or supplementary roster can be loaded without retiring everyone missing
  -- from it — a real operational case (one area's list, not the whole fleet).
  if p_deactivate then
    update public.drivers
       set status = 'inactive', updated_at = now()
     where status = 'active'
       and not (emp_no = any(v_seen));
    get diagnostics v_deactivated = row_count;
  end if;

  -- Seed an alias for each canonical name. Without this the resolver would
  -- re-derive the identity mapping for names that match exactly, on every
  -- import, forever. Seeds never overwrite a human confirmation: that is the
  -- point of the source <> 'human' guard, and it is what stops a routine
  -- roster upload from quietly undoing review work.
  with seeded as (
    insert into public.driver_aliases as a (norm_name, raw_name, emp_no, tier, source)
    select public.dds_norm_name(i.full_name), i.full_name, i.emp_no, 'seed', 'seed'
    from _incoming i
    where public.dds_norm_name(i.full_name) is not null
    on conflict (norm_name) do update
      set emp_no     = excluded.emp_no,
          raw_name   = excluded.raw_name,
          updated_at = now()
      where a.source <> 'human'
    returning 1
  )
  select count(*) into v_aliased from seeded;

  return jsonb_build_object(
    'inserted',    v_inserted,
    'updated',     v_updated,
    'deactivated', v_deactivated,
    'skipped',     v_skipped,
    'aliasesSeeded', v_aliased,
    'total',       v_inserted + v_updated
  );
end;
$$;

-- ── Alias maintenance ──────────────────────────────────────────────────────
-- The write path the review queue (phase 3) will use for all five of its fix
-- routes, and the reversal path that keeps a wrong confirmation from becoming
-- permanent. Both are exposed now so the table is never edited ad hoc.

create or replace function public.dds_confirm_alias(
  p_raw_name text,
  p_emp_no   text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_norm text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  v_norm := public.dds_norm_name(p_raw_name);
  if v_norm is null then raise exception 'BLANK_NAME'; end if;

  if not exists (select 1 from public.drivers where emp_no = p_emp_no) then
    raise exception 'UNKNOWN_EMPLOYEE';
  end if;

  -- source='human' unconditionally: this function is only ever reached by a
  -- person making a decision, and that provenance is what protects the row
  -- from being overwritten by the next roster upload's seeding pass.
  insert into public.driver_aliases (norm_name, raw_name, emp_no, tier, source, confirmed_by)
  values (v_norm, p_raw_name, p_emp_no, 'human', 'human', auth.uid())
  on conflict (norm_name) do update
    set emp_no       = excluded.emp_no,
        raw_name     = excluded.raw_name,
        tier         = 'human',
        source       = 'human',
        confirmed_by = auth.uid(),
        updated_at   = now();

  return jsonb_build_object('normName', v_norm, 'empNo', p_emp_no);
end;
$$;

create or replace function public.dds_remove_alias(p_raw_name text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_norm text;
  v_n    integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  v_norm := public.dds_norm_name(p_raw_name);
  delete from public.driver_aliases where norm_name = v_norm;
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;

-- ── Row Level Security ─────────────────────────────────────────────────────
-- Single tenant, same rule as events/imports (0001) and driver_master (0005):
-- any signed-in user reads. Writes go through the SECURITY DEFINER functions
-- above, so no INSERT/UPDATE/DELETE policies are granted here — the tables are
-- readable but not directly writable, which is what keeps the audit trigger
-- and the seeding guards from being bypassable by a direct PostgREST call.
--
-- driver_alias_log has no write policy at all: only the trigger writes it, and
-- the trigger is SECURITY DEFINER. An append-only history that a client can
-- insert into is not a history.

alter table public.drivers          enable row level security;
alter table public.driver_aliases   enable row level security;
alter table public.driver_alias_log enable row level security;

drop policy if exists drivers_read on public.drivers;
create policy drivers_read on public.drivers
  for select using (auth.uid() is not null);

drop policy if exists driver_aliases_read on public.driver_aliases;
create policy driver_aliases_read on public.driver_aliases
  for select using (auth.uid() is not null);

drop policy if exists driver_alias_log_read on public.driver_alias_log;
create policy driver_alias_log_read on public.driver_alias_log
  for select using (auth.uid() is not null);

revoke all on function public.dds_upsert_drivers(jsonb, boolean) from public, anon;
revoke all on function public.dds_confirm_alias(text, text)      from public, anon;
revoke all on function public.dds_remove_alias(text)             from public, anon;
revoke all on function public.dds_resolve_name(text)             from public, anon;

grant execute on function public.dds_upsert_drivers(jsonb, boolean) to authenticated;
grant execute on function public.dds_confirm_alias(text, text)      to authenticated;
grant execute on function public.dds_remove_alias(text)             to authenticated;
grant execute on function public.dds_resolve_name(text)             to authenticated;
