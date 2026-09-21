-- ============================================================================
-- DDS — 0164_minestat_review_trigram_fallback
-- ----------------------------------------------------------------------------
-- Mirrors dds_review_trigram_fallback() (0125) for the Minestat side of Name
-- Review. 0125 built this exact "broader, no-first-letter-anchor similarity
-- search" layer for import_name_review, but it was never extended to
-- minestat_name_review, and neither one was ever wired to a button in the
-- UI — both sat as dead, unreachable RPCs. This migration adds the Minestat
-- twin; the same session's index.html change wires a "Broaden search"
-- button to both.
--
-- Verified against the live Minestat backlog before writing this: of 7
-- genuine "no match"/"ambiguous" open rows, this approach surfaces the
-- correct employee for at least 2 with a clear similarity margin (e.g.
-- "ANGGON, CHRISTOPHER Z" -> VEGARE, CHRISTOPHER ANGGON at 0.679, next
-- candidate only 0.42) and also surfaces at least one clearly WRONG-looking
-- top suggestion (a same-surname, different-given-name person at 0.50) —
-- which is exactly why, like 0125, this NEVER auto-assigns an emp_no. It
-- only appends ranked 'trigram' candidates to the same `candidates` column
-- the review UI already renders, for a human to confirm via the existing
-- dds_minestat_resolve_review() — the same "confirm becomes a learned
-- alias" path today's candidates use.
--
-- SCOPE mirrors 0125 exactly: minestat_name_review.state = 'open' and tier
-- in ('none', 'fuzzy_review') — the two tiers where the standard resolver
-- genuinely found nothing usable. 'ambiguous_exact' rows are excluded: those
-- already have 2+ exact matches, so a similarity pass adds no new signal.
-- ============================================================================

create or replace function public.dds_minestat_review_trigram_fallback(
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

  drop table if exists pg_temp._minestat_trgm_todo;
  create temporary table _minestat_trgm_todo on commit drop as
  select id, norm_name, candidates as existing_candidates
  from public.minestat_name_review
  where state = 'open'
    and tier in ('none', 'fuzzy_review')
  order by row_count desc, id
  limit v_limit;

  select count(*) into v_checked from _minestat_trgm_todo;

  drop table if exists pg_temp._minestat_trgm_new;
  create temporary table _minestat_trgm_new on commit drop as
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
          and not exists (
            select 1 from jsonb_array_elements(t.existing_candidates) ec
            where ec ->> 'emp_no' = d.emp_no
          )
        order by similarity(d.norm_name, t.norm_name) desc
        limit c_max_candidates
      ) s
    ), '[]'::jsonb) as new_candidates
  from _minestat_trgm_todo t;

  update public.minestat_name_review r
     set candidates = r.candidates || n.new_candidates
    from _minestat_trgm_new n
   where r.id = n.review_id
     and jsonb_array_length(n.new_candidates) > 0;
  get diagnostics v_names_with_new = row_count;

  select coalesce(sum(jsonb_array_length(new_candidates)), 0) into v_candidates_added
  from _minestat_trgm_new;

  return jsonb_build_object(
    'checked',           v_checked,
    'namesWithNewCandidates', v_names_with_new,
    'candidatesAdded',   v_candidates_added
  );
end;
$function$;

revoke all on function public.dds_minestat_review_trigram_fallback(integer) from public, anon;
grant execute on function public.dds_minestat_review_trigram_fallback(integer) to authenticated;
