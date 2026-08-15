-- ============================================================================
-- DDS — 0008_driver_asset_actions_latest
-- ----------------------------------------------------------------------------
-- The Driver & Asset Monitoring table needs a "Last Action" column across
-- every row at once (up to however many distinct drivers/units are in the
-- filtered set) — calling dds_entity_actions() once per row would be an N+1
-- round trip for a table that can have dozens of rows. This adds one bulk
-- lookup instead: the single most recent action per distinct entity_id of
-- the given type, in one query.
-- ============================================================================

create or replace function public.dds_latest_entity_actions(
  p_entity_type text
)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(jsonb_object_agg(entity_id, row), '{}'::jsonb)
  from (
    select distinct on (entity_id)
      entity_id,
      jsonb_build_object(
        'actionType', action_type,
        'actionIsOther', action_is_other,
        'source', source,
        'actorUsername', actor_username,
        'createdAt', to_char(created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
      ) as row
    from public.driver_asset_actions
    where entity_type = p_entity_type
    order by entity_id, created_at desc
  ) latest;
$$;

revoke all on function public.dds_latest_entity_actions from public;
grant execute on function public.dds_latest_entity_actions to authenticated;
