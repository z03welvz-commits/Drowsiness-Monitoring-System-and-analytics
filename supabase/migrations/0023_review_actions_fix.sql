-- ============================================================================
-- DDS — 0023_review_actions_fix
-- ----------------------------------------------------------------------------
-- Fixes a real, pre-existing bug in 0019_events_emp_no.sql discovered while
-- building the MineStat migration that follows this one (0024): the ORIGINAL
-- dds_refresh_unresolved_counts() used a malformed dollar-quoted body —
-- `as $` ... `$;` (single `$`) instead of `as $$` ... `$$;` — which is a plain
-- SQL syntax error. Confirmed by actually applying 0001-0022 in order against
-- a scratch Postgres instance: `create or replace function
-- public.dds_refresh_unresolved_counts()` fails outright, and since a
-- migration file is executed statement-by-statement (not as one wrapping
-- transaction), every statement AFTER that point in 0019 never ran either:
--
--   dds_refresh_unresolved_counts()  — never created (the broken statement)
--   dds_resolve_review()             — never created
--   dds_ignore_review()              — never created
--   dds_reopen_review()              — never created
--   import_name_review RLS + policy  — never enabled/created
--   grants for the three functions   — never issued
--
-- Practical effect on a database that has run 0019 as originally written:
-- the Name Review UI can *read* the queue (import_name_review exists, created
-- before the broken line) but every write action — confirm, ignore, undo —
-- fails outright, because the RPCs those buttons call do not exist. This is
-- independent of MineStat; it affects DDS operator-name resolution alone and
-- would already be broken today for anyone who opened that queue and tried
-- to act on an item.
--
-- THIS FILE re-issues exactly what 0019 intended, verbatim except for the
-- corrected dollar-quoting, so it is safe to run whether or not a given
-- database already has some of these objects (every statement here is
-- `create or replace` / `drop ... if exists` + `create` / idempotent
-- `alter table ... enable row level security` / plain grants). If 0019 is
-- ever re-applied to a fresh database with its own bug now fixed there too,
-- this file becomes a no-op re-assertion of the same end state — never a
-- conflict.
-- ============================================================================

create or replace function public.dds_refresh_unresolved_counts()
returns void
language sql
security definer
set search_path = public
as $$
  update public.imports i
     set unresolved_count = coalesce((
       select sum(r.row_count) from public.import_name_review r
        where r.import_id = i.id and r.state = 'open'
     ), 0);
$$;

create or replace function public.dds_resolve_review(
  p_review_id bigint,
  p_emp_no    text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_norm text;
  v_raw  text;
  v_rows integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select norm_name, raw_name into v_norm, v_raw
  from public.import_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  perform public.dds_confirm_alias(coalesce(v_raw, v_norm), p_emp_no);

  update public.events
     set emp_no = p_emp_no
   where emp_no is null
     and operator is not null
     and public.dds_norm_name(operator) = v_norm;
  get diagnostics v_rows = row_count;

  update public.import_name_review
     set state = 'resolved', resolved_by = auth.uid(), resolved_at = now()
   where norm_name = v_norm and state = 'open';

  perform public.dds_refresh_unresolved_counts();

  return jsonb_build_object('normName', v_norm, 'empNo', p_emp_no, 'rowsUpdated', v_rows);
end;
$$;

create or replace function public.dds_ignore_review(p_review_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_norm text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select norm_name into v_norm from public.import_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  update public.import_name_review
     set state = 'ignored', resolved_by = auth.uid(), resolved_at = now()
   where norm_name = v_norm and state = 'open';

  perform public.dds_refresh_unresolved_counts();
  return true;
end;
$$;

create or replace function public.dds_reopen_review(
  p_review_id     bigint,
  p_clear_alias   boolean default true
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_norm text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select norm_name into v_norm from public.import_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  if p_clear_alias then
    delete from public.driver_aliases where norm_name = v_norm;
    update public.events set emp_no = null
     where operator is not null and public.dds_norm_name(operator) = v_norm;
  end if;

  update public.import_name_review
     set state = 'open', resolved_by = null, resolved_at = null
   where norm_name = v_norm and state <> 'open';

  perform public.dds_refresh_unresolved_counts();
  return true;
end;
$$;

alter table public.import_name_review enable row level security;

drop policy if exists import_name_review_read on public.import_name_review;
create policy import_name_review_read on public.import_name_review
  for select using (auth.uid() is not null);

revoke all on function public.dds_resolve_review(bigint, text)      from public, anon;
revoke all on function public.dds_ignore_review(bigint)             from public, anon;
revoke all on function public.dds_reopen_review(bigint, boolean)    from public, anon;
revoke all on function public.dds_refresh_unresolved_counts()       from public, anon;

grant execute on function public.dds_resolve_review(bigint, text)   to authenticated;
grant execute on function public.dds_ignore_review(bigint)          to authenticated;
grant execute on function public.dds_reopen_review(bigint, boolean) to authenticated;
-- dds_refresh_unresolved_counts() deliberately has no grant to `authenticated`
-- here, matching 0019's original (correct) intent: it is only ever invoked
-- internally via `perform` from the three functions above, which already run
-- with their own SECURITY DEFINER privilege — a direct grant would only add
-- an unused, ungoverned entry point.
