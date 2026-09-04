-- ============================================================================
-- DDS — 0053_driver_asset_instances_pagination_actionby
-- ----------------------------------------------------------------------------
-- Two real bugs found in a UI review of Driver & Asset Monitoring's "See
-- details" popup (dds_driver_alert_instances / dds_asset_alert_instances,
-- 0035_alert_case_instances.sql):
--
-- 1. NO "who logged this" anywhere. alert_cases.updated_by (a real column,
--    populated by every write path) was never surfaced by either function,
--    even though dds_alert_logs() (0044_alert_logs_action_by_and_sort.sql)
--    already does exactly this resolution — updated_by -> profiles.username
--    — for the Alert Logs page. Same join, applied here.
--
-- 2. The popup silently hard-capped at the 500 most-recent events with no
--    pagination and no indication a cap existed. For any driver/bucket with
--    more than 500 matching events in range — the 'UNSPECIFIED' bucket
--    (unattributed events) being the extreme case, routinely in the tens or
--    hundreds of thousands — a user can select-all and log every VISIBLE
--    row, see them all marked "Logged", and still find the driver-level
--    Status column stuck on "Pending": dds_driver_event_summary's own
--    `done` flag (and this function's own `allHighSeverityActioned`) is
--    computed against the FULL matching set, not the 500 shown, so it
--    correctly stays false while thousands of older events past the cap
--    remain unactioned and were never reachable from this popup at all.
--    Real pagination (p_limit/p_offset, same convention as
--    dds_driver_event_summary/dds_asset_event_summary) plus an honest
--    total row count fixes the reachability gap and makes the cap visible
--    instead of silent.
--
-- NOTE: adding new trailing parameters via CREATE OR REPLACE does NOT
-- replace the old 3-arg function — Postgres treats a different parameter
-- list as a distinct overload, so the old (text, date, date) signatures
-- must be dropped explicitly or both versions stay live simultaneously
-- (confirmed live: applying this without the drops below left two
-- overloads of each function active at once).
-- ============================================================================

drop function if exists public.dds_driver_alert_instances(text, date, date);
drop function if exists public.dds_asset_alert_instances(text, date, date);

create or replace function public.dds_driver_alert_instances(
  p_emp_no text,
  p_from date default null,
  p_to date default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 100), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'empNo', p_emp_no,
    'total', coalesce((
      select sum(e.event_count) from public.events e
      where coalesce(e.emp_no, 'UNSPECIFIED') = p_emp_no
        and (p_from is null or e.shift_date >= p_from)
        and (p_to   is null or e.shift_date <= p_to)
    ), 0),
    'rowCount', coalesce((
      select count(*) from public.events e
      where coalesce(e.emp_no, 'UNSPECIFIED') = p_emp_no
        and (p_from is null or e.shift_date >= p_from)
        and (p_to   is null or e.shift_date <= p_to)
    ), 0),
    -- true only when every critical/high-tier instance in range already
    -- has a logged alert_cases action (status_value not null) -- unchanged,
    -- already computed against the FULL set, not the paged-in rows below.
    'allHighSeverityActioned', not exists (
      select 1 from public.events e
      left join public.alert_cases c on c.event_id = e.id
      where coalesce(e.emp_no, 'UNSPECIFIED') = p_emp_no
        and (p_from is null or e.shift_date >= p_from)
        and (p_to   is null or e.shift_date <= p_to)
        and (e.event_code ilike '%sleep%' or e.event_code ilike '%drowsi%')
        and c.status_value is null
    ),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'eventId',         e.id,
        'unit',            e.asset_id,
        'startTime',       to_char(e.start_time, 'MM/DD/YYYY HH24:MI:SS'),
        'endTime',         to_char(e.end_time, 'MM/DD/YYYY HH24:MI:SS'),
        'updateTime',      to_char(e.update_time, 'MM/DD/YYYY HH24:MI:SS'),
        'eventCode',       e.event_code,
        'eventCount',      e.event_count,
        'severityTier',    case
                              when e.event_code ilike '%sleep%' then 'critical'
                              when e.event_code ilike '%drowsi%' then 'high'
                              else 'moderate'
                            end,
        'actionType',      c.action_type,
        'actionOtherText', c.action_is_other,
        'actionDate',      to_char(c.action_date, 'MM/DD/YYYY'),
        'statusValue',     c.status_value,
        'remarks',         c.remarks,
        'actionBy',        pu.username
      ) order by e.start_time desc, e.id desc)
      from (
        select * from public.events e2
        where coalesce(e2.emp_no, 'UNSPECIFIED') = p_emp_no
          and (p_from is null or e2.shift_date >= p_from)
          and (p_to   is null or e2.shift_date <= p_to)
        order by e2.start_time desc, e2.id desc
        limit v_limit offset v_offset
      ) e
      left join public.alert_cases c  on c.event_id = e.id
      left join public.profiles    pu on pu.user_id = c.updated_by
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

create or replace function public.dds_asset_alert_instances(
  p_asset_id text,
  p_from date default null,
  p_to date default null,
  p_limit integer default 100,
  p_offset integer default 0
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 100), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'assetId', p_asset_id,
    'total', coalesce((
      select sum(e.event_count) from public.events e
      where e.asset_id = p_asset_id
        and (p_from is null or e.shift_date >= p_from)
        and (p_to   is null or e.shift_date <= p_to)
    ), 0),
    'rowCount', coalesce((
      select count(*) from public.events e
      where e.asset_id = p_asset_id
        and (p_from is null or e.shift_date >= p_from)
        and (p_to   is null or e.shift_date <= p_to)
    ), 0),
    'avgSyncSeconds', (
      select avg(e.sync_seconds)::int from public.events e
      where e.asset_id = p_asset_id
        and e.sync_seconds is not null
        and (p_from is null or e.shift_date >= p_from)
        and (p_to   is null or e.shift_date <= p_to)
    ),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'eventId',    e.id,
        'startTime',  to_char(e.start_time, 'MM/DD/YYYY HH24:MI:SS'),
        'endTime',    to_char(e.end_time, 'MM/DD/YYYY HH24:MI:SS'),
        'updateTime', to_char(e.update_time, 'MM/DD/YYYY HH24:MI:SS'),
        'eventCode',  e.event_code,
        'eventCount', e.event_count
      ) order by e.start_time desc, e.id desc)
      from (
        select * from public.events e2
        where e2.asset_id = p_asset_id
          and (p_from is null or e2.shift_date >= p_from)
          and (p_to   is null or e2.shift_date <= p_to)
        order by e2.start_time desc, e2.id desc
        limit v_limit offset v_offset
      ) e
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;
