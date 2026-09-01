-- Driver & Asset Monitoring: per-alert-instance table + bulk-edit popup.
-- Backs the new "Emp ID / Emp Name / Event Code / Counts / Status" driver
-- table and "Asset No / Event Code / Event Counts / Avg Sync Time" asset
-- table, both of whose "Details" popup lists individual alert instances
-- (events rows) instead of the old per-entity weekly day-count summary.
--
-- alert_cases already exists (0005) as a one-row-per-event action log
-- (event_id -> action_type/status_value/remarks), which is exactly the
-- per-instance action model the new popup's bulk edit needs — it just has
-- no dedicated "action date" column yet (the closest thing, updated_at,
-- is a write-timestamp audit column, not a user-chosen effective date for
-- the action), so this migration adds one.

alter table public.alert_cases
  add column if not exists action_date date;

comment on column public.alert_cases.action_date is
  'User-chosen effective date for the logged action (e.g. "date the driver was made spare"), distinct from updated_at which is the row write-timestamp. Nullable: unset until an action is logged.';

-- alert_cases had no uniqueness on event_id (only a plain FK) even though
-- every existing reader (dds_alert_group_details, 0016) already assumes
-- at most one case row per event via a plain left join — two case rows
-- for the same event_id would silently duplicate that join's output.
-- Enforcing the 1:1 invariant here also lets the new bulk-write RPC below
-- use a real ON CONFLICT (event_id) upsert instead of a racy
-- select-then-insert-or-update.
alter table public.alert_cases
  add constraint alert_cases_event_id_key unique (event_id);

-- ---------------------------------------------------------------------
-- dds_driver_alert_instances: per-instance alert rows for one driver
-- (emp_no) within [p_from, p_to], each carrying its own alert_cases
-- action/status via the same events<->alert_cases join dds_alert_group_
-- details (0016) already uses. severity_tier is computed with the exact
-- same regex rules as the client's SEVERITY_RULES (index.html) so the
-- Status rule below and any future caller stay in lockstep with the UI's
-- own critical/high/moderate badges.
-- ---------------------------------------------------------------------
create or replace function public.dds_driver_alert_instances(
  p_emp_no text,
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  result jsonb;
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
    -- true only when every critical/high-tier instance in range already
    -- has a logged alert_cases action (status_value not null) — the
    -- "medium to high" Status rule, scoped to critical+high per the
    -- app's 3-tier severity model (no literal "medium" tier exists).
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
        'remarks',         c.remarks
      ) order by e.start_time desc, e.id desc)
      from (
        select * from public.events e2
        where coalesce(e2.emp_no, 'UNSPECIFIED') = p_emp_no
          and (p_from is null or e2.shift_date >= p_from)
          and (p_to   is null or e2.shift_date <= p_to)
        order by e2.start_time desc, e2.id desc
        limit 500
      ) e
      left join public.alert_cases c on c.event_id = e.id
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;

grant execute on function public.dds_driver_alert_instances(text, date, date) to authenticated;

-- ---------------------------------------------------------------------
-- dds_asset_alert_instances: same per-instance shape, scoped to one
-- asset_id. Read-only history for the Assets tab's popup (no bulk-edit
-- there, per product decision), plus avgSyncSeconds for the table's
-- "Avg Sync Time" column (sync_seconds is already a generated column on
-- events — see 0010/0021).
-- ---------------------------------------------------------------------
create or replace function public.dds_asset_alert_instances(
  p_asset_id text,
  p_from date default null,
  p_to date default null
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  result jsonb;
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
        limit 500
      ) e
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;

grant execute on function public.dds_asset_alert_instances(text, date, date) to authenticated;

-- ---------------------------------------------------------------------
-- dds_bulk_log_case_action: upserts alert_cases for a batch of event_ids
-- in one round trip (the popup's bulk-edit checkbox flow) instead of one
-- client round trip per row. driver_name is intentionally left untouched
-- on conflict — this endpoint only ever writes action/status fields, so
-- it can't clobber a name a human previously typed into a case via a
-- different flow.
-- ---------------------------------------------------------------------
create or replace function public.dds_bulk_log_case_action(
  p_event_ids bigint[],
  p_action_type text,
  p_action_is_other boolean,
  p_action_date date,
  p_status_value text,
  p_remarks text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_updated int;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  if p_event_ids is null or array_length(p_event_ids, 1) is null then
    raise exception 'NO_EVENT_IDS' using errcode = '22023';
  end if;

  insert into public.alert_cases (event_id, action_type, action_is_other, action_date, status_value, remarks, updated_by)
  select ev, p_action_type, coalesce(p_action_is_other, false), p_action_date, p_status_value, p_remarks, v_uid
  from unnest(p_event_ids) as ev
  on conflict (event_id) do update set
    action_type = excluded.action_type,
    action_is_other = excluded.action_is_other,
    action_date = excluded.action_date,
    status_value = excluded.status_value,
    remarks = coalesce(excluded.remarks, public.alert_cases.remarks),
    updated_by = excluded.updated_by,
    updated_at = now();

  get diagnostics v_updated = row_count;
  return jsonb_build_object('updated', v_updated);
end;
$function$;

grant execute on function public.dds_bulk_log_case_action(bigint[], text, boolean, date, text, text) to authenticated;
