-- ============================================================================
-- DDS — 0034_entity_status_reopen_risk_gated
-- ----------------------------------------------------------------------------
-- Phase 6 (Corrective Actions) verification pass found that
-- dds_entity_status_reopen() (0033) reopens an actioned entity on ANY new
-- alert, regardless of severity. The master prompt's own worked example
-- ("NEW ALERT AFTER CORRECTIVE ACTION", the master prompt document) is more
-- specific than that:
--
--   Alert -> High Risk -> Counseled -> Actioned
--   New Alert -> High Risk -> Action Required
--
-- i.e. the new alert itself pushes the entity back into High Risk before
-- status flips — not any alert regardless of what it does to the entity's
-- risk tier. This migration re-gates the reopen so it only fires when the
-- entity's CURRENT alert pattern (including the just-inserted row) would
-- classify as 'high' under the mock's own computeRisk() formula
-- (dds_overview_1_.html, Driver & Asset Monitoring IIFE): 2+ days with an
-- event count > 10, OR a total count > 20.
--
-- IMPORTANT SCOPE NOTE: dds_driver_asset_weekly() (0033) is called from the
-- mock with p_from=null/p_to=null — despite its name, "weekly" here means
-- the entity's ENTIRE alert history, not a real calendar-week window (no
-- week boundary exists anywhere in this feature today). This function
-- mirrors that exact same unbounded scope, not a newly-invented week
-- boundary, so "would dds_driver_asset_weekly() show this entity as High
-- Risk right now" and "does this trigger reopen it" stay the same answer —
-- changing the scope to a real week here, while the read path stays
-- unbounded, would silently create a NEW inconsistency instead of fixing
-- the one this migration targets.
--
-- GROUPING NOTE: dds_driver_asset_weekly() groups by to_char(shift_date,
-- 'Dy') (a 3-letter weekday LABEL — 'Mon', 'Tue', ...), not by distinct
-- calendar date. Since its own data is unbounded/all-time (see above), two
-- different Mondays from two different weeks land in the SAME 'Mon' bucket
-- computeRisk() sees client-side. This function groups the same way (by
-- weekday label, not by shift_date) so a day here means exactly what a day
-- means to the mock's computeRisk() — grouping by real calendar date
-- instead would silently disagree with what the UI itself shows as High
-- Risk for the same entity.
--
-- Does not touch the trigger itself (trg_entity_status_reopen, 0033) — only
-- redefines the function it already calls, so no trigger drop/recreate is
-- needed.
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
  v_days_over_10 int;
  v_total int;
begin
  -- Cheap indexed check first (entity_status's primary key) — the risk-
  -- pattern aggregate below only needs to run for the rare case where this
  -- entity is actually 'actioned' right now; most inserts touch entities
  -- that were never flagged, so skipping straight to an UPDATE...WHERE
  -- status='actioned' (as 0033's original version did) is cheap, but
  -- computing the aggregate unconditionally on every insert would not be.
  v_asset_id := new.asset_id;
  if exists (
    select 1 from public.entity_status
    where entity_type = 'asset' and entity_id = v_asset_id and status = 'actioned'
  ) then
    select count(*) filter (where day_max > 10), coalesce(sum(day_total), 0)
      into v_days_over_10, v_total
    from (
      select to_char(shift_date, 'Dy') as day_label,
             max(event_count) as day_max, sum(event_count) as day_total
      from public.events
      where asset_id = v_asset_id
      group by to_char(shift_date, 'Dy')
    ) by_day;

    if v_days_over_10 >= 2 or v_total > 20 then
      update public.entity_status
        set status = 'required', updated_at = now(), updated_by = null
        where entity_type = 'asset' and entity_id = v_asset_id and status = 'actioned';
    end if;
  end if;

  v_driver_key := coalesce(new.emp_no, 'UNSPECIFIED');
  if exists (
    select 1 from public.entity_status
    where entity_type = 'driver' and entity_id = v_driver_key and status = 'actioned'
  ) then
    select count(*) filter (where day_max > 10), coalesce(sum(day_total), 0)
      into v_days_over_10, v_total
    from (
      select to_char(shift_date, 'Dy') as day_label,
             max(event_count) as day_max, sum(event_count) as day_total
      from public.events
      where coalesce(emp_no, 'UNSPECIFIED') = v_driver_key
      group by to_char(shift_date, 'Dy')
    ) by_day;

    if v_days_over_10 >= 2 or v_total > 20 then
      update public.entity_status
        set status = 'required', updated_at = now(), updated_by = null
        where entity_type = 'driver' and entity_id = v_driver_key and status = 'actioned';
    end if;
  end if;

  return new;
end;
$$;
