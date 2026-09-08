-- dds_log_entity_action() unconditionally upserted entity_status.status =
-- 'actioned' for EVERY action type, including 'Cleared' — so picking
-- "Cleared" (or Driver Streaks' "—" reset option, which submits the same
-- type) logged a real, permanent entity_action_log audit row but left the
-- live entity_status pointer stuck on 'actioned' exactly as before. Reported
-- live: "i try to log or delete a log action item in streak, but it still
-- remains on the log action" — confirmed the row's status badge and
-- dropdown never changed after logging Cleared, because nothing ever un-set
-- 'actioned'.
--
-- entity_status is a live pointer, not history (entity_action_log already
-- keeps the permanent record) — dds_driver_streaks() and
-- dds_driver_asset_weekly() both already fall back to a freshly computed
-- baseline ('required'/'ok' from the real current streak) whenever no
-- entity_status row exists for an entity (confirmed by reading both live
-- definitions: `case when es.status = 'monitoring' then ... when es.status
-- = 'actioned' then 'actioned' else <computed from streak> end`). So
-- "Cleared" only needs to remove the entity_status row rather than write
-- some new status value — entity_status_status_check (0085) only allows
-- 'required'/'monitoring'/'actioned' anyway, and dds_entity_status_reopen()
-- (0086) already re-creates/updates it the moment a new qualifying streak
-- resumes, so deleting it loses no real capability.
create or replace function public.dds_log_entity_action(
  p_entity_type text,
  p_entity_id text,
  p_action_type text,
  p_action_other_text text,
  p_note text,
  p_logged_by text
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
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

  if p_action_type = 'Cleared' then
    delete from public.entity_status
    where entity_type = p_entity_type and entity_id = p_entity_id;
  else
    insert into public.entity_status (entity_type, entity_id, status, updated_by)
    values (p_entity_type, p_entity_id, 'actioned', auth.uid())
    on conflict (entity_type, entity_id)
    do update set status = 'actioned', updated_at = now(), updated_by = excluded.updated_by;
  end if;

  return v_id;
end;
$function$;
