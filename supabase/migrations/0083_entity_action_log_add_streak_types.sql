-- ============================================================================
-- DDS — 0083_entity_action_log_add_streak_types
-- ----------------------------------------------------------------------------
-- Driver Streaks' "Log an action" dropdown (ACTION_OPTIONS in index.html:
-- 'Spare', 'Replace', 'Continue', 'Other') only ever wrote to alert_cases via
-- dds_bulk_log_case_action_by_driver() — it never called dds_log_entity_
-- action(), so an action logged there never reached entity_status/
-- entity_action_log, the tables Driver & Asset Monitoring's status pill and
-- Driver Streaks' own "last action" column actually read. Wiring that call in
-- (client-side fix, no migration needed for that part) surfaces a real
-- incompatibility: entity_action_log.action_type's CHECK constraint, and
-- dds_log_entity_action()'s own internal validation, only allow the 8-value
-- Counseled/Suspended/Reassigned/Cleared/'Spare 3 Days'/Monitor/Continue/
-- Other vocabulary from 0033 — 'Spare' and 'Replace' aren't in it and would
-- be rejected outright ('Continue'/'Other' already overlap, which is why
-- this wasn't caught immediately).
--
-- Per explicit instruction: extend the vocabulary to include 'Spare' and
-- 'Replace' as their own first-class values, rather than remapping them onto
-- 'Spare 3 Days'/'Reassigned' and losing what was actually selected.
-- ============================================================================

alter table public.entity_action_log
  drop constraint entity_action_log_action_type_check;

alter table public.entity_action_log
  add constraint entity_action_log_action_type_check check (action_type in (
    'Counseled', 'Suspended', 'Reassigned', 'Cleared',
    'Spare 3 Days', 'Monitor', 'Continue', 'Other',
    'Spare', 'Replace'
  ));

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
    'Spare 3 Days', 'Monitor', 'Continue', 'Other',
    'Spare', 'Replace'
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
