-- ============================================================================
-- DDS — 0125_import_name_review_trigram_fallback
-- ----------------------------------------------------------------------------
-- dds_resolve_name()'s tier 5 (0018/0072) shortlists candidates by bounded
-- Levenshtein distance, but only among drivers whose surname starts with the
-- EXACT SAME LETTER as the raw name's surname — a deliberate precision guard
-- ("a first-letter typo is rare, and allowing it multiplies false
-- candidates," per 0018's own comment). That guard is correct for what it
-- protects: it is why dds_ingest()'s auto-resolutions stay trustworthy.
--
-- Its cost: a name that fails on that ONE letter (a transposed surname/given
-- name, a typo in the first character, a nickname) can never be found by
-- tier 5, no matter how many times dds_reresolve_all() re-runs the identical
-- cascade against an unchanged masterlist. Those rows are permanently stuck
-- in import_name_review, not merely temporarily unresolved.
--
-- This adds a SECOND, independent matching layer for exactly that stuck
-- backlog: trigram similarity (pg_trgm, already installed by 0005) against
-- the full active roster, with no first-letter anchor. 0018's own
-- idx_drivers_name_trgm turned out to be a dead end for this: it indexes
-- the EXPRESSION dds_norm_name(full_name), but 0071 later replaced every
-- resolver query with the generated, stored `norm_name` column instead —
-- an expression index only matches a query using that exact function-call
-- text, not a column that happens to hold the same value, so it can never
-- be used by a query written against d.norm_name. This migration adds the
-- index this layer actually needs, directly on that column. Per direct
-- instruction this layer NEVER auto-assigns emp_no — a similarity match is
-- a weaker, broader signal than tier 5's guarded edit distance, and a
-- wrong auto-match here would
-- misattribute a real driver's alerts to someone else. It only appends
-- ranked suggestions (tier 'trigram') to the same `candidates` column the
-- review UI already renders, for a human to confirm via the existing
-- dds_resolve_review() — the exact same "confirm becomes a learned alias"
-- path tier 5's own candidates use today.
--
-- SCOPE — "names with problems and no operator", i.e. exactly the rows this
-- schema already defines that way: import_name_review.state = 'open' (an
-- open row's events are by construction still emp_no is null — that is what
-- closes it) AND tier in ('none', 'fuzzy_review') — the two tiers where tier
-- 5 genuinely found nothing usable. 'ambiguous_exact' rows are excluded
-- deliberately: those already have 2+ EXACT name matches (similarity 1.0
-- for all of them), so a trigram pass adds no new information, only noise.
-- ============================================================================

create index if not exists idx_drivers_norm_name_trgm
  on public.drivers using gin (norm_name gin_trgm_ops);

create or replace function public.dds_review_trigram_fallback(
  p_limit integer default 100
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_limit               integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_checked             integer := 0;
  v_names_with_new      integer := 0;
  v_candidates_added    integer := 0;
  c_min_similarity      constant real := 0.35;
  c_max_candidates      constant integer := 5;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  drop table if exists _trgm_todo;
  create temporary table _trgm_todo on commit drop as
  select id, norm_name, candidates as existing_candidates
  from public.import_name_review
  where state = 'open'
    and tier in ('none', 'fuzzy_review')
  order by row_count desc, id
  limit v_limit;

  select count(*) into v_checked from _trgm_todo;

  drop table if exists _trgm_new;
  create temporary table _trgm_new on commit drop as
  select t.id as review_id, t.existing_candidates,
    coalesce((
      select jsonb_agg(jsonb_build_object(
               'emp_no', s.emp_no, 'name', s.full_name,
               'tier', 'trigram', 'similarity', s.sim
             ) order by s.sim desc, s.emp_no)
      from (
        select d.emp_no, d.full_name,
               round(similarity(d.norm_name, t.norm_name)::numeric, 3) as sim
        from public.drivers d
        where d.status = 'active'
          and d.norm_name % t.norm_name
          and similarity(d.norm_name, t.norm_name) >= c_min_similarity
          -- Skip anything tier 5 already shortlisted for this name — this
          -- layer's whole point is surfacing candidates tier 5 could not
          -- see, not re-ranking ones it already offered.
          and not exists (
            select 1 from jsonb_array_elements(t.existing_candidates) ec
            where ec ->> 'emp_no' = d.emp_no
          )
        order by similarity(d.norm_name, t.norm_name) desc
        limit c_max_candidates
      ) s
    ), '[]'::jsonb) as new_candidates
  from _trgm_todo t;

  update public.import_name_review r
     set candidates = r.candidates || n.new_candidates
    from _trgm_new n
   where r.id = n.review_id
     and jsonb_array_length(n.new_candidates) > 0;
  get diagnostics v_names_with_new = row_count;

  select coalesce(sum(jsonb_array_length(new_candidates)), 0) into v_candidates_added
  from _trgm_new;

  return jsonb_build_object(
    'checked',           v_checked,
    'namesWithNewCandidates', v_names_with_new,
    'candidatesAdded',   v_candidates_added
  );
end;
$function$;

revoke all on function public.dds_review_trigram_fallback(integer) from public, anon;
grant execute on function public.dds_review_trigram_fallback(integer) to authenticated;
