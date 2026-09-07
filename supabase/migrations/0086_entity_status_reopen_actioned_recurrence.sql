-- ============================================================================
-- DDS — 0086_entity_status_reopen_actioned_recurrence
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- Inferred intent: dds_entity_status_reopen() (the AFTER INSERT trigger on
-- events, trg_entity_status_reopen) is extended so a re-triggered streak
-- reopens entity_status from 'actioned' as well as 'monitoring' — previously
-- it likely only reopened out of 'monitoring'. When a driver/asset that was
-- marked actioned or monitoring starts a fresh qualifying streak (>= 3 days,
-- via dds_current_streak), its status flips back to 'required' and
-- recurrence_count increments, so recurrence tracking captures repeat
-- offenders even after they were actioned rather than just monitored.
-- ============================================================================

create or replace function public.dds_entity_status_reopen()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
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
$function$;
