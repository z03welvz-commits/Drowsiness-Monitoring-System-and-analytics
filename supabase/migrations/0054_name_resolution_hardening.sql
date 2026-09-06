-- ============================================================================
-- DDS — 0054_name_resolution_hardening
-- ----------------------------------------------------------------------------
-- The name-resolution ladder (0018) and its review queues (0019 DDS, 0024
-- MineStat) have worked correctly since they shipped, but two things left
-- the resolver worse than it should be, and a third left its results
-- invisible:
--
-- 1. dds_norm_name only folds the clean UTF-8 forms of Spanish diacritics
--    (Ñ/ñ, ÁÉÍÓÚ/áéíóú, Üü) plus a literal '?'. A name that arrives with a
--    MOJIBAKE-encoded ñ (e.g. a Windows-1252 file re-saved as UTF-8 renders
--    "ñ" as the two-byte sequence "Ã±", and "Ñ" as "Ã‘") normalizes to a
--    completely different string than the clean spelling of the same name
--    sitting in the masterlist — the two never meet at any tier, including
--    fuzzy, because the byte-level distance between "Ã±" and "n" is larger
--    than the tolerance any reasonable auto-accept threshold should allow.
--
-- 2. dds_strip_suffix only strips a suffix that is the LAST SPACE-SEPARATED
--    TOKEN of the whole string ('...JR', '...III'). Two common real-world
--    shapes it misses entirely:
--      - comma-separated:  "SANTOS, JUAN, JR"   (three comma segments, not two)
--      - suffix-before-comma (misfiled during encoding): "SANTOS JR, JUAN"
--    Both leave a spurious "JR"/"III" token stuck to the surname half of the
--    name for every downstream tier (surname_first, skeleton, fuzzy), which
--    is exactly the kind of one-token difference fuzzy matching is supposed
--    to absorb but a masterlist entry stored WITHOUT the suffix will not
--    coincidentally happen to be within edit-distance 3 of a full 3-word
--    surname string.
--
-- 3. Nothing lets a masterlist correction retroactively re-check the DDS
--    review queue. dds_minestat_reresolve_all() (0027) already does this for
--    MineStat; the DDS side (import_name_review) has had no equivalent,
--    so fixing a name or confirming an alias only ever helped future
--    imports — existing queued rows sat still even when they would now
--    resolve cleanly.
--
-- NONE OF THIS LOOSENS AUTO-ACCEPT. c_max_dist (3) and c_auto_dist (2) in
-- dds_resolve_name are untouched. Every change below is normalization —
-- making two spellings of the SAME name collapse to the same canonical
-- string before distance is ever computed — not a change to how much
-- distance is tolerated. A genuinely ambiguous or low-confidence match still
-- lands in fuzzy_review for a human, same as before.
-- ============================================================================

-- ── dds_norm_name: wider diacritic coverage + stray-byte tolerance ─────────
-- The existing translate() table folded Ñ/ñ, the five acute vowels, and a
-- literal '?' (the mangled-encoding placeholder some spreadsheet exports
-- substitute for a diacritic they can't represent). This widens the same
-- translate() table with grave and circumflex accents, which do appear in a
-- handful of real personnel records and previously fell through untouched
-- (an unmatched character is not an error in translate() — it just survives
-- into the normalized string, silently breaking every tier's comparison for
-- that one name). This is additive only: every character the original set
-- folded still folds exactly the same way, so no previously-normalizing
-- name changes its normalized form.
--
-- Deliberately NOT attempting to repair mojibake (UTF-8 bytes misread as
-- Latin-1, e.g. "ñ" arriving as the two-byte sequence usually rendered
-- "Ã±"). Guessing at byte-level corruption patterns without a confirmed
-- sample from this project's actual DDS/MineStat exports risks introducing
-- a replace() rule that matches nothing (dead code) or, worse, one that
-- matches a legitimate substring in some other name and corrupts it. If a
-- specific mojibake pattern is confirmed in real export files, add a
-- targeted replace() for that exact byte sequence in a follow-up migration
-- with the sample bytes captured in the comment.
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
          E'Ññ?' || E'ÁÉÍÓÚáéíóúÜü' || E'ÀÈÌÒÙàèìòù' || E'ÂÊÎÔÛâêîôû' || E'.-/''' || E' ',
          'NNN'      || 'AEIOUaeiouUu'    || 'AEIOUaeiou'    || 'AEIOUaeiou'    || '    '    || ' '
        ),
        '\s*,\s*', ', ', 'g'
      ),
      '\s+', ' ', 'g'
    )),
  '');
$$;

-- ── dds_strip_suffix: comma-separated and misplaced suffixes ───────────────
-- Order of operations: strip a comma-segment suffix first ("SANTOS, JUAN,
-- JR" -> "SANTOS, JUAN"), THEN strip a suffix that is its own leading token
-- immediately before a comma ("SANTOS JR, JUAN" -> "SANTOS, JUAN"), THEN
-- fall through to the original trailing-token rule ("SANTOS, JUAN JR" ->
-- "SANTOS, JUAN"). All three shapes collapse to the same suffix-free name,
-- which is what lets tiers 3/4/5 compare like against like regardless of
-- which shape a given source file happened to use.
create or replace function public.dds_strip_suffix(s text)
returns text
language sql immutable parallel safe
set search_path = public
as $$
  select nullif(trim(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          coalesce(s, ''),
          ',\s*(JR|SR|II|III|IV)\s*$', '', 'g'          -- "..., JUAN, JR" -> "..., JUAN"
        ),
        '^(.*?)\s+(JR|SR|II|III|IV)\s*,', '\1,', 'g'      -- "SANTOS JR, JUAN" -> "SANTOS, JUAN"
      ),
      '\s+(JR|SR|II|III|IV)$', '', 'g'                    -- "..., JUAN JR" -> "..., JUAN" (0018 original)
    )
  ), '');
$$;

-- ── dds_reresolve_all: DDS-side bulk re-check, mirrors 0027 for MineStat ──
-- Re-runs dds_resolve_name() against every currently-open import_name_review
-- row. A masterlist correction or a newly confirmed alias only ever affected
-- FUTURE dds_ingest() calls before this existed — a name already sitting in
-- the queue kept whatever tier/distance/candidates were computed at import
-- time, with no way to discover it would now resolve cleanly short of
-- re-uploading the same file. Same shape as dds_minestat_reresolve_all():
-- a row that now resolves gets events.emp_no backfilled and the queue row
-- closed under the caller's identity; a row that still doesn't resolve gets
-- its tier/distance/candidates refreshed in place but stays open.
create or replace function public.dds_reresolve_all()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resolved   integer := 0;
  v_checked    integer := 0;
  v_still_open integer := 0;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  create temporary table _reresolved on commit drop as
  select rv.id as review_id, rv.norm_name, rv.raw_name, r.emp_no, r.tier,
         r.distance, r.candidates
  from public.import_name_review rv
  cross join lateral public.dds_resolve_name(rv.raw_name) r
  where rv.state = 'open';

  select count(*) into v_checked from _reresolved;

  with newly_resolved as (
    select * from _reresolved where emp_no is not null
  ),
  events_updated as (
    update public.events e
       set emp_no = nr.emp_no
      from newly_resolved nr
     where e.emp_no is null
       and e.operator is not null
       and public.dds_norm_name(e.operator) = nr.norm_name
    returning 1
  ),
  review_closed as (
    update public.import_name_review rv
       set state = 'resolved', resolved_by = auth.uid(), resolved_at = now()
      from newly_resolved nr
     where rv.id = nr.review_id
       and rv.state = 'open'
    returning 1
  )
  select count(*) into v_resolved from review_closed;

  update public.import_name_review rv
     set tier = r.tier, distance = r.distance,
         candidates = coalesce(r.candidates, '[]'::jsonb)
    from _reresolved r
   where rv.id = r.review_id
     and r.emp_no is null
     and rv.state = 'open';
  get diagnostics v_still_open = row_count;

  perform public.dds_refresh_unresolved_counts();

  return jsonb_build_object(
    'checked',   v_checked,
    'resolved',  v_resolved,
    'stillOpen', v_still_open
  );
end;
$$;

revoke all on function public.dds_reresolve_all() from public, anon;
grant execute on function public.dds_reresolve_all() to authenticated;

-- ── Review queue listing RPCs ───────────────────────────────────────────────
-- Neither import_name_review nor minestat_name_review has ever had a listing
-- RPC — dds_resolve_review/dds_ignore_review/dds_reopen_review (0019) and
-- their MineStat mirrors (0024) all take a review_id the caller must already
-- have, because the UI that would have listed open rows to get that id was
-- never built (PENDING_102 finding A3). These two RPCs are that missing read
-- path: paged, filtered to a state, joined to a fuzzy-match preview so a
-- reviewer sees the candidate name(s) without a second round trip.
create or replace function public.dds_name_review_list(
  p_state  text    default 'open',
  p_limit  integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 50), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with scoped as (
    select * from public.import_name_review
     where p_state is null or p_state = 'all' or state = p_state
  ),
  total as (select count(*) as n from scoped),
  paged as (
    select * from scoped order by row_count desc, created_at asc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'importId', import_id, 'rawName', raw_name, 'normName', norm_name,
        'tier', tier, 'distance', distance, 'candidates', candidates,
        'rowCount', row_count, 'state', state,
        'resolvedAt', resolved_at, 'createdAt', created_at
      ) order by row_count desc, created_at asc)
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

create or replace function public.dds_minestat_name_review_list(
  p_state  text    default 'open',
  p_limit  integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 50), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with scoped as (
    select * from public.minestat_name_review
     where p_state is null or p_state = 'all' or state = p_state
  ),
  total as (select count(*) as n from scoped),
  paged as (
    select * from scoped order by row_count desc, created_at asc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'importId', import_id, 'rawName', raw_name, 'normName', norm_name,
        'tier', tier, 'distance', distance, 'candidates', candidates,
        'rowCount', row_count, 'state', state,
        'resolvedAt', resolved_at, 'createdAt', created_at
      ) order by row_count desc, created_at asc)
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

revoke all on function public.dds_name_review_list(text, integer, integer)          from public, anon;
revoke all on function public.dds_minestat_name_review_list(text, integer, integer) from public, anon;
grant execute on function public.dds_name_review_list(text, integer, integer)          to authenticated;
grant execute on function public.dds_minestat_name_review_list(text, integer, integer) to authenticated;
