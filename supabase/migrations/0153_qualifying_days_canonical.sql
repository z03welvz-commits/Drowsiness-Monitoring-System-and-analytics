-- ============================================================================
-- DDS — 0153_qualifying_days_canonical
-- ----------------------------------------------------------------------------
-- Part 1 of the action-logging/status redesign. Three RPCs
-- (dds_driver_streaks, dds_required_attention, dds_driver_asset_weekly) each
-- independently decide whether a driver/asset "qualifies" on a given shift
-- date. Migration 0147 fixed the rule everywhere it was wrong EXCEPT
-- dds_driver_asset_weekly, which still blends all event types together into
-- one day_total and compares that to a threshold — so a driver with 12 Sleep
-- + 9 Drowsiness events (21 blended) qualifies there but not on Driver
-- Streaks or Required Attention, which correctly require one event type to
-- individually cross its own threshold.
--
-- This migration adds the single canonical rule as a reusable function.
-- Migration 0154 rewires all three RPCs to call it instead of re-deriving
-- their own version, so there is exactly one place this rule can drift again.
--
-- Rule (unchanged from 0147, generalized to also serve assets): a
-- (entity_id, shift_date) pair qualifies if any single event that day has
-- event_count > 10, OR any one event_code's sum for that day exceeds 20 —
-- never blending event types together.
-- ============================================================================

create or replace function public.dds_qualifying_days(
  p_entity_type text,
  p_from date default null,
  p_to date default null
)
returns table(entity_id text, shift_date date)
language sql
stable
set search_path to 'public'
as $function$
  with scoped as (
    select
      case when p_entity_type = 'asset' then e.asset_id else e.emp_no end as entity_id,
      e.shift_date,
      e.event_code,
      e.event_count
    from public.events e
    where (case when p_entity_type = 'asset' then e.asset_id else e.emp_no end) is not null
      and (p_from is null or e.shift_date >= p_from)
      and (p_to is null or e.shift_date <= p_to)
  ),
  by_code as (
    select entity_id, shift_date, sum(event_count) as code_day_total
    from scoped
    group by entity_id, shift_date, event_code
  )
  select entity_id, shift_date from scoped where event_count > 10
  union
  select entity_id, shift_date from by_code where code_day_total > 20;
$function$;

comment on function public.dds_qualifying_days(text, date, date) is
  'Canonical "does this driver/asset qualify as flagged on this shift date" rule: a single event > 10, or one event_code''s day-sum > 20 — never blended across event types. Shared by dds_driver_streaks, dds_required_attention, and dds_driver_asset_weekly (migration 0154).';
