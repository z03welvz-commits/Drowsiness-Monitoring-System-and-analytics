-- ============================================================================
-- DDS — 0072_dds_resolve_name_indexed
-- ----------------------------------------------------------------------------
-- Phase 1 continued: rewrite dds_resolve_name() to read the generated,
-- indexed columns added in 0071 instead of recomputing dds_norm_name/
-- dds_strip_suffix/dds_surname_first_key/dds_name_skeleton/dds_surname_of
-- per candidate row on every call. Same signature, same tier order, same
-- thresholds (c_max_dist=3, c_auto_dist=2) as the version this replaces —
-- a pure performance rewrite, no behavior change. T1 (alias table lookup)
-- is unchanged since it was already a plain indexed lookup.
--
-- Measured live: a batch of 100 rows via this rewrite completed in ~185ms
-- (vs. previously timing out entirely at the same batch size).
-- ============================================================================

create or replace function public.dds_resolve_name(p_raw text)
returns table(emp_no text, tier text, distance integer, candidates jsonb)
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  v_norm  text;
  v_bare  text;
  v_sf    text;
  v_skel  text;
  v_hit   text;
  v_n     integer;
  v_cands jsonb;
  c_max_dist  constant integer := 3;
  c_auto_dist constant integer := 2;
  v_best  integer;
  v_ties  integer;
begin
  v_norm := public.dds_norm_name(p_raw);
  if v_norm is null then
    return query select null::text, 'blank'::text, null::integer, '[]'::jsonb;
    return;
  end if;

  select a.emp_no into v_hit from public.driver_aliases a where a.norm_name = v_norm;
  if v_hit is not null then
    return query select v_hit, 'alias'::text, null::integer, '[]'::jsonb;
    return;
  end if;

  select count(*), min(d.emp_no) into v_n, v_hit
  from public.drivers d
  where d.norm_name = v_norm;
  if v_n = 1 then
    return query select v_hit, 'exact'::text, null::integer, '[]'::jsonb;
    return;
  elsif v_n > 1 then
    return query select null::text, 'ambiguous_exact'::text, null::integer,
      (select jsonb_agg(jsonb_build_object('emp_no', d.emp_no, 'name', d.full_name, 'tier', 'exact'))
       from public.drivers d where d.norm_name = v_norm);
    return;
  end if;

  v_bare := public.dds_strip_suffix(v_norm);
  select count(*), min(d.emp_no) into v_n, v_hit
  from public.drivers d
  where d.bare_name = v_bare;
  if v_n = 1 then
    return query select v_hit, 'suffix'::text, null::integer, '[]'::jsonb;
    return;
  end if;

  v_sf := public.dds_surname_first_key(v_norm);
  if v_sf is not null then
    select count(*), min(d.emp_no) into v_n, v_hit
    from public.drivers d
    where d.surname_first_key = v_sf;
    if v_n = 1 then
      return query select v_hit, 'surname_first'::text, null::integer, '[]'::jsonb;
      return;
    end if;
  end if;

  v_skel := public.dds_name_skeleton(v_bare);
  if v_skel is not null and length(v_skel) >= 3 then
    select count(*), min(d.emp_no) into v_n, v_hit
    from public.drivers d
    where d.name_skeleton = v_skel;
    if v_n = 1 then
      return query select v_hit, 'skeleton'::text, null::integer, '[]'::jsonb;
      return;
    end if;
  end if;

  with shortlist as (
    select d.emp_no as cand_emp_no, d.full_name,
           levenshtein_less_equal(v_bare, d.bare_name, c_max_dist) as dist
    from public.drivers d
    where d.status = 'active'
      and d.surname_first_letter = left(public.dds_surname_of(v_norm), 1)
      and abs(d.bare_name_len - length(v_bare)) <= c_max_dist
  )
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

  if v_ties = 1 and v_best <= c_auto_dist then
    return query select (v_cands -> 0 ->> 'emp_no')::text, 'fuzzy'::text, v_best, v_cands;
  else
    return query select null::text, 'fuzzy_review'::text, v_best, v_cands;
  end if;
end;
$function$;
