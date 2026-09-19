-- ============================================================================
-- DDS — 0148_backfill_pagination_truncated_resolutions
-- ----------------------------------------------------------------------------
-- One-time data repair for the historical backlog left by the client-side
-- name-resolver pagination bug (root-caused live, fixed prospectively in the
-- app by rewriting DDS.loadResolverContext() to page through `drivers` and
-- `driver_aliases` with .range() instead of a bare .select()). That bare
-- .select() was silently capped at PostgREST's implicit ~1000-row page: with
-- drivers at 4,117 rows and driver_aliases at 4,134, roughly 3/4 of each
-- table was invisible to every client-side name resolution on every upload,
-- for however long the tables have been above that size.
--
-- Concrete confirmed example: asset DT-674, driver "MONTAÑO, JOEMAR ALCANO"
-- (alias -> emp_no 9778047) resolved correctly through 2026-08-25, then
-- started coming back emp_no=null/tier='none' on every later upload
-- (09-01, 09-08, 09-15) — same name, same alias row, unchanged — because the
-- alias had shifted past the truncated page boundary. dds_resolve_name(),
-- which queries `drivers`/`driver_aliases` directly and was never subject to
-- this bug, still resolves it correctly today. A live audit found 2,287 of
-- 2,336 currently-unresolved (non "no operator") minestat_shifts rows —
-- 295 distinct driver names, 98% — resolve correctly right now the same way.
--
-- This migration re-resolves every such row directly through
-- dds_resolve_name() — the same always-correct lookup
-- dds_minestat_reresolve_all() already uses for its per-review-row backfill —
-- applied here in one bulk pass across minestat_shifts itself rather than
-- only rows still carrying an open minestat_name_review entry, since some
-- truncated-era rows may already have superseded/closed review rows from
-- later re-imports of the same name.
--
-- The existing trg_minestat_shift_op_status_upd trigger (statement-level,
-- transition-table based) does the rest automatically, in the same
-- transaction, as an ordinary side effect of the UPDATE below: it recomputes
-- minestat_shift_operator_status for every touched (asset_id, shift_date,
-- shift) key and pushes emp_no through to events.emp_no wherever the shift
-- is unambiguous. No separate backfill call is needed.
-- ============================================================================
do $$
declare
  v_shifts_updated integer;
  v_review_closed  integer;
begin
  create temporary table _pagbug_resolved on commit drop as
  with candidates as (
    select distinct
      coalesce(last_name, '') || ', ' ||
        trim(coalesce(first_name, '') || ' ' || coalesce(middle_name, '')) as raw_name
    from public.minestat_shifts
    where emp_no is null and tier is distinct from 'no_operator'
  )
  select c.raw_name, r.emp_no, r.tier, r.distance, r.candidates
  from candidates c
  cross join lateral public.dds_resolve_name(c.raw_name) r
  where r.emp_no is not null;

  update public.minestat_shifts ms
     set emp_no = rr.emp_no,
         tier = rr.tier,
         distance = rr.distance,
         candidates = coalesce(rr.candidates, '[]'::jsonb),
         updated_at = now()
    from _pagbug_resolved rr
   where ms.emp_no is null
     and ms.tier is distinct from 'no_operator'
     and (coalesce(ms.last_name, '') || ', ' ||
          trim(coalesce(ms.first_name, '') || ' ' || coalesce(ms.middle_name, ''))) = rr.raw_name;
  get diagnostics v_shifts_updated = row_count;

  update public.minestat_name_review rv
     set state = 'resolved',
         resolved_at = now()
    from _pagbug_resolved rr
   where rv.state = 'open'
     and rv.norm_name = public.dds_norm_name(rr.raw_name);
  get diagnostics v_review_closed = row_count;

  raise notice 'pagination backfill: % minestat_shifts rows resolved, % review rows closed', v_shifts_updated, v_review_closed;
end $$;

select public.dds_minestat_refresh_unresolved_counts();
