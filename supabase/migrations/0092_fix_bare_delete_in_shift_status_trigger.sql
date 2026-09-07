-- ============================================================================
-- DDS — 0092_fix_bare_delete_in_shift_status_trigger
-- ----------------------------------------------------------------------------
-- Root cause of "Import failed: DELETE requires a WHERE clause" on MineStat
-- uploads (confirmed live via edge_logs + postgres_logs correlation: the
-- failing call is always rpc/dds_minestat_ingest_resolved, and a schema-wide
-- scan of every function body confirms trg_refresh_minestat_shift_operator_
-- status() is the ONLY function anywhere in this database containing a bare
-- `delete from <table>;` with no WHERE at all):
--
--   create temporary table if not exists _touched_shift_keys (...) on commit drop;
--   delete from _touched_shift_keys;
--
-- That statement clears the trigger's own scratch temp table before
-- repopulating it — a genuinely full-table delete, not a mistake in intent.
-- But it runs inside a SECURITY DEFINER trigger fired by every INSERT/UPDATE/
-- DELETE on minestat_shifts, under the function owner's role rather than a
-- direct superuser session — evidently a role/session context where an
-- unqualified DELETE is rejected outright, unlike a direct admin SQL
-- connection (reproduced live: the exact same bare DELETE against a throwaway
-- temp table succeeds over a direct connection, so this isn't a universal
-- Postgres restriction — it's specific to the trigger's execution context).
--
-- Fix: add `where true` — functionally identical (still deletes every row
-- in the scratch table), but satisfies whatever is checking for an explicit
-- WHERE clause. Nothing else in the function changes.
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
