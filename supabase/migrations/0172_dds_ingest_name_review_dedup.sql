-- ============================================================================
-- DDS — 0172_dds_ingest_name_review_dedup
-- ----------------------------------------------------------------------------
-- Same Name Review backlog double-booking bug as 0171, this time in
-- dds_ingest_resolved() (current live def confirmed via
-- pg_get_functiondef() immediately before writing this migration).
--
-- dds_ingest_resolved()'s own events insert already uses
-- `on conflict (...) do NOTHING`, so it has no row_count-inflation bug —
-- only the import_name_review insert needs the fix. Same root cause as
-- 0171: `on conflict (import_id, norm_name)` can't recognize "this name
-- is already awaiting review" across two different imports (a fresh
-- p_import_id every upload), or even across chunks of the SAME upload
-- once the first chunk's row exists — so a re-upload/re-chunk containing
-- a still-unresolved operator name opens a second, separate open review
-- row for the same physical name instead of adding to the existing one.
--
-- Fixed identically to 0171: merge into any EXISTING OPEN row for the
-- same norm_name first (regardless of which import created it), only
-- insert for names with no open match. import_id itself is deliberately
-- left untouched on merge, same as 0171.
--
-- No signature change, no behavior change to the events upsert itself.
-- ============================================================================

create or replace function public.dds_ingest_resolved(p_import_id uuid, p_rows jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_inserted integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  perform public.dds_require_edit_lock();
  if not exists (select 1 from public.imports where id = p_import_id) then
    raise exception 'UNKNOWN_IMPORT';
  end if;

  drop table if exists _rchunk;
  create temporary table _rchunk on commit drop as
  select
    (r->>'start_time')::timestamp  as start_time,
    (r->>'update_time')::timestamp as update_time,
    case when nullif(r->>'end_time', '') is not null
      then (r->>'end_time')::timestamp end as end_time,
    trim(r->>'asset_id')           as asset_id,
    r->>'event_code'               as event_code,
    coalesce((r->>'event_count')::integer, 0) as event_count,
    nullif(r->>'operator', '')     as operator,
    nullif(r->>'emp_no', '')       as emp_no,
    nullif(r->>'shift', '')        as shift,
    case when nullif(r->>'shift_date', '') is not null
      then (r->>'shift_date')::date end as shift_date,
    (r->>'actionable')::boolean    as actionable,
    (r->>'sync_seconds')::integer  as sync_seconds,
    nullif(r->>'tier', '')         as tier,
    (r->>'distance')::integer      as distance,
    coalesce(r->'candidates', '[]'::jsonb) as candidates
  from jsonb_array_elements(p_rows) r;

  insert into public.events (
    import_id, update_time, start_time, end_time,
    asset_id, event_code, event_count, operator, emp_no,
    shift, shift_date, actionable, sync_seconds
  )
  select
    p_import_id, c.update_time, c.start_time, c.end_time,
    c.asset_id, c.event_code, c.event_count, c.operator, c.emp_no,
    c.shift, c.shift_date, c.actionable, c.sync_seconds
  from _rchunk c
  on conflict (asset_id, start_time, event_code) do nothing;

  get diagnostics v_inserted = row_count;

  with grouped as (
    select public.dds_norm_name(c.operator) as norm_name,
           min(c.operator)   as raw_name,
           min(c.tier)       as tier,
           min(c.distance)   as distance,
           (array_agg(c.candidates order by c.ord))[1] as candidates,
           count(*)::integer as row_count
    from (
      select *, row_number() over () as ord from _rchunk
    ) c
    where c.emp_no is null
      and c.operator is not null
      and public.dds_norm_name(c.operator) is not null
    group by public.dds_norm_name(c.operator)
  ),
  merged as (
    update public.import_name_review r
       set row_count  = r.row_count + g.row_count,
           candidates = g.candidates,
           tier       = g.tier,
           distance   = g.distance
      from grouped g
     where r.norm_name = g.norm_name
       and r.state = 'open'
    returning r.norm_name
  )
  insert into public.import_name_review (
    import_id, raw_name, norm_name, tier, distance, candidates, row_count
  )
  select p_import_id, g.raw_name, g.norm_name, g.tier, g.distance, g.candidates, g.row_count
  from grouped g
  where g.norm_name not in (select norm_name from merged)
  on conflict (import_id, norm_name) do update
    set row_count  = public.import_name_review.row_count + excluded.row_count,
        candidates = excluded.candidates,
        tier       = excluded.tier,
        distance   = excluded.distance;

  update public.imports
     set row_count = row_count + v_inserted,
         unresolved_count = (
           select coalesce(sum(row_count), 0) from public.import_name_review
            where import_id = p_import_id and state = 'open'
         ),
         status = 'processing'
   where id = p_import_id;

  return v_inserted;
end;
$function$;
