-- dds_driver_asset_weekly (Driver & Asset Monitoring's background risk
-- model, called on every page nav) was still ~4.9s after 0040's work_mem
-- bump alone (0040 fixed the temp-file spill — confirmed gone here, but
-- the query itself stayed slow: shared hit=5040, no temp read/written).
--
-- Root cause: drivers_out/assets_out build each entity's jsonb row with
-- THREE correlated subqueries per row (days lookup, entity_status lookup,
-- last_actions lookup) — for 416 distinct drivers + 119 distinct assets
-- (measured live), that's ~1600 independent subquery executions, each
-- re-scanning a materialized CTE Postgres has no index into. Same shape of
-- bug as dds_driver_event_summary's status_agg, fixed in 0040.
--
-- Rewritten to pre-aggregate each lookup ONCE (days as a per-entity
-- jsonb_object_agg, status and last_actions as plain LEFT JOINs keyed on
-- entity_id) and join them onto the entity list, instead of asking a
-- correlated subquery to answer "give me this one entity's slice" once per
-- entity. Same output shape, computed as three total aggregation passes
-- instead of ~1600 per-row lookups.
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
  with filtered as (
    select
      coalesce(emp_no, 'UNSPECIFIED') as driver_key,
      asset_id,
      shift_date,
      event_count
    from public.events
    where (p_from is null or shift_date >= p_from)
      and (p_to   is null or shift_date <= p_to)
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
