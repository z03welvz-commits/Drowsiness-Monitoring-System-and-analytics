-- DDS — 0027_minestat_reresolve
--
-- Recorded from the live database (already applied and tracked in
-- supabase_migrations.schema_migrations as version 20260829023136, name
-- "minestat_reresolve") — this file did not previously exist on disk.
-- Added 2026-08-29 while reconciling supabase/migrations/ against the live
-- project so the two stay in sync going forward; the SQL below is
-- byte-for-byte what's already running, not a new change.
--
-- dds_minestat_reresolve_all() re-runs dds_resolve_name() (0018) against
-- every currently-open minestat_name_review row. This exists because
-- fixes to the masterlist (e.g. correcting a driver's name, adding an
-- alias) only affect FUTURE MineStat imports' name resolution — rows
-- already sitting in the review queue keep whatever tier/distance/
-- candidates dds_minestat_ingest() computed against the masterlist AS IT
-- WAS at import time. Without this, a masterlist fix can silently leave
-- names in review that would now resolve cleanly, with no way to find out
-- short of re-uploading the same MineStat file again.
--
-- For every open review row: re-resolve against the current masterlist.
-- A row that now resolves gets its minestat_shifts.emp_no backfilled (same
-- shift_date+shift+asset_id+name-match join dds_minestat_ingest() itself
-- uses) and its review row closed (state='resolved') under the calling
-- user's identity, same as a manual match via
-- dds_resolve_minestat_name_review(). A row that still doesn't resolve
-- gets its tier/distance/candidates refreshed in place (so the review UI
-- reflects the current best-guess) but stays open. Refreshes the
-- unresolved-count cache (dds_minestat_refresh_unresolved_counts(), 0024)
-- at the end either way.

create or replace function public.dds_minestat_reresolve_all()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resolved  integer := 0;
  v_checked   integer := 0;
  v_still_open integer := 0;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  create temporary table _reresolved on commit drop as
  select rv.id as review_id, rv.norm_name, rv.raw_name, r.emp_no, r.tier,
         r.distance, r.candidates
  from public.minestat_name_review rv
  cross join lateral public.dds_resolve_name(rv.raw_name) r
  where rv.state = 'open';

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

  perform public.dds_minestat_refresh_unresolved_counts();

  return jsonb_build_object(
    'checked',   v_checked,
    'resolved',  v_resolved,
    'stillOpen', v_still_open
  );
end;
$$;

revoke all on function public.dds_minestat_reresolve_all() from public, anon;
grant execute on function public.dds_minestat_reresolve_all() to authenticated;
