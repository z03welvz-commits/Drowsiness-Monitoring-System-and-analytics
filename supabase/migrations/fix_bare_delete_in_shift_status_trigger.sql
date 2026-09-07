-- ============================================================================
-- DDS — fix_bare_delete_in_shift_status_trigger
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- Inferred intent: trg_refresh_minestat_shift_operator_status() (the
-- statement-level trigger on minestat_shifts that maintains
-- minestat_shift_operator_status) had a bare/unqualified
-- `delete from _touched_shift_keys;` with no WHERE clause, which some
-- Postgres linters/policies flag or which risked deleting rows it shouldn't
-- once the temp table pattern was reused across statements in the same
-- transaction. The live body now writes it as
-- `delete from _touched_shift_keys where true;` — an explicit, intentional
-- full-table clear that reads unambiguously as "delete everything" rather
-- than an accidentally-omitted filter.
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

-- Preserve the lockdown from 0077_lock_down_trigger_function.sql: this is an
-- internal statement-level trigger function, not a public RPC.
revoke all on function public.trg_refresh_minestat_shift_operator_status() from public, anon, authenticated;
