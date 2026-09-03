-- ============================================================================
-- DDS — 0047_audit_fixes_batch1
-- ----------------------------------------------------------------------------
-- Three independent fixes from the code-correctness audit (Sept 2026), all
-- restoring or completing behavior an earlier migration had already gotten
-- right once. No new tables/columns; each block reissues one function.
--
-- 1. dds_alert_logs() lost its work_mem tuning.
--    0040 set `alter function ... set work_mem = '32MB'` after measuring a
--    346ms temp-file spill. 0044 re-issued the function with the SAME
--    9-arg signature via CREATE OR REPLACE to add the action_by join and
--    extra sort keys — but CREATE OR REPLACE FUNCTION replaces the whole
--    proconfig list, it does not merge with an earlier standalone ALTER
--    FUNCTION, and 0044's own header never re-declared work_mem. The
--    override silently disappeared at the same moment the query got
--    heavier (one more LEFT JOIN, to profiles, for action_by). Restored
--    here at 48MB rather than the original 32MB, since the query is now
--    doing more work per row than it was when 32MB was measured sufficient.
--
-- 2. dds_backfill_emp_no_from_minestat() lost its conflict-audit logging.
--    0032 added a read-only insert into emp_no_attribution_conflicts
--    whenever operator-text resolution and the MineStat join disagreed on
--    an emp_no — a diagnostic trail, never touches events.emp_no itself.
--    0043's rewrite (a genuine, correct fix: only backfill from shifts
--    that resolve to exactly one distinct emp_no, so a two-operator shift
--    is never coin-flipped) was diffed against 0024 in its own header
--    comment, not 0032 — it branched from the wrong base and dropped the
--    conflict-logging block without noticing. emp_no_attribution_conflicts
--    itself was never dropped; it's just been silently unwritten since
--    0043. This reissue keeps 0043's unambiguous_shifts fix intact and
--    restores 0032's logging on top of it.
--
-- 3. dds_log_entity_action() validated 2 of its 3 free-form parameters
--    before insert (p_entity_type, p_logged_by) but not the third
--    (p_action_type), despite entity_action_log.action_type carrying an
--    8-value CHECK constraint. Not a live bug — the CHECK still catches a
--    bad value — but an inconsistent validation posture that fails with a
--    raw Postgres 23514 instead of the same clean, catchable errcode the
--    other two guards use. Added for consistency, not correctness.
--
-- 4. dds_bulk_log_case_action_by_driver() (0039) never received the
--    coalesce-on-null partial-update protection its sibling RPC
--    (dds_bulk_log_case_action, fixed in 0045) got — action_type/
--    action_is_other/action_date/status_value are all still overwritten
--    unconditionally on conflict; only remarks was ever protected here.
--    The Flagged Drivers bulk bar's date field (da-drivers-bulk-date) has
--    no default and isn't marked required, so an empty date can already
--    reach this RPC as null and silently wipe an existing action/status on
--    every matched row today — this was reachable, not just latent.
-- ============================================================================

-- ── 1. Restore + bump work_mem on dds_alert_logs ────────────────────────────
alter function public.dds_alert_logs(date, date, text, text, text, integer, integer, text, text)
  set work_mem = '48MB';

-- ── 2. Restore conflict-audit logging in dds_backfill_emp_no_from_minestat ──
create or replace function public.dds_backfill_emp_no_from_minestat(
  p_limit integer default 2000
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows      integer := 0;
  v_conflicts integer := 0;
  v_remaining integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  -- 0043's fix, unchanged: only backfill from shifts that resolve to exactly
  -- one distinct emp_no. A shift covered by two different operators is left
  -- alone — no time-of-day data exists to say which of them was driving
  -- when a given alert fired, so an unresolved emp_no here surfaces as
  -- "still needs review", not a coin flip.
  with unambiguous_shifts as (
    select asset_id, shift_date, shift, max(emp_no) as emp_no
    from public.minestat_shifts
    where emp_no is not null
    group by asset_id, shift_date, shift
    having count(distinct emp_no) = 1
  ),
  candidates as (
    select e.id, u.emp_no
    from public.events e
    join unambiguous_shifts u
      on u.asset_id   = e.asset_id
     and u.shift_date = e.shift_date
     and u.shift      = e.shift
    where e.emp_no is null
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

  -- 0032's fix, restored: conflict detection. Rows where OPERATOR-text
  -- resolution already set a DIFFERENT emp_no than MineStat's shift record
  -- would say. Never touches events.emp_no — read-only observation,
  -- recorded once per (event_id, minestat_emp_no) pair via the unique
  -- index on emp_no_attribution_conflicts, so repeat calls stay idempotent.
  -- Scoped by NOT EXISTS against already-recorded conflicts rather than a
  -- bare full-table join, since this runs after every DDS/MineStat upload —
  -- cost should grow with what's new, not with total history.
  insert into public.emp_no_attribution_conflicts (
    event_id, asset_id, shift_date, shift, operator_emp_no, minestat_emp_no
  )
  select e.id, e.asset_id, e.shift_date, e.shift, e.emp_no, u.emp_no
  from public.events e
  join unambiguous_shifts u
    on u.asset_id   = e.asset_id
   and u.shift_date = e.shift_date
   and u.shift      = e.shift
  where e.emp_no is not null
    and u.emp_no <> e.emp_no
    and not exists (
      select 1 from public.emp_no_attribution_conflicts c
       where c.event_id = e.id and c.minestat_emp_no = u.emp_no
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
      select 1 from public.minestat_shifts m
       where m.asset_id = e.asset_id and m.shift_date = e.shift_date
         and m.shift = e.shift and m.emp_no is not null
    );

  return jsonb_build_object(
    'rowsUpdated', v_rows,
    'rowsRemaining', v_remaining,
    'conflictsDetected', v_conflicts
  );
end;
$$;

revoke all on function public.dds_backfill_emp_no_from_minestat(integer) from public, anon;
grant execute on function public.dds_backfill_emp_no_from_minestat(integer) to authenticated;

-- ── 3. Validate p_action_type in dds_log_entity_action, for consistency ─────
create or replace function public.dds_log_entity_action(
  p_entity_type       text,
  p_entity_id         text,
  p_action_type       text,
  p_action_other_text text,
  p_note              text,
  p_logged_by         text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  if p_entity_type not in ('driver', 'asset') then
    raise exception 'INVALID_ENTITY_TYPE' using errcode = '22023';
  end if;

  if p_action_type not in (
    'Counseled', 'Suspended', 'Reassigned', 'Cleared',
    'Spare 3 Days', 'Monitor', 'Continue', 'Other'
  ) then
    raise exception 'INVALID_ACTION_TYPE' using errcode = '22023';
  end if;

  if coalesce(trim(p_logged_by), '') = '' then
    raise exception 'LOGGED_BY_REQUIRED' using errcode = '22023';
  end if;

  insert into public.entity_action_log (
    entity_type, entity_id, action_type, action_other_text, note,
    logged_by, actor_user_id
  ) values (
    p_entity_type, p_entity_id, p_action_type, p_action_other_text, p_note,
    trim(p_logged_by), auth.uid()
  )
  returning id into v_id;

  insert into public.entity_status (entity_type, entity_id, status, updated_by)
  values (p_entity_type, p_entity_id, 'actioned', auth.uid())
  on conflict (entity_type, entity_id)
  do update set status = 'actioned', updated_at = now(), updated_by = excluded.updated_by;

  return v_id;
end;
$$;

revoke all on function public.dds_log_entity_action from public, anon;
grant execute on function public.dds_log_entity_action to authenticated;

-- ── 4. Coalesce-on-null protection for dds_bulk_log_case_action_by_driver ───
create or replace function public.dds_bulk_log_case_action_by_driver(
  p_emp_nos text[],
  p_include_unspecified boolean,
  p_from date,
  p_to date,
  p_shift text,
  p_action_type text,
  p_action_is_other boolean,
  p_action_date date,
  p_status_value text,
  p_remarks text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_updated int;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  if (p_emp_nos is null or array_length(p_emp_nos, 1) is null) and not coalesce(p_include_unspecified, false) then
    raise exception 'NO_DRIVERS' using errcode = '22023';
  end if;

  with target_events as (
    select e.id
    from public.events e
    where (
        (p_emp_nos is not null and e.emp_no = any(p_emp_nos))
        or (coalesce(p_include_unspecified, false) and e.emp_no is null)
      )
      and (p_from is null or e.shift_date >= p_from)
      and (p_to   is null or e.shift_date <= p_to)
      and (p_shift is null or p_shift = '' or e.shift = p_shift)
  )
  insert into public.alert_cases (event_id, action_type, action_is_other, action_date, status_value, remarks, updated_by)
  select te.id, p_action_type, coalesce(p_action_is_other, false), p_action_date, p_status_value, p_remarks, v_uid
  from target_events te
  on conflict (event_id) do update set
    action_type     = coalesce(excluded.action_type, public.alert_cases.action_type),
    action_is_other = coalesce(excluded.action_is_other, public.alert_cases.action_is_other),
    action_date     = coalesce(excluded.action_date, public.alert_cases.action_date),
    status_value    = coalesce(excluded.status_value, public.alert_cases.status_value),
    remarks         = coalesce(excluded.remarks, public.alert_cases.remarks),
    updated_by      = excluded.updated_by,
    updated_at      = now();

  get diagnostics v_updated = row_count;
  return jsonb_build_object('updated', v_updated);
end;
$function$;

revoke all on function public.dds_bulk_log_case_action_by_driver(text[], boolean, date, date, text, text, boolean, date, text, text) from public, anon;
grant execute on function public.dds_bulk_log_case_action_by_driver(text[], boolean, date, date, text, text, boolean, date, text, text) to authenticated;
