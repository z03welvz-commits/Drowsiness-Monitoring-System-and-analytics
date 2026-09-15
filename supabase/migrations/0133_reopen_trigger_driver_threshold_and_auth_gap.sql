-- ============================================================================
-- DDS — 0133_reopen_trigger_driver_threshold_and_auth_gap
-- ----------------------------------------------------------------------------
-- Two audit findings, fixed together since the second only became safe to
-- fix once the first was in place.
--
-- 1. CONFLICTING LOGIC: dds_entity_status_reopen() (the trigger that decides
--    whether a Closed/Monitoring driver should flip back to Pending when a
--    new event arrives) called dds_current_streak('driver', ...) — the OLD
--    pooled day-total>=20 rule. Driver Streaks itself (0127/0130) now judges
--    "does this driver currently need attention" by a DIFFERENT rule: a
--    per-shift sum >20, OR a single event_count>10. Two definitions of the
--    same question, live at once, is exactly the class of bug this audit
--    was asked to find: a driver Closed on Driver Streaks could stay
--    incorrectly Closed after a new single severe alert (>10, doesn't clear
--    the trigger's pooled >=20 bar) or get incorrectly reopened by two
--    ordinary shifts that individually aren't concerning but pool past 20.
--
--    Fix: a single new function, dds_driver_requires_attention(p_emp_no),
--    replicates Driver Streaks' own qualifying-day/run/last-activity logic
--    exactly (same query shape as 0130), scoped to one driver. The reopen
--    trigger's driver branch now calls this instead of dds_current_streak()
--    — one definition, shared by both the display and the reopen check.
--    The asset branch is UNCHANGED (still dds_current_streak('asset', ...))
--    — nothing has asked to change what "qualifying" means for assets, and
--    Driver & Asset Monitoring's own status logic isn't part of this fix.
--
-- 2. dds_current_streak() had no auth.uid() check and was executable by the
--    anon role, unlike every other dds_* function. Its only real caller is
--    this same trigger (which only ever fires inside an authenticated
--    insert, per this app's established ingest pattern), so adding the
--    guard and revoking anon is a pure hardening move with no behavior
--    change for any legitimate path.
-- ============================================================================

create or replace function public.dds_driver_requires_attention(p_emp_no text)
returns boolean
language sql
stable
set search_path to 'public'
as $$
  with daily as (
    select shift_date, sum(event_count) as day_total
    from public.events
    where emp_no = p_emp_no
    group by shift_date
  ),
  shift_daily as (
    select shift_date, shift, sum(event_count) as shift_total
    from public.events
    where emp_no = p_emp_no
    group by shift_date, shift
  ),
  qualifying_days as (
    select distinct shift_date
    from public.events
    where emp_no = p_emp_no and event_count > 10
    union
    select shift_date from shift_daily where shift_total > 20
  ),
  qualifying as (
    select shift_date,
           shift_date - (row_number() over (order by shift_date))::int as grp
    from qualifying_days
  ),
  runs as (
    select min(shift_date) as run_start, max(shift_date) as run_end, count(*) as run_len
    from qualifying
    group by grp
  ),
  latest_run as (
    select run_end, run_len from runs order by run_end desc limit 1
  ),
  last_activity as (
    select max(shift_date) as d from daily
  ),
  last_activity_acute as (
    select bool_or(event_count > 10) as acute
    from public.events
    where emp_no = p_emp_no
      and shift_date = (select d from last_activity)
  )
  select coalesce(
    (select lr.run_end = la.d and lr.run_len >= 3 from latest_run lr, last_activity la),
    false
  ) or coalesce((select acute from last_activity_acute), false);
$$;

revoke all on function public.dds_driver_requires_attention(text) from public, anon;
grant execute on function public.dds_driver_requires_attention(text) to authenticated;

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
    if public.dds_driver_requires_attention(v_driver_key) then
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

create or replace function public.dds_current_streak(
  p_entity_type text,
  p_entity_id text,
  p_day_threshold integer default 20,
  p_lookback_days integer default 90
)
returns integer
language plpgsql
stable
set search_path to 'public'
as $$
declare
  v_result integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with entity_days as (
    select shift_date, sum(event_count) as day_total
    from public.events
    where (p_entity_type = 'driver' and coalesce(emp_no, 'UNSPECIFIED') = p_entity_id)
       or (p_entity_type = 'asset' and asset_id = p_entity_id)
    group by shift_date
  ),
  last_day as (
    select max(shift_date) as d from entity_days
  ),
  cal as (
    select generate_series(
      (select d from last_day) - (greatest(coalesce(p_lookback_days, 90), 1) - 1) * interval '1 day',
      (select d from last_day),
      interval '1 day'
    )::date as cal_date
  ),
  joined as (
    select cal.cal_date,
           (coalesce(ed.day_total, 0) >= coalesce(p_day_threshold, 20)) as qualifies
    from cal
    left join entity_days ed on ed.shift_date = cal.cal_date
  ),
  ranked as (
    select row_number() over (order by cal_date desc) as rn, qualifies
    from joined
  ),
  first_break as (
    select min(rn) as rn from ranked where not qualifies
  )
  select coalesce(
    case
      when (select rn from first_break) is null then (select count(*) from ranked)
      else (select rn from first_break) - 1
    end,
    0
  )
  into v_result;

  return v_result;
end;
$$;

revoke all on function public.dds_current_streak(text, text, integer, integer) from public, anon;
grant execute on function public.dds_current_streak(text, text, integer, integer) to authenticated;
