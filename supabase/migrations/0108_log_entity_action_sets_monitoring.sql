-- ============================================================================
-- DDS — 0108_log_entity_action_sets_monitoring
-- ----------------------------------------------------------------------------
-- Fixes finding A-4: entity_status.status = 'monitoring' and monitor_until
-- were both real, live-read columns (dds_driver_asset_weekly() already
-- branches on them, the reopen trigger already reopens 'monitoring' rows)
-- that nothing ever wrote — dds_log_entity_action() set every logged action
-- to 'actioned' unconditionally (except 'Cleared', which deletes the row).
--
-- Per explicit instruction, 3 of the 9 real action types are inherently
-- time-bounded follow-ups rather than one-time interventions, and now set
-- 'monitoring' + a monitor_until date instead of 'actioned':
--   - 'Spare 3 Days' -> monitor_until = today + 3 days (duration is in its
--     own name — no reason to guess a different number).
--   - 'Monitor' / 'Continue' -> monitor_until = today + 14 days (a standard
--     follow-up window; neither name implies a specific duration).
-- The other 6 (Counseled, Suspended, Reassigned, Other, Spare, Replace)
-- keep today's exact behavior — status = 'actioned', no monitor_until.
-- 'Cleared' is untouched (still deletes the entity_status row).
--
-- No change needed to dds_driver_asset_weekly()'s 'monitoring'/'resolved'
-- display logic or dds_entity_status_reopen()'s trigger — both already
-- branch on status='monitoring' correctly; they've just never had a real
-- row to read until now.
-- ============================================================================

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
set search_path = public
as $$
declare
  v_id uuid;
  v_status text;
  v_monitor_until date;
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
    if p_action_type = 'Spare 3 Days' then
      v_status := 'monitoring';
      v_monitor_until := current_date + 3;
    elsif p_action_type in ('Monitor', 'Continue') then
      v_status := 'monitoring';
      v_monitor_until := current_date + 14;
    else
      v_status := 'actioned';
      v_monitor_until := null;
    end if;

    insert into public.entity_status (entity_type, entity_id, status, monitor_until, updated_by)
    values (p_entity_type, p_entity_id, v_status, v_monitor_until, auth.uid())
    on conflict (entity_type, entity_id)
    do update set status = excluded.status,
                  monitor_until = excluded.monitor_until,
                  updated_at = now(),
                  updated_by = excluded.updated_by;
  end if;

  return v_id;
end;
$$;
