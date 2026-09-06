-- ============================================================================
-- DDS — 0075_reresolve_clamp_p_limit
-- ----------------------------------------------------------------------------
-- Phase 3c: clamp p_limit server-side on both bulk re-check RPCs so a
-- client bug or a manual RPC call can't request an unbounded batch,
-- mirroring the same least/greatest clamp pattern already used elsewhere
-- in this schema for other paginated RPCs. No behavior change for the
-- client, which already caps its own dynamic batch size in [10, 200].
-- ============================================================================

create or replace function public.dds_minestat_reresolve_all(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resolved    integer := 0;
  v_checked     integer := 0;
  v_still_open  integer := 0;
  v_remaining   integer := 0;
  v_limit       integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  create temporary table _reresolved on commit drop as
  select rv.id as review_id, rv.norm_name, rv.raw_name, r.emp_no, r.tier,
         r.distance, r.candidates
  from (
    select id, norm_name, raw_name
    from public.minestat_name_review
    where state = 'open'
    order by id
    limit v_limit
  ) rv
  cross join lateral public.dds_resolve_name(rv.raw_name) r;

  select count(*) into v_checked from _reresolved;

  with newly_resolved as (
    select * from _reresolved where emp_no is not null
  ),
  shifts_updated as (
    update public.minestat_shifts ms
       set emp_no = nr.emp_no, tier = nr.tier, distance = nr.distance,
           candidates = coalesce(nr.candidates, '[]'::jsonb), updated_at = now()
      from newly_resolved nr
     where ms.emp_no is null
       and public.dds_norm_name(
             coalesce(ms.last_name, '') || ', ' ||
             trim(coalesce(ms.first_name, '') || ' ' || coalesce(ms.middle_name, ''))
           ) = nr.norm_name
    returning 1
  ),
  review_closed as (
    update public.minestat_name_review rv
       set state = 'resolved', resolved_by = auth.uid(), resolved_at = now()
      from newly_resolved nr
     where rv.id = nr.review_id
       and rv.state = 'open'
    returning 1
  )
  select count(*) into v_resolved from review_closed;

  update public.minestat_name_review rv
     set tier = r.tier, distance = r.distance,
         candidates = coalesce(r.candidates, '[]'::jsonb)
    from _reresolved r
   where rv.id = r.review_id
     and r.emp_no is null
     and rv.state = 'open';
  get diagnostics v_still_open = row_count;

  select count(*) into v_remaining from public.minestat_name_review where state = 'open';

  perform public.dds_minestat_refresh_unresolved_counts();

  return jsonb_build_object(
    'checked',       v_checked,
    'resolved',      v_resolved,
    'stillOpen',     v_still_open,
    'remainingOpen', v_remaining
  );
end;
$$;

revoke all on function public.dds_minestat_reresolve_all(integer) from public, anon;
grant execute on function public.dds_minestat_reresolve_all(integer) to authenticated;

create or replace function public.dds_reresolve_all(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resolved    integer := 0;
  v_checked     integer := 0;
  v_still_open  integer := 0;
  v_remaining   integer := 0;
  v_limit       integer := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  create temporary table _reresolved on commit drop as
  select rv.id as review_id, rv.norm_name, rv.raw_name, r.emp_no, r.tier,
         r.distance, r.candidates
  from (
    select id, norm_name, raw_name
    from public.import_name_review
    where state = 'open'
    order by id
    limit v_limit
  ) rv
  cross join lateral public.dds_resolve_name(rv.raw_name) r;

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

  select count(*) into v_remaining from public.import_name_review where state = 'open';

  perform public.dds_refresh_unresolved_counts();

  return jsonb_build_object(
    'checked',       v_checked,
    'resolved',      v_resolved,
    'stillOpen',     v_still_open,
    'remainingOpen', v_remaining
  );
end;
$$;

revoke all on function public.dds_reresolve_all(integer) from public, anon;
grant execute on function public.dds_reresolve_all(integer) to authenticated;
