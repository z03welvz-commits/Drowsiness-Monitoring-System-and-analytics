-- ============================================================================
-- DDS — 0173_spike_investigation_asset_concentration
-- ----------------------------------------------------------------------------
-- Bug found in the system-function audit: Analytics' Spike Investigation
-- panel shows "Top 5 <drivers|assets> account for X% of volume" depending
-- on which tab is active, but dds_spike_investigation() only ever computed
-- ONE concentration figure — top5Share, from `concentration`, summed over
-- driver_ranked (driver rank <= 5) — and the client (index.html ~6328)
-- reused that same number verbatim on the Assets tab. The percentage shown
-- while viewing Assets was actually the DRIVER-side concentration, mislabeled.
--
-- Adds a parallel `asset_concentration` CTE (identical shape to the
-- existing driver-side `concentration`, but ranking assets by total_count
-- instead) and a new `top5AssetShare` output field. `top5Share` is left
-- exactly as-is (still the driver-side figure, still used for the Drivers
-- tab) — purely additive, no existing field's meaning changes.
-- ============================================================================

create or replace function public.dds_spike_investigation(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
 SET work_mem TO '64MB'
AS $function$
declare
  result jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  if p_from is null or p_to is null then
    raise exception 'p_from and p_to are both required' using errcode = '22023';
  end if;

  with window_events as (
    select r.event_id, r.emp_no_norm as emp_no, r.emp_name, r.asset_id,
           r.event_code, r.event_count, r.status as status_value
    from public.dds_case_records r
    where r.shift_date >= p_from and r.shift_date <= p_to
  ),
  overall as (
    select
      count(*) as total_events,
      coalesce(sum(event_count), 0) as total_count,
      count(*) filter (where status_value is not null) as reviewed_events
    from window_events
  ),
  driver_totals as (
    select emp_no,
      coalesce(max(emp_name), case when emp_no = 'UNSPECIFIED' then 'Unspecified' else emp_no end) as name,
      sum(event_count) as total_count,
      count(*) as event_rows,
      count(*) filter (where status_value is not null) as reviewed_rows
    from window_events
    group by emp_no
  ),
  driver_codes as (
    select emp_no, jsonb_agg(jsonb_build_object('eventCode', event_code, 'count', code_count) order by code_count desc) as codes
    from (
      select emp_no, event_code, sum(event_count) as code_count
      from window_events
      group by emp_no, event_code
    ) x
    group by emp_no
  ),
  driver_last_actions as (
    select distinct on (entity_id) entity_id, action_type, action_other_text, logged_by, created_at
    from public.entity_action_log
    where entity_type = 'driver'
    order by entity_id, created_at desc
  ),
  driver_ranked as (
    select dt.emp_no, dt.name, dt.total_count, dt.event_rows, dt.reviewed_rows,
      dc.codes,
      es.status as case_status, es.monitor_until,
      dla.action_type as last_action_type, dla.action_other_text as last_action_other_text,
      dla.logged_by as last_action_by, dla.created_at as last_action_at,
      row_number() over (order by dt.total_count desc) as rn
    from driver_totals dt
    left join driver_codes dc on dc.emp_no = dt.emp_no
    left join public.entity_status es on es.entity_type = 'driver' and es.entity_id = dt.emp_no
    left join driver_last_actions dla on dla.entity_id = dt.emp_no
  ),
  top_drivers as (
    select * from driver_ranked order by total_count desc limit 15
  ),
  concentration as (
    select coalesce(sum(total_count) filter (where rn <= 5), 0) as top5_count
    from driver_ranked
  ),
  asset_totals as (
    select asset_id,
      sum(event_count) as total_count,
      count(*) as event_rows,
      count(*) filter (where status_value is not null) as reviewed_rows
    from window_events
    where asset_id is not null
    group by asset_id
  ),
  asset_codes as (
    select asset_id, jsonb_agg(jsonb_build_object('eventCode', event_code, 'count', code_count) order by code_count desc) as codes
    from (
      select asset_id, event_code, sum(event_count) as code_count
      from window_events
      where asset_id is not null
      group by asset_id, event_code
    ) x
    group by asset_id
  ),
  asset_last_actions as (
    select distinct on (entity_id) entity_id, action_type, action_other_text, logged_by, created_at
    from public.entity_action_log
    where entity_type = 'asset'
    order by entity_id, created_at desc
  ),
  asset_ranked as (
    select at2.asset_id, at2.total_count, at2.event_rows, at2.reviewed_rows,
      ac.codes,
      es.status as case_status, es.monitor_until,
      ala.action_type as last_action_type, ala.action_other_text as last_action_other_text,
      ala.logged_by as last_action_by, ala.created_at as last_action_at,
      row_number() over (order by at2.total_count desc) as rn
    from asset_totals at2
    left join asset_codes ac on ac.asset_id = at2.asset_id
    left join public.entity_status es on es.entity_type = 'asset' and es.entity_id = at2.asset_id
    left join asset_last_actions ala on ala.entity_id = at2.asset_id
  ),
  top_assets as (
    select * from asset_ranked order by total_count desc limit 15
  ),
  asset_concentration as (
    select coalesce(sum(total_count) filter (where rn <= 5), 0) as top5_count
    from asset_ranked
  )
  select jsonb_build_object(
    'from', to_char(p_from, 'YYYY-MM-DD'),
    'to', to_char(p_to, 'YYYY-MM-DD'),
    'totalEvents', (select total_events from overall),
    'totalCount', (select total_count from overall),
    'reviewedEvents', (select reviewed_events from overall),
    'top5Share', case when (select total_count from overall) > 0
      then round((select top5_count from concentration)::numeric / (select total_count from overall) * 100, 1)
      else null end,
    'top5AssetShare', case when (select total_count from overall) > 0
      then round((select top5_count from asset_concentration)::numeric / (select total_count from overall) * 100, 1)
      else null end,
    'drivers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'empNo', emp_no, 'name', name, 'total', total_count,
        'eventCodes', codes,
        'reviewedEvents', reviewed_rows, 'totalEvents', event_rows,
        'caseStatus', case
          when case_status = 'monitoring' then
            case when monitor_until is not null and monitor_until >= current_date then 'monitoring' else 'resolved' end
          when case_status = 'actioned' then 'actioned'
          else null
        end,
        'monitorUntil', to_char(monitor_until, 'YYYY-MM-DD'),
        'lastAction', case when last_action_type is null then null else jsonb_build_object(
          'type', last_action_type, 'otherText', last_action_other_text, 'by', last_action_by,
          'at', to_char(last_action_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z')
        ) end
      ) order by total_count desc)
      from top_drivers
    ), '[]'::jsonb),
    'assets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'assetId', asset_id, 'total', total_count,
        'eventCodes', codes,
        'reviewedEvents', reviewed_rows, 'totalEvents', event_rows,
        'caseStatus', case
          when case_status = 'monitoring' then
            case when monitor_until is not null and monitor_until >= current_date then 'monitoring' else 'resolved' end
          when case_status = 'actioned' then 'actioned'
          else null
        end,
        'monitorUntil', to_char(monitor_until, 'YYYY-MM-DD'),
        'lastAction', case when last_action_type is null then null else jsonb_build_object(
          'type', last_action_type, 'otherText', last_action_other_text, 'by', last_action_by,
          'at', to_char(last_action_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z')
        ) end
      ) order by total_count desc)
      from top_assets
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;
