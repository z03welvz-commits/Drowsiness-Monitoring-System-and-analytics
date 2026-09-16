-- ============================================================================
-- DDS — 0144_fix_minestat_shift_operator_status_zero_known_bug
-- ----------------------------------------------------------------------------
-- Re-verified the events<->minestat_shifts driver-linking pipeline end to
-- end per direct instruction (join key: asset_id+shift_date+shift, DDS side
-- computed via dds_shift_date()/dds_shift() — 05:21:00-17:20:59 = DAY, else
-- NIGHT, with the pre-05:21 tail rolling back to the previous day; MineStat
-- side taken verbatim from its own file columns, no shift-date computation
-- needed there — then masterlist+alias resolution via dds_resolve_name()).
-- The join key, shift boundaries, and masterlist/alias resolution ladder are
-- all already correct and already exactly this design (0001/0018/0024/0072).
-- Live-data audit found one real bug in the caching layer underneath them:
--
-- trg_refresh_minestat_shift_operator_status() (0073, extended by 0137) has
-- classified a shift key's ambiguity as
--   coalesce(count(distinct emp_no) filter (where emp_no is not null), 0) <> 1
-- — true both when 2+ DIFFERENT drivers are recorded that shift (genuinely
-- ambiguous — correct) AND when ZERO are (nobody resolved yet, or a real
-- "no operator" sentinel row — not ambiguous, just unknown). Confirmed live:
-- of 1,600 rows currently flagged is_ambiguous, 961 (60%) have zero resolved
-- drivers, not conflicting ones — a plain mislabel, not a real conflict.
--
-- Separately, 0073's one-time backfill INSERT filtered its source rows with
-- `where emp_no is not null` before grouping, so any (asset_id, shift_date,
-- shift) key whose MineStat rows ALL had a null emp_no at that time got NO
-- row in the cache at all — not even "unambiguous, no driver known". 225
-- such keys (608 events) were confirmed live: 201 are the real "no_operator"
-- sentinel (nothing to attribute, correctly), 24 have a real name that
-- simply hasn't matched the masterlist yet (tier='none') — both classes are
-- invisible to dds_backfill_emp_no_from_minestat()'s cache-based join today.
-- Neither bug has produced a WRONG events.emp_no value (the join still
-- correctly requires a non-null cached emp_no before writing one, so a
-- mislabeled or missing row just means "nothing to attribute yet", the same
-- correct end state) — but both leave the pipeline's own bookkeeping
-- incomplete/inaccurate, exactly what this recheck was meant to catch.
--
-- Fix: correct the boolean (0 known -> not ambiguous, only 2+ -> ambiguous),
-- then do a one-time full recompute of every key currently in
-- minestat_shifts using the corrected formula — this both backfills the 225
-- missing keys and relabels the 961 mislabeled ones in a single idempotent
-- pass. Does not touch events.emp_no directly; only events already covered
-- by dds_backfill_emp_no_from_minestat()'s existing "unambiguous AND
-- emp_no is not null" rule can ever be written, so this cannot newly
-- misattribute anything — it only makes previously-invisible-but-still-
-- unfillable shifts visible and correctly labeled, and lets the 24
-- resolvable-later names get their normal self-heal treatment (0137) the
-- next time the masterlist/alias table changes and dds_minestat_reresolve_
-- all() successfully resolves one of them.
-- ============================================================================

create or replace function public.trg_refresh_minestat_shift_operator_status()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  create temporary table if not exists _touched_shift_keys (
    asset_id text, shift_date date, shift text
  ) on commit drop;
  delete from _touched_shift_keys where true;

  if tg_op = 'INSERT' then
    insert into _touched_shift_keys select distinct asset_id, shift_date, shift from new_rows;
  elsif tg_op = 'UPDATE' then
    insert into _touched_shift_keys
      select distinct asset_id, shift_date, shift from new_rows
      union
      select distinct asset_id, shift_date, shift from old_rows;
  elsif tg_op = 'DELETE' then
    insert into _touched_shift_keys select distinct asset_id, shift_date, shift from old_rows;
  end if;

  insert into public.minestat_shift_operator_status (asset_id, shift_date, shift, emp_no, is_ambiguous)
  select k.asset_id, k.shift_date, k.shift,
         case when count(distinct ms.emp_no) filter (where ms.emp_no is not null) = 1
              then max(ms.emp_no) filter (where ms.emp_no is not null)
              else null end,
         -- Only 2+ DIFFERENT known drivers is a real conflict. Zero known
         -- drivers (no rows resolved yet, or a genuine "no operator" shift)
         -- is "not ambiguous, just not yet known" — the same non-attributable
         -- outcome either way, but a materially different reason.
         coalesce(count(distinct ms.emp_no) filter (where ms.emp_no is not null), 0) > 1
  from (select distinct asset_id, shift_date, shift from _touched_shift_keys) k
  left join public.minestat_shifts ms
    on ms.asset_id = k.asset_id and ms.shift_date = k.shift_date and ms.shift = k.shift
  group by k.asset_id, k.shift_date, k.shift
  on conflict (asset_id, shift_date, shift) do update
    set emp_no = excluded.emp_no, is_ambiguous = excluded.is_ambiguous, updated_at = now();

  delete from public.minestat_shift_operator_status s
  using (select distinct asset_id, shift_date, shift from _touched_shift_keys) k
  where s.asset_id = k.asset_id and s.shift_date = k.shift_date and s.shift = k.shift
    and not exists (
      select 1 from public.minestat_shifts ms
      where ms.asset_id = k.asset_id and ms.shift_date = k.shift_date and ms.shift = k.shift
    );

  -- Unchanged from 0137: push a newly-known/newly-unambiguous operator onto
  -- any still-unmatched events rows for the touched keys.
  update public.events e
     set emp_no = s.emp_no
    from public.minestat_shift_operator_status s
    join (select distinct asset_id, shift_date, shift from _touched_shift_keys) k
      on k.asset_id = s.asset_id and k.shift_date = s.shift_date and k.shift = s.shift
   where e.asset_id = s.asset_id
     and e.shift_date = s.shift_date
     and e.shift = s.shift
     and e.emp_no is null
     and not s.is_ambiguous
     and s.emp_no is not null;

  return null;
end;
$function$;

-- One-time corrective recompute over every key currently in minestat_shifts
-- (not filtered by emp_no is not null, unlike 0073's original backfill) —
-- fixes the 961 mislabeled rows and inserts the 225 previously-missing keys
-- in one pass, using the same corrected formula as the trigger above.
insert into public.minestat_shift_operator_status (asset_id, shift_date, shift, emp_no, is_ambiguous)
select asset_id, shift_date, shift,
       case when count(distinct emp_no) filter (where emp_no is not null) = 1
            then max(emp_no) filter (where emp_no is not null)
            else null end,
       coalesce(count(distinct emp_no) filter (where emp_no is not null), 0) > 1
from public.minestat_shifts
group by asset_id, shift_date, shift
on conflict (asset_id, shift_date, shift) do update
  set emp_no = excluded.emp_no, is_ambiguous = excluded.is_ambiguous, updated_at = now();

-- Drop any cache row left over for a key no longer present in minestat_shifts
-- at all (mirrors the trigger's own per-touch cleanup, run once here for any
-- key that was never touched by an insert/update/delete since 0073).
delete from public.minestat_shift_operator_status s
where not exists (
  select 1 from public.minestat_shifts ms
  where ms.asset_id = s.asset_id and ms.shift_date = s.shift_date and ms.shift = s.shift
);

-- The corrected cache may have just made some previously-invisible shifts'
-- operators known (or newly unambiguous) — push those onto any events rows
-- still sitting unmatched, same rule dds_backfill_emp_no_from_minestat()
-- and the triggers already use (never overwrites a non-null emp_no).
update public.events e
   set emp_no = s.emp_no
  from public.minestat_shift_operator_status s
 where e.asset_id = s.asset_id
   and e.shift_date = s.shift_date
   and e.shift = s.shift
   and e.emp_no is null
   and not s.is_ambiguous
   and s.emp_no is not null;
