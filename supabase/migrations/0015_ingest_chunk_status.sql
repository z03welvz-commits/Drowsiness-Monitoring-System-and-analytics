-- ============================================================================
-- DDS — 0015_ingest_chunk_status
-- ----------------------------------------------------------------------------
-- dds_ingest() marked the import row `status='complete'` on EVERY call.
--
-- That was correct when the client sent an entire import in one RPC, but the
-- client now uploads in 2,000-row chunks (one RPC per chunk), so the FIRST
-- chunk flips the import to 'complete' and every later chunk re-affirms it.
-- An import that dies on chunk 2 of 25 is left permanently recorded as
-- finished, with row_count showing only the rows that happened to land.
--
-- Observed exactly that on the live project: an import row read
-- status='complete', row_count=2000, while the client had 45,000 rows and had
-- actually failed on chunk 2 (401 from a mid-upload token refresh — see
-- Cloud.ingest()'s comment in index.html for that diagnosis). Anyone reading
-- the imports table would conclude the import succeeded.
--
-- The function cannot tell on its own which chunk is the last one — it only
-- ever sees one slice. So completion becomes an explicit decision:
--
--   * dds_ingest() now leaves status at 'processing' and only accumulates
--     row_count. It no longer claims completion it cannot verify.
--   * dds_complete_import() is called once by the client after the final
--     chunk succeeds, and is the only thing that sets 'complete'.
--   * dds_fail_import() records a failure, so a dead import is visibly
--     failed rather than silently stuck mid-flight.
--
-- An import interrupted by a closed tab now stays 'processing' rather than
-- masquerading as complete — an honest state that a later cleanup pass (or a
-- human) can act on. That is strictly better than a false 'complete'.
--
-- row_count semantics are unchanged: still cumulative across chunks, still
-- counting only rows actually inserted (dds_ingest's `on conflict do nothing`
-- means re-sent duplicates add 0), so a retry cannot inflate it.
-- ============================================================================

create or replace function public.dds_ingest(
  p_import_id uuid,
  p_rows      jsonb
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inserted integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  if not exists (select 1 from public.imports where id = p_import_id) then
    raise exception 'UNKNOWN_IMPORT';
  end if;

  insert into public.events (
    import_id, update_time, start_time, end_time,
    asset_id, event_code, event_count, operator
  )
  select
    p_import_id,
    to_timestamp(r->>'UPDATE_TIME', 'MM/DD/YYYY HH24:MI:SS')::timestamp,
    to_timestamp(r->>'START_TIME',  'MM/DD/YYYY HH24:MI:SS')::timestamp,
    case when nullif(r->>'END_TIME', '') is not null
      then to_timestamp(r->>'END_TIME', 'MM/DD/YYYY HH24:MI:SS')::timestamp end,
    r->>'ASSET_ID',
    r->>'EVENT_CODE',
    coalesce((r->>'EVENT_COUNT')::integer, 0),
    nullif(r->>'OPERATOR', '')
  from jsonb_array_elements(p_rows) r
  on conflict (asset_id, start_time, event_code) do nothing;

  get diagnostics v_inserted = row_count;

  -- Accumulate only. Completion is dds_complete_import()'s job: this
  -- function sees one chunk and cannot know whether it is the last.
  update public.imports
     set row_count = row_count + v_inserted,
         status = 'processing'
   where id = p_import_id;

  return v_inserted;
end;
$$;

revoke all on function public.dds_ingest from public;
grant execute on function public.dds_ingest to authenticated;

-- ── Explicit completion ────────────────────────────────────────────────────
-- Called once after the final chunk lands. Separate from dds_ingest() so that
-- "every row arrived" is asserted by the only party that knows it — the
-- client that holds the full row set.

create or replace function public.dds_complete_import(p_import_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  update public.imports
     set status = 'complete',
         completed_at = now(),
         error = null
   where id = p_import_id;
end;
$$;

revoke all on function public.dds_complete_import from public;
revoke all on function public.dds_complete_import from anon;
grant execute on function public.dds_complete_import to authenticated;

-- ── Explicit failure ───────────────────────────────────────────────────────
-- A failed import should say so. p_error is a SHORT, already-sanitised
-- reason from the client (see syncToCloud()'s "never surface the raw
-- Postgres/Supabase error" rule) — truncated here as defence in depth so a
-- stack trace or SQL fragment cannot be parked in the table by a caller that
-- ignores that rule.

create or replace function public.dds_fail_import(
  p_import_id uuid,
  p_error     text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  update public.imports
     set status = 'failed',
         error  = left(coalesce(p_error, 'Sync failed'), 200)
   where id = p_import_id;
end;
$$;

revoke all on function public.dds_fail_import from public;
revoke all on function public.dds_fail_import from anon;
grant execute on function public.dds_fail_import to authenticated;
