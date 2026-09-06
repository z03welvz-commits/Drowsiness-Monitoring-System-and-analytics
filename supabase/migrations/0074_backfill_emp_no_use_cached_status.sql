-- ============================================================================
-- DDS — 0074_backfill_emp_no_use_cached_status
-- ----------------------------------------------------------------------------
-- Phase 2a completion: dds_backfill_emp_no_from_minestat() now joins against
-- minestat_shift_operator_status (0073) instead of recomputing the
-- unambiguous-shift GROUP BY inline. Same output shape, same semantics
-- (unambiguous shifts only; conflict detection unchanged) — pure
-- performance rewrite. Measured live: the read side dropped from ~4.2s to
-- ~50ms, well under the 8s authenticated statement_timeout even at
-- p_limit's default of 2000.
-- ============================================================================

create or replace function public.dds_backfill_emp_no_from_minestat(p_limit integer default 2000)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rows      integer := 0;
  v_conflicts integer := 0;
  v_remaining integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with candidates as (
    select e.id, s.emp_no
    from public.events e
    join public.minestat_shift_operator_status s
      on s.asset_id   = e.asset_id
     and s.shift_date = e.shift_date
     and s.shift      = e.shift
    where e.emp_no is null
      and not s.is_ambiguous
      and s.emp_no is not null
    limit p_limit
  ),
  upd as (
    update public.events e
       set emp_no = c.emp_no
      from candidates c
     where e.id = c.id
    returning 1
  )
  select count(*) into v_rows from upd;

  insert into public.emp_no_attribution_conflicts (
    event_id, asset_id, shift_date, shift, operator_emp_no, minestat_emp_no
  )
  select e.id, e.asset_id, e.shift_date, e.shift, e.emp_no, s.emp_no
  from public.events e
  join public.minestat_shift_operator_status s
    on s.asset_id   = e.asset_id
   and s.shift_date = e.shift_date
   and s.shift      = e.shift
  where e.emp_no is not null
    and not s.is_ambiguous
    and s.emp_no is not null
    and s.emp_no <> e.emp_no
    and not exists (
      select 1 from public.emp_no_attribution_conflicts c
       where c.event_id = e.id and c.minestat_emp_no = s.emp_no
    )
  limit p_limit
  on conflict (event_id) do update
    set asset_id        = excluded.asset_id,
        shift_date      = excluded.shift_date,
        shift           = excluded.shift,
        operator_emp_no = excluded.operator_emp_no,
        minestat_emp_no = excluded.minestat_emp_no,
        detected_at     = now();
  get diagnostics v_conflicts = row_count;

  select count(*) into v_remaining
  from public.events e
  where e.emp_no is null
    and exists (
      select 1 from public.minestat_shift_operator_status s
       where s.asset_id = e.asset_id and s.shift_date = e.shift_date
         and s.shift = e.shift and not s.is_ambiguous and s.emp_no is not null
    );

  return jsonb_build_object(
    'rowsUpdated', v_rows,
    'rowsRemaining', v_remaining,
    'conflictsDetected', v_conflicts
  );
end;
$function$;
