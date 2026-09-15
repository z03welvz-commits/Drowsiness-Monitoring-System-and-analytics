-- ============================================================================
-- DDS — 0137_events_minestat_auto_link_db_trigger
-- ----------------------------------------------------------------------------
-- Request: alert uploads should automatically link MineStat operator data to
-- DDS events, and there should be a second, DB-side layer that automatically
-- fills in the operator match whenever there wasn't one yet.
--
-- Context (confirmed against the live schema before writing this):
-- Layer 1 (app-side) already exists — index.html's ingestDdsFile() and
-- ingestMinestatFile() both call runBackfillEmpNoFromMinestat() right after
-- a successful upload, which loops DB.rpc('dds_backfill_emp_no_from_minestat')
-- to fill events.emp_no from the unambiguous-operator cache
-- (minestat_shift_operator_status, keyed by asset_id+shift_date+shift). That
-- part of the request was already built; this migration doesn't touch it.
--
-- The actual gap is Layer 2: nothing on the DB side ever re-ran this match
-- automatically. So it depended entirely on: (a) the browser tab staying
-- open through that client-side loop, (b) that RPC call not failing (it's
-- wrapped in .catch() and only console.error()s on failure), and (c) upload
-- ORDER — if a DDS alert arrives for a shift MineStat hasn't reported yet,
-- nothing ever comes back to re-check that event once the MineStat data
-- shows up later, unless someone happens to re-open the app and re-upload.
-- This is a second, plausible explanation (alongside the emp_no-null root
-- cause already confirmed for DT-689) for why some events sit with
-- emp_no null indefinitely.
--
-- Fix — two triggers, both reusing the EXISTING match rule (unambiguous
-- operator in minestat_shift_operator_status for the same asset+shift+date;
-- never overwrites a non-null emp_no, so this can't create a new entry in
-- emp_no_attribution_conflicts — that full reconciliation stays exactly as
-- the periodic dds_backfill_emp_no_from_minestat() RPC's job, unchanged):
--
-- 1. trg_events_backfill_emp_no_ins (NEW, statement-level AFTER INSERT on
--    events, mirroring the existing minestat_shifts trigger's batching
--    style): the moment new alert rows land — regardless of whether the
--    browser is still open — checks the operator cache immediately and
--    fills emp_no for any that already have an unambiguous match.
--
-- 2. trg_refresh_minestat_shift_operator_status (EXTENDED, not replaced):
--    this function already runs on every minestat_shifts insert/update/
--    delete and already computes exactly which shift keys were touched
--    (_touched_shift_keys) to refresh the cache. It now also, in the same
--    pass, pushes any newly-unambiguous operator for those keys onto any
--    EXISTING events rows that are still unmatched — covering the
--    "MineStat data arrives after the alert" ordering with no separate
--    trigger or duplicated matching logic.
--
-- Both are SECURITY DEFINER, matching every other trigger function on these
-- tables, and only ever move an event from unmatched to matched — they
-- never overwrite an existing emp_no, so RLS/authorization exposure is
-- identical to the writes that already fire these tables' existing triggers.
-- ============================================================================

create or replace function public.trg_events_backfill_emp_no_from_minestat()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update public.events e
     set emp_no = s.emp_no
    from new_rows nr
    join public.minestat_shift_operator_status s
      on s.asset_id   = nr.asset_id
     and s.shift_date = nr.shift_date
     and s.shift      = nr.shift
   where e.id = nr.id
     and e.emp_no is null
     and nr.emp_no is null
     and not s.is_ambiguous
     and s.emp_no is not null;

  return null;
end;
$function$;

drop trigger if exists trg_events_backfill_emp_no_ins on public.events;
create trigger trg_events_backfill_emp_no_ins
after insert on public.events
referencing new table as new_rows
for each statement
execute function public.trg_events_backfill_emp_no_from_minestat();

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
         coalesce(count(distinct ms.emp_no) filter (where ms.emp_no is not null), 0) <> 1
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

  -- NEW: this MineStat write just made one or more shift keys' operator
  -- newly known (or newly unambiguous) in the cache above. Push that onto
  -- any events rows for those exact keys that are STILL unmatched — this
  -- is what makes "alert uploaded before MineStat caught up" self-heal
  -- automatically instead of waiting for someone to re-open the app.
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
