-- ============================================================================
-- DDS — 0070_reresolve_batched_to_avoid_timeout
-- ----------------------------------------------------------------------------
-- "Re-check unresolved names" silently did nothing on real data, even for
-- rows that dds_resolve_name() can resolve instantly in isolation. Root
-- cause found by reproducing the exact live function body: dds_minestat_
-- reresolve_all() (and dds_reresolve_all(), same shape) ran dds_resolve_
-- name() — up to 6 match tiers, the last a full drivers-table Levenshtein
-- scan — against EVERY open review row in a single request. Measured
-- directly against the live database: the first 50 of 851 open Minestat
-- rows took 5.8s; extrapolated, a full run is ~100s, well past PostgREST's
-- request timeout. The RPC call times out before its UPDATE statements
-- ever commit — no error surfaces to the user, the button just never
-- finishes, and nothing gets saved, no matter how correct the matching
-- logic itself is (confirmed separately: "VILLANUEVA, JONATHAN MACIREN"
-- resolves via the alias tier in ~4ms when checked alone against a
-- driver_aliases row that already exists for it).
--
-- Fix: both RPCs now take p_limit (default 100) and only cross-join
-- dds_resolve_name against that many open rows per call (oldest id first,
-- so repeated calls make steady progress with no row skipped or retried
-- ahead of others). Returns 'remainingOpen' (the true open count after
-- this batch) so the client can loop until there's nothing left, rather
-- than guessing at a fixed number of iterations. The match/update/close
-- logic itself is unchanged — only the batch size changed. The client
-- (index.html's dm-review-*-recheck click handler) now loops in batches of
-- 100 and shows a progress bar (checked / total, as a percentage) while it
-- runs, rather than a single blocking button click.
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
    limit greatest(p_limit, 1)
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

-- Drop the old zero-arg overload so PostgREST doesn't have two ambiguous
-- dds_minestat_reresolve_all signatures to choose between.
drop function if exists public.dds_minestat_reresolve_all();

-- ---- Same fix, same shape, for the DDS side (import_name_review/events) ----
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
    limit greatest(p_limit, 1)
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

drop function if exists public.dds_reresolve_all();
