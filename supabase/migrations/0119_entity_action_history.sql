-- ============================================================================
-- DDS — 0119_entity_action_history
-- ----------------------------------------------------------------------------
-- entity_action_log has RLS enabled with zero policies defined, so it is
-- fully inaccessible to a direct client-side select (RLS with no policy
-- means no rows, not an error) — the same reason writes to it already go
-- through a security-definer RPC (dds_log_entity_action). dds_driver_
-- streaks() only ever surfaced the single latest entry per entity
-- (lastAction); this adds the full history list for the Driver Streaks
-- detail panel's new Action History section.
-- ============================================================================
create or replace function public.dds_entity_action_history(
  p_entity_type text,
  p_entity_id   text,
  p_limit       integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  result jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'actionType', action_type,
    'actionOtherText', action_other_text,
    'note', note,
    'loggedBy', logged_by,
    'at', to_char(created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  ) order by created_at desc), '[]'::jsonb)
  into result
  from (
    select action_type, action_other_text, note, logged_by, created_at
    from public.entity_action_log
    where entity_type = p_entity_type and entity_id = p_entity_id
    order by created_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
  ) x;

  return result;
end;
$function$;
