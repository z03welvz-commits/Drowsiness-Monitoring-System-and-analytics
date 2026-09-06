-- ============================================================================
-- DDS — 0057_update_event_resolved
-- ----------------------------------------------------------------------------
-- CORRECTNESS FIX, not a new feature: 0050's dds_update_event() explicitly
-- relied on shift/shift_date/actionable/sync_seconds being GENERATED ALWAYS
-- columns ("Postgres recomputes them automatically on any UPDATE") — true
-- when 0050 shipped, no longer true after 0055 converted those columns to
-- plain columns so the client could populate them directly. Without this
-- fix, editing a DDS row's timestamps via Data Management's Edit modal would
-- silently leave shift/shift_date/actionable/sync_seconds holding whatever
-- value the ORIGINAL (pre-edit) timestamps produced — visibly wrong in
-- Alert Logs, Overview, and every RPC that groups by shift_date.
--
-- Also fixes a pre-existing gap 0050 never addressed: dds_update_event()
-- never touched emp_no even when p_operator changed, so editing a row's
-- driver name left the OLD resolved emp_no in place, attributing the
-- edited alert to the wrong (or no) employee. This RPC accepts a
-- client-resolved emp_no/tier/distance/candidates for the new operator
-- text, same as dds_ingest_resolved() (0056), and updates
-- import_name_review the same way ingest does when the new operator text
-- is non-blank but still unresolved.
--
-- dds_update_event() (0050) is left in place, unchanged, as a fallback for
-- any caller still sending the old (no shift/emp_no) signature — it will
-- now rely on 0055's BEFORE trigger to fill shift/shift_date/actionable/
-- sync_seconds (since they're no longer GENERATED, the trigger is what
-- fills them when the caller leaves them null), so it still produces a
-- self-consistent row, just without client-side name resolution.
-- ============================================================================

create or replace function public.dds_update_event_resolved(
  p_event_id     bigint,
  p_start_time   timestamp,
  p_end_time     timestamp default null,
  p_update_time  timestamp default null,
  p_asset_id     text default null,
  p_event_code   text default null,
  p_event_count  integer default null,
  p_operator     text default null,
  p_emp_no       text default null,
  p_shift        text default null,
  p_shift_date   date default null,
  p_actionable   boolean default null,
  p_sync_seconds integer default null,
  p_tier         text default null,
  p_distance     integer default null,
  p_candidates   jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_asset_id      text;
  v_event_code    text;
  v_event_count   integer;
  v_update_time   timestamp;
  v_operator      text;
  v_import_id     uuid;
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
  v_update_time := coalesce(p_update_time, p_start_time);
  v_operator := nullif(trim(coalesce(p_operator, '')), '');

  select import_id into v_import_id from public.events where id = p_event_id;

  update public.events
     set start_time   = p_start_time,
         end_time      = p_end_time,
         update_time   = v_update_time,
         asset_id      = v_asset_id,
         event_code    = v_event_code,
         event_count   = v_event_count,
         operator      = v_operator,
         emp_no        = p_emp_no,
         shift         = p_shift,
         shift_date    = p_shift_date,
         actionable    = p_actionable,
         sync_seconds  = p_sync_seconds
   where id = p_event_id;

  -- Same review-queue rule as ingest: a non-blank operator with no
  -- resolved emp_no is queued for review, scoped to the row's own import
  -- (or left unscoped if the row predates emp_no/imports, in which case
  -- import_id is null and the row simply isn't queued — matching how a
  -- manually-added row with no import context already behaves elsewhere).
  if v_operator is not null and p_emp_no is null and v_import_id is not null
     and public.dds_norm_name(v_operator) is not null then
    insert into public.import_name_review (
      import_id, raw_name, norm_name, tier, distance, candidates, row_count
    )
    values (
      v_import_id, v_operator, public.dds_norm_name(v_operator),
      coalesce(p_tier, 'none'), p_distance, coalesce(p_candidates, '[]'::jsonb), 1
    )
    on conflict (import_id, norm_name) do update
      set row_count  = public.import_name_review.row_count + 1,
          candidates = excluded.candidates,
          tier       = excluded.tier,
          distance   = excluded.distance;

    perform public.dds_refresh_unresolved_counts();
  end if;

  return jsonb_build_object('updated', 1);
exception
  when unique_violation then
    raise exception 'DUPLICATE_EVENT' using errcode = '23505',
      message = 'Another event already exists with this asset, start time, and event code.';
end;
$$;

revoke all on function public.dds_update_event_resolved(
  bigint, timestamp, timestamp, timestamp, text, text, integer, text,
  text, text, date, boolean, integer, text, integer, jsonb
) from public, anon;
grant execute on function public.dds_update_event_resolved(
  bigint, timestamp, timestamp, timestamp, text, text, integer, text,
  text, text, date, boolean, integer, text, integer, jsonb
) to authenticated;
