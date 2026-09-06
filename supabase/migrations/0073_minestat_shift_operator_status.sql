-- ============================================================================
-- DDS — 0073_minestat_shift_operator_status
-- ----------------------------------------------------------------------------
-- Phase 2a of the name-linking pipeline fix. dds_backfill_emp_no_from_
-- minestat()'s unambiguous_shifts CTE (a GROUP BY over ALL of
-- minestat_shifts, filtering to shift-keys with exactly one distinct
-- emp_no) is recomputed in full on every call. Measured live: 4.2 seconds
-- for this CTE alone against 175,238 rows — and it grows as Minestat data
-- grows. This function is the ONLY path that can ever give a DDS event
-- (which never carries a driver name at all — confirmed by inspecting the
-- real uploaded file's actual header row) an emp_no, so this cost sits
-- directly in the path of every DDS alert ever becoming attributable to a
-- driver.
--
-- Fix: cache each (asset_id, shift_date, shift) key's ambiguity status in a
-- real table, maintained incrementally by STATEMENT-level triggers with
-- transition tables (not per-row triggers — a bulk Minestat upload/upsert
-- writes thousands of rows per statement, so recomputing once per
-- statement over only the distinct keys that statement touched is what
-- keeps upload-time cost proportional to what changed, not to
-- minestat_shifts' total size). Postgres requires one trigger per event
-- type when using transition tables (cannot combine INSERT OR UPDATE OR
-- DELETE on one transition-table trigger), so this defines three triggers
-- sharing one function, each declaring only the transition table relevant
-- to its own event.
-- ============================================================================

create table if not exists public.minestat_shift_operator_status (
  asset_id     text not null,
  shift_date   date not null,
  shift        text not null,
  emp_no       text,
  is_ambiguous boolean not null default false,
  updated_at   timestamptz not null default now(),
  primary key (asset_id, shift_date, shift)
);

create index if not exists idx_minestat_shift_op_status_unambiguous
  on public.minestat_shift_operator_status (asset_id, shift_date, shift)
  where not is_ambiguous;

-- One-time backfill from the current full data — same cost as today's
-- per-call recompute, paid exactly once here instead of on every future call.
insert into public.minestat_shift_operator_status (asset_id, shift_date, shift, emp_no, is_ambiguous)
select asset_id, shift_date, shift,
       case when count(distinct emp_no) = 1 then max(emp_no) else null end,
       count(distinct emp_no) <> 1
from public.minestat_shifts
where emp_no is not null
group by asset_id, shift_date, shift
on conflict (asset_id, shift_date, shift) do update
  set emp_no = excluded.emp_no, is_ambiguous = excluded.is_ambiguous, updated_at = now();

-- Recompute ambiguity only for the distinct shift-keys touched by a given
-- statement, scanning just those keys' rows, not the whole table. Reads
-- whichever of NEW/OLD transition tables the calling trigger declared
-- (only one is ever non-null for a given firing, since each trigger below
-- is scoped to exactly one event type).
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
  delete from _touched_shift_keys;

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

  -- A shift key that no longer has ANY rows (all deleted) should be
  -- removed from the cache entirely rather than left as a stale row that
  -- no longer has any backing data.
  delete from public.minestat_shift_operator_status s
  using (select distinct asset_id, shift_date, shift from _touched_shift_keys) k
  where s.asset_id = k.asset_id and s.shift_date = k.shift_date and s.shift = k.shift
    and not exists (
      select 1 from public.minestat_shifts ms
      where ms.asset_id = k.asset_id and ms.shift_date = k.shift_date and ms.shift = k.shift
    );

  return null;
end;
$function$;

-- Trigger-only function — never meant to be called directly by a client.
-- Supabase/PostgREST auto-exposes every public-schema function as an RPC
-- endpoint by default; the security advisor confirmed this one was
-- reachable via /rest/v1/rpc/trg_refresh_minestat_shift_operator_status
-- for both anon and authenticated until this revoke. Triggers still fire
-- normally after this — Postgres invokes a trigger function directly,
-- independent of a role's own EXECUTE grant (verified live: insert/delete
-- on minestat_shifts still correctly updated the cache table afterward).
revoke all on function public.trg_refresh_minestat_shift_operator_status() from public, anon, authenticated;

drop trigger if exists trg_minestat_shift_op_status_ins on public.minestat_shifts;
create trigger trg_minestat_shift_op_status_ins
  after insert on public.minestat_shifts
  referencing new table as new_rows
  for each statement
  execute function public.trg_refresh_minestat_shift_operator_status();

drop trigger if exists trg_minestat_shift_op_status_upd on public.minestat_shifts;
create trigger trg_minestat_shift_op_status_upd
  after update on public.minestat_shifts
  referencing new table as new_rows old table as old_rows
  for each statement
  execute function public.trg_refresh_minestat_shift_operator_status();

drop trigger if exists trg_minestat_shift_op_status_del on public.minestat_shifts;
create trigger trg_minestat_shift_op_status_del
  after delete on public.minestat_shifts
  referencing old table as old_rows
  for each statement
  execute function public.trg_refresh_minestat_shift_operator_status();

-- Note: this table's RLS read policy is added separately in
-- 0076_minestat_shift_operator_status_rls.sql — it was applied live as a
-- follow-up after the security advisor flagged "RLS Enabled No Policy"
-- for this table, not in the same statement as its creation above.
