-- ============================================================================
-- DDS — 0171_minestat_ingest_count_and_dedup
-- ----------------------------------------------------------------------------
-- Two bugs found in the system-function audit, both in
-- dds_minestat_ingest_resolved() (current live def confirmed via
-- pg_get_functiondef() immediately before writing this migration —
-- matches 0151's, unchanged since):
--
-- 1. Reported "Records" count is inflated on any re-upload or date-
--    overlapping upload (i.e. almost any real-world re-export). The
--    minestat_shifts insert uses `on conflict (...) do UPDATE` (not DO
--    NOTHING, unlike DDS's own events insert), then
--    `get diagnostics v_inserted = row_count` — in Postgres this counts
--    every source row PROCESSED (inserted OR updated), not just genuinely
--    new ones. Live proof: the same "Consolidated_Mine_Stat.xlsx" export,
--    uploaded repeatedly across several days, had its reported row_count
--    climb 2376 -> 2639 -> 2932 -> 3043 -> 3357 -> 4060 -> 4060 -> 4981 —
--    a cumulative export necessarily re-includes prior days' already-
--    ingested shifts every time, yet every upload's "Records" column
--    reported the file's WHOLE size, not the actual new-row delta.
--    Fixed via the standard `RETURNING (xmax = 0)` idiom (verified live
--    against a throwaway temp table before use here) to count only rows
--    that were genuinely inserted, not updated.
--
-- 2. The Name Review backlog can double-book on the same re-upload
--    pattern. The import_name_review-style insert's `on conflict
--    (import_id, norm_name)` can never recognize "this name is already
--    awaiting review" across two different uploads, because p_import_id
--    is a fresh UUID every upload (insertImportRow() has no same-file/
--    same-date-range guard) — so a re-upload (or a chunk within the SAME
--    upload — this RPC is called once per DDS_INGEST_CHUNK-sized batch,
--    all sharing one p_import_id) that still contains an unresolved
--    operator name opens a SECOND, separate open review row for the same
--    physical name instead of adding to the existing one. Fixed by first
--    merging into any EXISTING OPEN row for the same norm_name
--    (regardless of which import created it), and only inserting for
--    names that had no open match — this also naturally covers the
--    multi-chunk-same-import case, since by the second chunk the first
--    chunk's row already exists and is open.
--
-- No signature change, no behavior change to the underlying
-- minestat_shifts upsert itself (still updates existing rows exactly as
-- before) — only what gets COUNTED/deduped changes.
-- ============================================================================

create or replace function public.dds_minestat_ingest_resolved(p_import_id uuid, p_rows jsonb)
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

  drop table if exists _rmchunk;
  create temporary table _rmchunk on commit drop as
  select
    trim(r->>'asset_id')                as asset_id,
    (r->>'shift_date')::date            as shift_date,
    upper(trim(r->>'shift'))            as shift,
    nullif(trim(r->>'last_name'), '')   as last_name,
    nullif(trim(r->>'first_name'), '')  as first_name,
    nullif(trim(r->>'middle_name'), '') as middle_name,
    coalesce((r->>'operating_hrs')::numeric, 0) as operating_hrs,
    coalesce((r->>'down_hrs')::numeric, 0)      as down_hrs,
    coalesce((r->>'delay_hrs')::numeric, 0)     as delay_hrs,
    coalesce((r->>'standby_hrs')::numeric, 0)   as standby_hrs,
    coalesce((r->>'total_hrs')::numeric, 0)     as total_hrs,
    nullif(r->>'emp_no', '')            as emp_no,
    nullif(r->>'tier', '')              as tier,
    (r->>'distance')::integer           as distance,
    coalesce(r->'candidates', '[]'::jsonb) as candidates,
    (upper(coalesce(nullif(trim(r->>'last_name'), ''), ''))   = 'NO OPERATOR'
     and upper(coalesce(nullif(trim(r->>'first_name'), ''), '')) = 'EQUIPMENT DOWN'
     and upper(coalesce(nullif(trim(r->>'middle_name'), ''), '')) = 'OR STANDBY') as no_operator,
    row_number() over () as ord
  from jsonb_array_elements(p_rows) r;

  drop table if exists _rmdeduped;
  create temporary table _rmdeduped on commit drop as
  select distinct on (m.asset_id, m.shift_date, m.shift,
                       public.dds_minestat_operator_key(m.last_name, m.first_name, m.middle_name))
    m.*
  from _rmchunk m
  order by m.asset_id, m.shift_date, m.shift,
           public.dds_minestat_operator_key(m.last_name, m.first_name, m.middle_name),
           m.ord desc;

  with ins as (
    insert into public.minestat_shifts (
      asset_id, shift_date, shift, last_name, first_name, middle_name,
      operating_hrs, down_hrs, delay_hrs, standby_hrs, total_hrs,
      emp_no, tier, distance, candidates, import_id, updated_at
    )
    select
      m.asset_id, m.shift_date, m.shift, m.last_name, m.first_name, m.middle_name,
      m.operating_hrs, m.down_hrs, m.delay_hrs, m.standby_hrs, m.total_hrs,
      case when m.no_operator then null else m.emp_no end,
      case when m.no_operator then 'no_operator' else m.tier end,
      m.distance, m.candidates,
      p_import_id, now()
    from _rmdeduped m
    on conflict (asset_id, shift_date, shift, operator_key) do update
      set last_name     = excluded.last_name,
          first_name    = excluded.first_name,
          middle_name   = excluded.middle_name,
          operating_hrs = excluded.operating_hrs,
          down_hrs      = excluded.down_hrs,
          delay_hrs     = excluded.delay_hrs,
          standby_hrs   = excluded.standby_hrs,
          total_hrs     = excluded.total_hrs,
          emp_no        = excluded.emp_no,
          tier          = excluded.tier,
          distance      = excluded.distance,
          candidates    = excluded.candidates,
          import_id     = excluded.import_id,
          updated_at    = now()
    returning (xmax = 0) as is_new
  )
  select count(*) filter (where is_new) into v_inserted from ins;

  with grouped as (
    select public.dds_norm_name(
             coalesce(m.last_name, '') || ', ' ||
             trim(coalesce(m.first_name, '') || ' ' || coalesce(m.middle_name, ''))
           ) as norm_name,
           min(coalesce(m.last_name, '') || ', ' ||
               trim(coalesce(m.first_name, '') || ' ' || coalesce(m.middle_name, ''))) as raw_name,
           min(m.tier)       as tier,
           min(m.distance)   as distance,
           (array_agg(m.candidates order by m.ord))[1] as candidates,
           count(*)::integer as row_count
    from _rmchunk m
    where m.no_operator = false
      and m.emp_no is null
      and public.dds_norm_name(
            coalesce(m.last_name, '') || ', ' ||
            trim(coalesce(m.first_name, '') || ' ' || coalesce(m.middle_name, ''))
          ) is not null
    group by public.dds_norm_name(
               coalesce(m.last_name, '') || ', ' ||
               trim(coalesce(m.first_name, '') || ' ' || coalesce(m.middle_name, ''))
             )
  ),
  merged as (
    update public.minestat_name_review r
       set row_count  = r.row_count + g.row_count,
           candidates = g.candidates,
           tier       = g.tier,
           distance   = g.distance
      from grouped g
     where r.norm_name = g.norm_name
       and r.state = 'open'
    returning r.norm_name
  )
  insert into public.minestat_name_review (
    import_id, raw_name, norm_name, tier, distance, candidates, row_count
  )
  select p_import_id, g.raw_name, g.norm_name, g.tier, g.distance, g.candidates, g.row_count
  from grouped g
  where g.norm_name not in (select norm_name from merged)
  on conflict (import_id, norm_name) do update
    set row_count  = public.minestat_name_review.row_count + excluded.row_count,
        candidates = excluded.candidates,
        tier       = excluded.tier,
        distance   = excluded.distance;

  update public.imports
     set row_count = row_count + v_inserted,
         unresolved_count = (
           select coalesce(sum(row_count), 0) from public.minestat_name_review
            where import_id = p_import_id and state = 'open'
         ),
         status = 'processing'
   where id = p_import_id;

  return v_inserted;
end;
$function$;
