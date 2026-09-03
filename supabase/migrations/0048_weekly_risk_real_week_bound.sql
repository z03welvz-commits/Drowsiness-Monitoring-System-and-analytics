-- ============================================================================
-- DDS — 0048_weekly_risk_real_week_bound
-- ----------------------------------------------------------------------------
-- The audit found dds_driver_asset_weekly() is always called with
-- p_from=null/p_to=null (index.html's only call site, fetchWeekly()), which
-- 0034's own header already documented as deliberate: "weekly" here has
-- never meant a real calendar week, it means the entity's entire alert
-- history, grouped by weekday LABEL (Mon/Tue/...) so two different Mondays
-- from two different weeks land in the same bucket. That scope was kept
-- unbounded specifically so the read path (this function, which still
-- drives the High/Medium/Low KPI cards and the Summary page's "top
-- flagged" table via loadWeeklyRiskBackground()/window.__daState) and the
-- reopen trigger's write path (dds_entity_status_reopen(), 0034) would
-- always agree on whether an entity is currently High Risk.
--
-- Every label on screen (KPI cards, detail drawer, action-modal context,
-- History modal — 8+ sites in index.html) calls this "this week." Once an
-- account has more than a week of history, that's actively wrong: a driver
-- can stay flagged High Risk forever from old, already-resolved alerts,
-- with zero real alerts in the actual current week. It was also an
-- unconditional full scan of events on every Driver & Asset page visit.
--
-- Fix: bound the DEFAULT (null/null) window to a real trailing 7 days —
-- current_date and the 6 days before it — on BOTH sides at once, so they
-- stay in agreement the same way the unbounded version did:
--   - dds_driver_asset_weekly(): null/null now means "trailing 7 days",
--     not "all time". An explicit wide p_from/p_to still works exactly as
--     before for any future caller that wants a longer window on purpose.
--   - dds_entity_status_reopen() trigger: its risk-pattern aggregate is
--     scoped to the same trailing 7 days, instead of all-time.
-- A rolling 7-day window can contain at most one of each weekday label, so
-- grouping by to_char(shift_date, 'Dy') is still safe here — no cross-week
-- label collision exists once the range is bounded to <=7 days.
--
-- index.html's fetchWeekly() needs no change: it already calls this RPC
-- with p_from: null, p_to: null — the bound moves server-side, not client-
-- side, so every UI label calling this "this week" becomes true instead of
-- requiring a separate client-side date-math change.
-- ============================================================================

create or replace function public.dds_driver_asset_weekly(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language sql
stable
security invoker
set search_path = public
set work_mem = '64MB'
as $$
  with bounds as (
    select
      coalesce(p_from, current_date - interval '6 days')::date as v_from,
      coalesce(p_to, current_date)::date as v_to
  ),
  filtered as (
    select
      coalesce(emp_no, 'UNSPECIFIED') as driver_key,
      asset_id,
      shift_date,
      event_count
    from public.events, bounds
    where shift_date >= bounds.v_from
      and shift_date <= bounds.v_to
  ),
  driver_days_agg as (
    select driver_key as entity_id, jsonb_object_agg(day_label, counts) as days
    from (
      select driver_key,
             to_char(shift_date, 'Dy') as day_label,
             jsonb_agg(event_count order by event_count desc) as counts
      from filtered
      group by driver_key, to_char(shift_date, 'Dy')
    ) x
    group by driver_key
  ),
  asset_days_agg as (
    select asset_id as entity_id, jsonb_object_agg(day_label, counts) as days
    from (
      select asset_id,
             to_char(shift_date, 'Dy') as day_label,
             jsonb_agg(event_count order by event_count desc) as counts
      from filtered
      group by asset_id, to_char(shift_date, 'Dy')
    ) x
    group by asset_id
  ),
  driver_entities as (
    select distinct driver_key as entity_id from filtered
  ),
  asset_entities as (
    select distinct asset_id as entity_id from filtered
  ),
  driver_names as (
    select coalesce(d.full_name, e.entity_id) as name, e.entity_id as driver_key
    from driver_entities e
    left join public.drivers d on d.emp_no = e.entity_id
  ),
  last_actions as (
    select distinct on (entity_type, entity_id)
      entity_type, entity_id, action_type, note, logged_by, created_at
    from public.entity_action_log
    order by entity_type, entity_id, created_at desc
  ),
  drivers_out as (
    select jsonb_build_object(
      'id', e.entity_id,
      'name', case when e.entity_id = 'UNSPECIFIED' then 'Unspecified' else n.name end,
      'days', coalesce(dd.days, '{}'::jsonb),
      'status', coalesce(es.status, 'required'),
      'lastAction', case when la.entity_id is null then null else jsonb_build_object(
        'type', la.action_type, 'note', la.note, 'by', la.logged_by,
        'at', to_char(la.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
      ) end
    ) as row
    from driver_entities e
    left join driver_names n on n.driver_key = e.entity_id
    left join driver_days_agg dd on dd.entity_id = e.entity_id
    left join public.entity_status es on es.entity_type = 'driver' and es.entity_id = e.entity_id
    left join last_actions la on la.entity_type = 'driver' and la.entity_id = e.entity_id
  ),
  assets_out as (
    select jsonb_build_object(
      'id', e.entity_id,
      'name', e.entity_id,
      'days', coalesce(ad.days, '{}'::jsonb),
      'status', coalesce(es.status, 'required'),
      'lastAction', case when la.entity_id is null then null else jsonb_build_object(
        'type', la.action_type, 'note', la.note, 'by', la.logged_by,
        'at', to_char(la.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
      ) end
    ) as row
    from asset_entities e
    left join asset_days_agg ad on ad.entity_id = e.entity_id
    left join public.entity_status es on es.entity_type = 'asset' and es.entity_id = e.entity_id
    left join last_actions la on la.entity_type = 'asset' and la.entity_id = e.entity_id
  )
  select jsonb_build_object(
    'drivers', coalesce((select jsonb_agg(row) from drivers_out), '[]'::jsonb),
    'assets',  coalesce((select jsonb_agg(row) from assets_out), '[]'::jsonb)
  );
$$;

revoke all on function public.dds_driver_asset_weekly(date, date) from public, anon;
grant execute on function public.dds_driver_asset_weekly(date, date) to authenticated;

-- ── Reopen trigger: same trailing-7-day bound, so it keeps agreeing with
-- the read path above exactly as 0034 originally required. ─────────────────
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
  v_from date := current_date - interval '6 days';
  v_to date := current_date;
begin
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
        and shift_date >= v_from and shift_date <= v_to
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
        and shift_date >= v_from and shift_date <= v_to
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
