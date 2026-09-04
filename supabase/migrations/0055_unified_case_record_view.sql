-- ============================================================================
-- DDS — 0055_unified_case_record_view
-- ----------------------------------------------------------------------------
-- Phase 1 of the whole-app consolidation pass (see the approved plan). Fixes
-- three confirmed issues found in a full data-model audit:
--
-- 1. Five separate RPCs (dds_alert_logs, dds_driver_alert_instances,
--    dds_asset_alert_instances, dds_driver_event_summary,
--    dds_asset_event_summary) each independently re-derive the SAME
--    events <-> alert_cases <-> drivers <-> profiles join, with no shared
--    definition anywhere. A fix to "how do we resolve Action By" or "how do
--    we decide a row is unresolved-high-severity" has to be applied five
--    times by hand — exactly the kind of duplication that let the
--    "select-all only grabs the current page" bug survive in one copy of
--    the bulk-selection-bar while already being fixed in another.
--    dds_case_records is the ONE place that join now lives; every one of
--    those five RPCs is repointed to select from it below, with their
--    existing signatures, params, filters and returned JSON shapes left
--    byte-for-byte identical — this is a pure refactor, not a behavior
--    change (each RPC still resolves driver identity exactly the way it
--    always did: dds_alert_logs alone uses the case-level driver/emp_no
--    override via driver_display/emp_no_display; the per-driver drill-down
--    RPCs key strictly off the event's own emp_no, unchanged).
--
-- 2. alert_cases.action_type has never had a server-side constraint at
--    all. Two different screens write to it with two different
--    vocabularies — Alert Logs' bulk bar (Reviewed/Escalated/Coached/
--    Dismissed/Other) and the Driver & Asset instance popup's bulk bar
--    (Spare/Continue/Other) — so anything, including a typo, could land in
--    the column from either screen. Both pickers stay as they are (they
--    serve genuinely different moments — after-the-fact triage vs. an
--    immediate this-shift decision) but the column itself is now
--    constrained to the union of both, so nothing else can ever land there.
--
-- 3. events(asset_id, shift_date) had no composite index — only a bare
--    single-column index on asset_id — while the mirror-image
--    events(emp_no, shift_date) index already existed (0019). Every
--    asset-side query (dds_current_streak('asset',...),
--    dds_asset_event_summary, dds_asset_alert_instances) was scanning all
--    of an asset's rows instead of seeking a date range. Added for parity.
--
-- Also backfills the migration history for entity_status/entity_action_log
-- (0054's tables) whose actual CREATE TABLE is missing from this repo's
-- checked-in migration history — `supabase db reset` could not replay from
-- scratch and end up with a working schema without this. IF NOT EXISTS
-- throughout, so this is a no-op against the live database (both tables
-- already exist there) and only matters for a from-scratch replay.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Backfill missing 0033/0034 history — entity_status / entity_action_log.
--    Column set, constraints, indexes and RLS policies below mirror the
--    live database exactly (verified via information_schema/pg_policies
--    before writing this), not a guess.
-- ---------------------------------------------------------------------------
create table if not exists public.entity_status (
  entity_type text not null,
  entity_id text not null,
  status text not null default 'required',
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  monitor_until date,
  recurrence_count integer not null default 0,
  primary key (entity_type, entity_id),
  constraint entity_status_entity_type_check check (entity_type in ('driver', 'asset')),
  constraint entity_status_status_check check (status in ('required', 'monitoring'))
);

alter table public.entity_status enable row level security;

drop policy if exists es_read on public.entity_status;
create policy es_read on public.entity_status for select
  using (auth.uid() is not null);

drop policy if exists es_upsert on public.entity_status;
create policy es_upsert on public.entity_status for insert
  with check (auth.uid() is not null and updated_by = auth.uid());

drop policy if exists es_update on public.entity_status;
create policy es_update on public.entity_status for update
  using (auth.uid() is not null)
  with check (updated_by = auth.uid());

create table if not exists public.entity_action_log (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null,
  entity_id text not null,
  action_type text not null,
  action_other_text text,
  note text,
  logged_by text not null,
  actor_user_id uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create index if not exists idx_eal_entity on public.entity_action_log (entity_type, entity_id, created_at desc);

alter table public.entity_action_log enable row level security;

drop policy if exists eal_read on public.entity_action_log;
create policy eal_read on public.entity_action_log for select
  using (auth.uid() is not null);

drop policy if exists eal_insert on public.entity_action_log;
create policy eal_insert on public.entity_action_log for insert
  with check (auth.uid() is not null and actor_user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 1. alert_cases.action_type — union constraint (see comment above).
-- ---------------------------------------------------------------------------
alter table public.alert_cases
  drop constraint if exists alert_cases_action_type_check;

alter table public.alert_cases
  add constraint alert_cases_action_type_check check (
    action_type is null or action_type in (
      'Reviewed', 'Escalated', 'Coached', 'Dismissed',
      'Spare', 'Continue', 'Other'
    )
  );

-- ---------------------------------------------------------------------------
-- 2. Missing index — parity with idx_events_emp_no_date (0019).
-- ---------------------------------------------------------------------------
create index if not exists idx_events_asset_shift_date on public.events (asset_id, shift_date);

-- ---------------------------------------------------------------------------
-- 3. The shared view. Plain (not materialized) — Postgres inlines it, so
--    every existing predicate on shift_date/emp_no/asset_id still hits the
--    same indexes it always did through the underlying events table.
-- ---------------------------------------------------------------------------
create or replace view public.dds_case_records as
select
  e.id                                                                          as event_id,
  e.shift_date,
  e.shift,
  e.asset_id,
  e.emp_no,
  coalesce(e.emp_no, 'UNSPECIFIED')                                             as emp_no_norm,
  d.full_name                                                                   as emp_name,
  e.operator,
  e.event_code,
  e.event_count,
  e.start_time,
  e.end_time,
  e.update_time,
  e.sync_seconds,
  e.actionable,
  c.id                                                                          as case_id,
  c.driver_name                                                                 as case_driver_name,
  c.emp_no                                                                      as case_emp_no,
  dc.full_name                                                                  as case_emp_name,
  c.action_type                                                                 as action_performed,
  c.action_is_other,
  c.action_date,
  c.status_value                                                                as status,
  c.status_is_other,
  c.remarks,
  c.updated_at                                                                  as case_updated_at,
  c.updated_by                                                                  as case_updated_by,
  pu.username                                                                   as action_by,
  coalesce(nullif(c.driver_name, ''), dc.full_name, d.full_name, nullif(e.operator, '')) as driver_display,
  coalesce(c.emp_no, e.emp_no)                                                  as emp_no_display,
  ((e.event_code ilike '%sleep%' or e.event_code ilike '%drowsi%') and c.status_value is null) as is_unresolved_high_severity
from public.events e
left join public.alert_cases c on c.event_id = e.id
left join public.drivers d    on d.emp_no = e.emp_no
left join public.drivers dc   on dc.emp_no = c.emp_no
left join public.profiles pu  on pu.user_id = c.updated_by;

-- ---------------------------------------------------------------------------
-- 4. Repoint the five RPCs. Signatures, filters, sort options and returned
--    JSON shapes are unchanged from their current live definitions — only
--    the FROM/JOIN clauses move to the view above.
-- ---------------------------------------------------------------------------
create or replace function public.dds_alert_logs(p_from date default null, p_to date default null, p_shift text default null, p_status text default null, p_search text default null, p_limit integer default 75, p_offset integer default 0, p_sort text default 'start_time', p_dir text default 'desc')
returns jsonb
language plpgsql
stable
set search_path = public
set work_mem = '48MB'
as $$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 75), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_desc boolean := lower(coalesce(p_dir, 'desc')) <> 'asc';
  v_sort text := lower(coalesce(p_sort, 'start_time'));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with filtered as (
    select r.event_id as id, r.update_time, r.start_time, r.end_time, r.asset_id, r.event_code,
           r.event_count, r.operator, r.shift, r.shift_date, r.actionable,
           r.emp_no as event_emp_no, r.emp_name as event_emp_name,
           r.case_id, r.case_driver_name as driver_name, r.case_emp_no, r.case_emp_name,
           r.action_performed as action_type, r.action_is_other,
           r.status as status_value, r.status_is_other, r.remarks, r.case_updated_at,
           r.action_by,
           r.driver_display,
           r.emp_no_display
    from public.dds_case_records r
    where (p_from   is null or r.shift_date >= p_from)
      and (p_to     is null or r.shift_date <= p_to)
      and (p_shift  is null or r.shift = p_shift)
      and (p_status is null or p_status = 'all'
           or (p_status = 'unset' and r.status is null)
           or r.status = p_status)
      and (p_search is null or p_search = '' or
           r.asset_id ilike '%' || p_search || '%' or
           coalesce(r.operator, '') ilike '%' || p_search || '%' or
           r.event_code ilike '%' || p_search || '%' or
           coalesce(r.case_driver_name, '') ilike '%' || p_search || '%' or
           coalesce(r.case_emp_name, '') ilike '%' || p_search || '%' or
           coalesce(r.emp_name, '') ilike '%' || p_search || '%' or
           coalesce(r.case_emp_no, '') ilike '%' || p_search || '%' or
           coalesce(r.emp_no, '') ilike '%' || p_search || '%')
  ),
  total as (select count(*) as n from filtered),
  paged as (
    select * from filtered
    order by
      -- text-typed sort keys
      case when v_desc then null else
        case v_sort
          when 'asset_id'   then asset_id
          when 'event_code' then event_code
          when 'shift'      then shift
          when 'driver'     then driver_display
          when 'status'     then status_value
          when 'action'     then action_type
          when 'emp_no'     then emp_no_display
          when 'action_by'  then action_by
          when 'remarks'    then remarks
        end
      end asc nulls last,
      case when v_desc then
        case v_sort
          when 'asset_id'   then asset_id
          when 'event_code' then event_code
          when 'shift'      then shift
          when 'driver'     then driver_display
          when 'status'     then status_value
          when 'action'     then action_type
          when 'emp_no'     then emp_no_display
          when 'action_by'  then action_by
          when 'remarks'    then remarks
        end
      end desc nulls last,
      -- date-typed sort key
      case when v_sort = 'shift_date' and not v_desc then shift_date end asc nulls last,
      case when v_sort = 'shift_date' and v_desc     then shift_date end desc nulls last,
      -- timestamp-typed sort keys
      case when v_sort = 'start_time'  and not v_desc then start_time  end asc nulls last,
      case when v_sort = 'start_time'  and v_desc     then start_time  end desc nulls last,
      case when v_sort = 'end_time'    and not v_desc then end_time    end asc nulls last,
      case when v_sort = 'end_time'    and v_desc     then end_time    end desc nulls last,
      case when v_sort = 'update_time' and not v_desc then update_time end asc nulls last,
      case when v_sort = 'update_time' and v_desc     then update_time end desc nulls last,
      -- integer-typed sort key
      case when v_sort = 'event_count' and not v_desc then event_count end asc nulls last,
      case when v_sort = 'event_count' and v_desc     then event_count end desc nulls last,
      id desc
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'startTime', start_time, 'updateTime', update_time, 'endTime', end_time,
        'assetId', asset_id, 'eventCode', event_code, 'eventCount', event_count,
        'operator', operator, 'shift', shift, 'shiftDate', shift_date, 'actionable', actionable,
        'caseId', case_id, 'driverName', driver_name,
        'empNo', emp_no_display, 'driverDisplayName', driver_display,
        'actionType', action_type, 'actionIsOther', action_is_other,
        'statusValue', status_value, 'statusIsOther', status_is_other,
        'remarks', remarks, 'caseUpdatedAt', case_updated_at, 'actionBy', action_by
      ))
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

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
      select sum(r.event_count) from public.dds_case_records r
      where r.emp_no_norm = p_emp_no
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
    ), 0),
    'rowCount', coalesce((
      select count(*) from public.dds_case_records r
      where r.emp_no_norm = p_emp_no
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
    ), 0),
    'allHighSeverityActioned', not exists (
      select 1 from public.dds_case_records r
      where r.emp_no_norm = p_emp_no
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
        and r.is_unresolved_high_severity
    ),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'eventId',         r.event_id,
        'unit',            r.asset_id,
        'startTime',       to_char(r.start_time, 'MM/DD/YYYY HH24:MI:SS'),
        'endTime',         to_char(r.end_time, 'MM/DD/YYYY HH24:MI:SS'),
        'updateTime',      to_char(r.update_time, 'MM/DD/YYYY HH24:MI:SS'),
        'eventCode',       r.event_code,
        'eventCount',      r.event_count,
        'severityTier',    case
                              when r.event_code ilike '%sleep%' then 'critical'
                              when r.event_code ilike '%drowsi%' then 'high'
                              else 'moderate'
                            end,
        'actionType',      r.action_performed,
        'actionOtherText', r.action_is_other,
        'actionDate',      to_char(r.action_date, 'MM/DD/YYYY'),
        'statusValue',     r.status,
        'remarks',         r.remarks,
        'actionBy',        r.action_by
      ) order by r.start_time desc, r.event_id desc)
      from (
        select * from public.dds_case_records r2
        where r2.emp_no_norm = p_emp_no
          and (p_from is null or r2.shift_date >= p_from)
          and (p_to   is null or r2.shift_date <= p_to)
        order by r2.start_time desc, r2.event_id desc
        limit v_limit offset v_offset
      ) r
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
      select sum(r.event_count) from public.dds_case_records r
      where r.asset_id = p_asset_id
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
    ), 0),
    'rowCount', coalesce((
      select count(*) from public.dds_case_records r
      where r.asset_id = p_asset_id
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
    ), 0),
    'avgSyncSeconds', (
      select avg(r.sync_seconds)::int from public.dds_case_records r
      where r.asset_id = p_asset_id
        and r.sync_seconds is not null
        and (p_from is null or r.shift_date >= p_from)
        and (p_to   is null or r.shift_date <= p_to)
    ),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'eventId',    r.event_id,
        'startTime',  to_char(r.start_time, 'MM/DD/YYYY HH24:MI:SS'),
        'endTime',    to_char(r.end_time, 'MM/DD/YYYY HH24:MI:SS'),
        'updateTime', to_char(r.update_time, 'MM/DD/YYYY HH24:MI:SS'),
        'eventCode',  r.event_code,
        'eventCount', r.event_count
      ) order by r.start_time desc, r.event_id desc)
      from (
        select * from public.dds_case_records r2
        where r2.asset_id = p_asset_id
          and (p_from is null or r2.shift_date >= p_from)
          and (p_to   is null or r2.shift_date <= p_to)
        order by r2.start_time desc, r2.event_id desc
        limit v_limit offset v_offset
      ) r
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

create or replace function public.dds_driver_event_summary(p_search text default null, p_sort text default 'total', p_dir text default 'desc', p_limit integer default 50, p_offset integer default 0, p_from date default null, p_to date default null, p_shift text default null)
returns jsonb
language plpgsql
stable
set search_path = public
set work_mem = '64MB'
as $$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 50), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_desc boolean := lower(coalesce(p_dir, 'desc')) is distinct from 'asc';
  v_sort text := lower(coalesce(p_sort, 'total'));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with base as (
    select
      r.emp_no_norm as emp_no,
      coalesce(r.emp_name, case when r.emp_no is null then 'Unspecified' else r.emp_no end) as emp_name,
      r.event_code,
      r.event_count,
      r.is_unresolved_high_severity
    from public.dds_case_records r
    where (p_from is null or r.shift_date >= p_from)
      and (p_to   is null or r.shift_date <= p_to)
      and (p_shift is null or p_shift = '' or r.shift = p_shift)
  ),
  per_driver_code as (
    select emp_no, emp_name, event_code, sum(event_count) as code_count
    from base
    group by emp_no, emp_name, event_code
  ),
  codes_agg as (
    select emp_no, emp_name,
      jsonb_agg(jsonb_build_object('eventCode', event_code, 'count', code_count) order by code_count desc) as codes,
      sum(code_count) as total
    from per_driver_code
    group by emp_no, emp_name
  ),
  status_agg as (
    select emp_no, not bool_or(is_unresolved_high_severity) as done
    from base
    group by emp_no
  ),
  filtered as (
    select ca.emp_no, ca.emp_name, ca.codes, ca.total, coalesce(sa.done, true) as done
    from codes_agg ca
    left join status_agg sa on sa.emp_no = ca.emp_no
    where p_search is null or p_search = ''
       or ca.emp_name ilike '%' || p_search || '%'
       or ca.emp_no ilike '%' || p_search || '%'
  ),
  total_count as (select count(*) as n from filtered),
  paged as (
    select * from filtered
    order by
      case when v_desc then null else
        case v_sort
          when 'emp_name' then emp_name
          when 'emp_no'   then emp_no
        end
      end asc nulls last,
      case when v_desc then
        case v_sort
          when 'emp_name' then emp_name
          when 'emp_no'   then emp_no
        end
      end desc nulls last,
      case when v_sort = 'total' and not v_desc then total end asc nulls last,
      case when v_sort = 'total' and v_desc     then total end desc nulls last,
      emp_no
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total_count),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'empNo', emp_no, 'empName', emp_name, 'eventCodes', codes,
        'total', total, 'done', done
      ))
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

create or replace function public.dds_asset_event_summary(p_search text default null, p_sort text default 'total', p_dir text default 'desc', p_limit integer default 50, p_offset integer default 0, p_from date default null, p_to date default null, p_shift text default null)
returns jsonb
language plpgsql
stable
set search_path = public
set work_mem = '64MB'
as $$
declare
  result jsonb;
  v_limit integer := least(coalesce(p_limit, 50), 200);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_desc boolean := lower(coalesce(p_dir, 'desc')) is distinct from 'asc';
  v_sort text := lower(coalesce(p_sort, 'total'));
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with base as (
    select r.asset_id, r.event_code, r.event_count, r.sync_seconds
    from public.dds_case_records r
    where (p_from is null or r.shift_date >= p_from)
      and (p_to   is null or r.shift_date <= p_to)
      and (p_shift is null or p_shift = '' or r.shift = p_shift)
  ),
  per_asset_code as (
    select asset_id, event_code, sum(event_count) as code_count
    from base
    group by asset_id, event_code
  ),
  codes_agg as (
    select asset_id,
      jsonb_agg(jsonb_build_object('eventCode', event_code, 'count', code_count) order by code_count desc) as codes,
      sum(code_count) as total
    from per_asset_code
    group by asset_id
  ),
  sync_agg as (
    select asset_id, avg(sync_seconds)::int as avg_sync_seconds
    from base
    where sync_seconds is not null
    group by asset_id
  ),
  filtered as (
    select ca.asset_id, ca.codes, ca.total, sy.avg_sync_seconds
    from codes_agg ca
    left join sync_agg sy on sy.asset_id = ca.asset_id
    where p_search is null or p_search = '' or ca.asset_id ilike '%' || p_search || '%'
  ),
  total_count as (select count(*) as n from filtered),
  paged as (
    select * from filtered
    order by
      case when v_desc then null else case v_sort when 'asset_id' then asset_id end end asc nulls last,
      case when v_desc then case v_sort when 'asset_id' then asset_id end end desc nulls last,
      case when v_sort = 'total' and not v_desc then total end asc nulls last,
      case when v_sort = 'total' and v_desc     then total end desc nulls last,
      asset_id
    limit v_limit offset v_offset
  )
  select jsonb_build_object(
    'total', (select n from total_count),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'assetId', asset_id, 'eventCodes', codes, 'total', total, 'avgSyncSeconds', avg_sync_seconds
      ))
      from paged
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;
