-- ============================================================================
-- DDS — 0054_entity_status_streak_and_recurrence
-- ----------------------------------------------------------------------------
-- Redesign of the "needs attention" lifecycle, from a live user walkthrough:
--
--   "the system should allow to log the action, who action it per alert
--   cases... my primary goal is to monitor the trend of the alerts and flag
--   the driver or unit with consistent high alerts for consecutive days...
--   if we already action them, did the unit remain flagged, or should we
--   implement other thing?"
--
-- Old model (0047/0048): entity_status.status was a 2-value flag,
-- 'required' (default) / 'actioned' (terminal — set once by
-- dds_log_entity_action and never re-derived from real data). The only
-- thing that could ever flip 'actioned' back to 'required' was
-- dds_entity_status_reopen, a trigger on events that re-ran a *trailing
-- 7-day spike/total rule* (>=2 days with a single event row over 10, OR a
-- 7-day sum over 20) — a different, independently-tuned rule from
-- whatever surfaced the entity as "required" in the first place, and one
-- that quietly stopped re-checking at all once the 7-day window rolled
-- past whatever triggered the original flag. Net effect: log an action,
-- and the entity could sit "Actioned" indefinitely even while it kept
-- generating the exact alerts that got it flagged, because nothing was
-- comparing recent days against the 3-consecutive-bad-days threshold the
-- user actually cares about.
--
-- New model: three states, only two of them stored.
--   required   — needs attention now (never actioned, or actioned and the
--                problem came back).
--   monitoring — action just logged; watched for a fixed window
--                (monitor_until = logged date + 3 days) rather than
--                trusted forever.
--   resolved   — DERIVED, not stored: monitor_until has passed and the
--                entity never re-qualified during the window. No status
--                value is written for this — dds_driver_asset_weekly()
--                computes it at read time, so there's no scheduled job
--                needed to "expire" anything.
-- entity_status keeps recurrence_count so a driver/unit that keeps
-- bouncing back is visibly distinguishable from one flagged for the
-- first time (surfaced in the UI as a "Recurrence" badge).
--
-- The single qualifying rule for "is this entity currently bad" is now
-- ONE function, dds_current_streak() — the count of consecutive calendar
-- days (most recent day with data going backwards, real dates, not
-- weekday-label text) where the entity's PER-DAY TOTAL event count
-- (sum of that day's rows, not any single row's count) exceeds the
-- threshold. That matches the clarified rule: several smaller alerts
-- accumulating past 10 in a day count the same as one big spike. Both
-- dds_entity_status_reopen (the write-path reopen check) and
-- dds_driver_asset_weekly (the read-path listing) call this same
-- function, so the two can no longer drift apart the way the old
-- 7-day-window rule and the client's separate computeRisk() did.
--
-- Streak threshold (>=3 consecutive qualifying days) and day-qualifying
-- rule (day total > 10) both confirmed directly by the product owner.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Shared streak function. SQL/STABLE, SECURITY INVOKER (default) — reads
--    public.events directly and relies on that table's own RLS, exactly like
--    dds_driver_asset_weekly() already does, so it's safe to call both from
--    an authenticated-user RPC context (invoker) and from inside a
--    SECURITY DEFINER trigger (definer's elevated context) without needing
--    its own auth.uid() gate.
-- ---------------------------------------------------------------------------
create or replace function public.dds_current_streak(
  p_entity_type text,
  p_entity_id text,
  p_day_threshold integer default 10,
  p_lookback_days integer default 90
)
returns integer
language sql
stable
set search_path = public
as $$
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
           (coalesce(ed.day_total, 0) > coalesce(p_day_threshold, 10)) as qualifies
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
  );
$$;

-- ---------------------------------------------------------------------------
-- 2. entity_status: add monitor_until + recurrence_count, retire 'actioned'.
--    Table has 0 rows live (confirmed before writing this migration), so
--    there is no data to migrate — only the constraint changes.
-- ---------------------------------------------------------------------------
alter table public.entity_status
  add column if not exists monitor_until date,
  add column if not exists recurrence_count integer not null default 0;

alter table public.entity_status
  drop constraint if exists entity_status_status_check;

alter table public.entity_status
  add constraint entity_status_status_check check (status in ('required', 'monitoring'));

-- ---------------------------------------------------------------------------
-- 3. dds_log_entity_action: logging an action now opens a 3-day monitoring
--    window instead of a terminal 'actioned' state. recurrence_count is
--    intentionally untouched here — it only increments on a real reopen
--    (step 4), so it stays a running history count across repeated actions.
-- ---------------------------------------------------------------------------
create or replace function public.dds_log_entity_action(p_entity_type text, p_entity_id text, p_action_type text, p_action_other_text text, p_note text, p_logged_by text)
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

  insert into public.entity_status (entity_type, entity_id, status, monitor_until, updated_by)
  values (p_entity_type, p_entity_id, 'monitoring', current_date + 3, auth.uid())
  on conflict (entity_type, entity_id)
  do update set status = 'monitoring',
                monitor_until = current_date + 3,
                updated_at = now(),
                updated_by = excluded.updated_by;

  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. dds_entity_status_reopen: replace the old independent 7-day
--    spike/total rule with the same dds_current_streak() the listing uses.
--    Any entity currently 'monitoring' whose streak re-reaches the
--    3-consecutive-day threshold on a new event flips back to 'required',
--    clears monitor_until (it's no longer "on a clock", it's flagged
--    again) and bumps recurrence_count. This fires on every new event
--    insert regardless of whether monitor_until has already lapsed, which
--    is exactly the case the product owner asked about: a "resolved"
--    (monitoring-window-elapsed) entity that starts re-qualifying gets
--    correctly reopened rather than staying silently resolved forever.
-- ---------------------------------------------------------------------------
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
begin
  v_asset_id := new.asset_id;
  if v_asset_id is not null and exists (
    select 1 from public.entity_status
    where entity_type = 'asset' and entity_id = v_asset_id and status = 'monitoring'
  ) then
    v_streak := public.dds_current_streak('asset', v_asset_id);
    if v_streak >= 3 then
      update public.entity_status
        set status = 'required',
            monitor_until = null,
            recurrence_count = recurrence_count + 1,
            updated_at = now(),
            updated_by = null
        where entity_type = 'asset' and entity_id = v_asset_id and status = 'monitoring';
    end if;
  end if;

  v_driver_key := coalesce(new.emp_no, 'UNSPECIFIED');
  if exists (
    select 1 from public.entity_status
    where entity_type = 'driver' and entity_id = v_driver_key and status = 'monitoring'
  ) then
    v_streak := public.dds_current_streak('driver', v_driver_key);
    if v_streak >= 3 then
      update public.entity_status
        set status = 'required',
            monitor_until = null,
            recurrence_count = recurrence_count + 1,
            updated_at = now(),
            updated_by = null
        where entity_type = 'driver' and entity_id = v_driver_key and status = 'monitoring';
    end if;
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. dds_driver_asset_weekly: surface the derived status + new fields.
--    'days' (the 7-day weekday-label heatmap grid) is untouched — every
--    caller in index.html invokes this with p_from/p_to both null, i.e.
--    always the default trailing 7-calendar-day window, so the
--    weekday-label bucketing (one label per calendar day in that window)
--    cannot actually collide today; changing its key format is a separate,
--    purely-cosmetic follow-up and out of scope here.
--
--    status is now DERIVED, not just passed through:
--      stored 'monitoring' + monitor_until >= today  -> 'monitoring'
--      stored 'monitoring' + monitor_until <  today  -> 'resolved' (derived)
--      stored 'required' / no row at all              -> 'required' if the
--                                                         live streak still
--                                                         qualifies (>=3),
--                                                         else 'ok'
--    This also means an entity that was flagged 'required' but whose streak
--    has since dropped below 3 without ever being actioned naturally shows
--    'ok' instead of staying stuck on 'required' forever.
-- ---------------------------------------------------------------------------
create or replace function public.dds_driver_asset_weekly(p_from date default null, p_to date default null)
returns jsonb
language sql
stable
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
  driver_streaks as (
    select entity_id, public.dds_current_streak('driver', entity_id) as streak
    from driver_entities
  ),
  asset_streaks as (
    select entity_id, public.dds_current_streak('asset', entity_id) as streak
    from asset_entities
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
      'status', case
                  when es.status = 'monitoring' then
                    case when es.monitor_until is not null and es.monitor_until >= current_date
                         then 'monitoring' else 'resolved' end
                  else
                    case when coalesce(ds.streak, 0) >= 3 then 'required' else 'ok' end
                end,
      'streakDays', coalesce(ds.streak, 0),
      'recurrenceCount', coalesce(es.recurrence_count, 0),
      'monitorUntil', to_char(es.monitor_until, 'YYYY-MM-DD'),
      'lastAction', case when la.entity_id is null then null else jsonb_build_object(
        'type', la.action_type, 'note', la.note, 'by', la.logged_by,
        'at', to_char(la.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
      ) end
    ) as row
    from driver_entities e
    left join driver_names n on n.driver_key = e.entity_id
    left join driver_days_agg dd on dd.entity_id = e.entity_id
    left join driver_streaks ds on ds.entity_id = e.entity_id
    left join public.entity_status es on es.entity_type = 'driver' and es.entity_id = e.entity_id
    left join last_actions la on la.entity_type = 'driver' and la.entity_id = e.entity_id
  ),
  assets_out as (
    select jsonb_build_object(
      'id', e.entity_id,
      'name', e.entity_id,
      'days', coalesce(ad.days, '{}'::jsonb),
      'status', case
                  when es.status = 'monitoring' then
                    case when es.monitor_until is not null and es.monitor_until >= current_date
                         then 'monitoring' else 'resolved' end
                  else
                    case when coalesce(ast.streak, 0) >= 3 then 'required' else 'ok' end
                end,
      'streakDays', coalesce(ast.streak, 0),
      'recurrenceCount', coalesce(es.recurrence_count, 0),
      'monitorUntil', to_char(es.monitor_until, 'YYYY-MM-DD'),
      'lastAction', case when la.entity_id is null then null else jsonb_build_object(
        'type', la.action_type, 'note', la.note, 'by', la.logged_by,
        'at', to_char(la.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
      ) end
    ) as row
    from asset_entities e
    left join asset_days_agg ad on ad.entity_id = e.entity_id
    left join asset_streaks ast on ast.entity_id = e.entity_id
    left join public.entity_status es on es.entity_type = 'asset' and es.entity_id = e.entity_id
    left join last_actions la on la.entity_type = 'asset' and la.entity_id = e.entity_id
  )
  select jsonb_build_object(
    'drivers', coalesce((select jsonb_agg(row) from drivers_out), '[]'::jsonb),
    'assets',  coalesce((select jsonb_agg(row) from assets_out), '[]'::jsonb)
  );
$$;
