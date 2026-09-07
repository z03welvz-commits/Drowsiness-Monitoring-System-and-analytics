-- ============================================================================
-- DDS — 0086_entity_status_reopen_actioned_recurrence
-- ----------------------------------------------------------------------------
-- dds_entity_status_reopen() (the trigger that fires on every new events
-- row) currently live only reopens entity_status rows with status =
-- 'monitoring' — a value nothing in this app ever writes, so in practice
-- this trigger is a permanent no-op. It has no branch for 'actioned' at all,
-- unlike the committed-but-superseded 0048 version (which reopened
-- 'actioned' rows via a different, older pattern check). Neither version is
-- what's wanted: per explicit instruction, "recurrence" should fire when a
-- driver/asset who already has a logged action (status = 'actioned') is
-- STILL in a qualifying streak — i.e. the same >=3-day streak threshold
-- dds_driver_asset_weekly()/dds_driver_streaks() already use everywhere else
-- to decide "required" in the first place, not a separate pattern rule.
--
-- Fix: reopen on either 'monitoring' OR 'actioned' via the same
-- dds_current_streak(entity_type, entity_id) >= 3 check (defaults: >10
-- units/day, 90-day lookback — the shared threshold this app already uses
-- consistently). Recurrence_count still increments either way, since it's
-- the same "this keeps happening after we thought it was handled" signal
-- regardless of which status the row was reopened from. 'monitoring' kept
-- rather than dropped, since removing it would be a separate, unrequested
-- behavior change (nothing currently writes it, so keeping it is zero-risk).
-- ============================================================================

create or replace function public.dds_entity_status_reopen()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_asset_id text;
  v_driver_key text;
  v_streak int;
  v_status text;
begin
  v_asset_id := new.asset_id;
  if v_asset_id is not null then
    select status into v_status from public.entity_status
      where entity_type = 'asset' and entity_id = v_asset_id and status in ('monitoring', 'actioned');
    if v_status is not null then
      v_streak := public.dds_current_streak('asset', v_asset_id);
      if v_streak >= 3 then
        update public.entity_status
          set status = 'required',
              monitor_until = null,
              recurrence_count = recurrence_count + 1,
              updated_at = now(),
              updated_by = null
          where entity_type = 'asset' and entity_id = v_asset_id and status = v_status;
      end if;
    end if;
  end if;

  v_driver_key := coalesce(new.emp_no, 'UNSPECIFIED');
  select status into v_status from public.entity_status
    where entity_type = 'driver' and entity_id = v_driver_key and status in ('monitoring', 'actioned');
  if v_status is not null then
    v_streak := public.dds_current_streak('driver', v_driver_key);
    if v_streak >= 3 then
      update public.entity_status
        set status = 'required',
            monitor_until = null,
            recurrence_count = recurrence_count + 1,
            updated_at = now(),
            updated_by = null
        where entity_type = 'driver' and entity_id = v_driver_key and status = v_status;
    end if;
  end if;

  return new;
end;
$$;
