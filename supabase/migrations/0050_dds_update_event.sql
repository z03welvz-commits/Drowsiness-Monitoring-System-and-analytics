-- ============================================================================
-- DDS — 0050_dds_update_event
-- ----------------------------------------------------------------------------
-- Data Management's DDS Data table has drawn an Edit button on every row
-- since it was built, hard-disabled with "Editing not available yet" — a
-- real gap flagged in the code-correctness audit (the UI promises editing
-- and refuses it). There was no RPC to back it: every existing write path
-- into `events` is either bulk ingest (dds_ingest) or a narrow emp_no-only
-- backfill, nothing that lets an operator correct one row's own fields
-- after the fact (a typo'd asset ID, a wrong event code, a bad timestamp).
--
-- Safe to add: shift/shift_date/actionable/sync_seconds are all GENERATED
-- ALWAYS ... STORED columns (0001_init.sql) — Postgres recomputes them
-- automatically on any UPDATE to the base columns they derive from, so
-- there is no way for this RPC to leave them stale. The one real
-- constraint is uq_events_natural (asset_id, start_time, event_code) —
-- editing a row into another existing row's identity raises a normal,
-- catchable unique-violation, not silent data corruption.
-- ============================================================================

create or replace function public.dds_update_event(
  p_event_id   bigint,
  p_start_time timestamp,
  p_end_time   timestamp default null,
  p_update_time timestamp default null,
  p_asset_id   text default null,
  p_event_code text default null,
  p_event_count integer default null,
  p_operator   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_asset_id text;
  v_event_code text;
  v_event_count integer;
  v_update_time timestamp;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  if not exists (select 1 from public.events where id = p_event_id) then
    raise exception 'EVENT_NOT_FOUND' using errcode = '22023';
  end if;
  if p_start_time is null then
    raise exception 'START_TIME_REQUIRED' using errcode = '22023';
  end if;

  v_asset_id := nullif(trim(coalesce(p_asset_id, '')), '');
  v_event_code := nullif(trim(coalesce(p_event_code, '')), '');
  if v_asset_id is null then
    raise exception 'ASSET_ID_REQUIRED' using errcode = '22023';
  end if;
  if v_event_code is null then
    raise exception 'EVENT_CODE_REQUIRED' using errcode = '22023';
  end if;
  v_event_count := greatest(coalesce(p_event_count, 0), 0);
  -- update_time defaults to start_time (matches the client's own Add
  -- Record modal, which pre-fills Update Time from Start Time when the
  -- user leaves it blank) rather than being left null, since downstream
  -- consumers (dds_actionable(), Alert Logs' Update Time column) expect it.
  v_update_time := coalesce(p_update_time, p_start_time);

  update public.events
     set start_time  = p_start_time,
         end_time     = p_end_time,
         update_time  = v_update_time,
         asset_id     = v_asset_id,
         event_code   = v_event_code,
         event_count  = v_event_count,
         operator     = nullif(trim(coalesce(p_operator, '')), '')
   where id = p_event_id;

  return jsonb_build_object('updated', 1);
exception
  when unique_violation then
    raise exception 'DUPLICATE_EVENT' using errcode = '23505',
      message = 'Another event already exists with this asset, start time, and event code.';
end;
$$;

revoke all on function public.dds_update_event(bigint, timestamp, timestamp, timestamp, text, text, integer, text) from public, anon;
grant execute on function public.dds_update_event(bigint, timestamp, timestamp, timestamp, text, text, integer, text) to authenticated;
