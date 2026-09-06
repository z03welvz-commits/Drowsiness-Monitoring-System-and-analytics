-- ============================================================================
-- DDS — 0056_ingest_resolved_rows
-- ----------------------------------------------------------------------------
-- New ingest entry points that accept ALREADY-NORMALIZED, ALREADY-RESOLVED
-- rows from the client's DDS_LINK module (index.html), instead of doing
-- timestamp parsing and name resolution here. dds_ingest()/
-- dds_minestat_ingest() (0032) are UNCHANGED and remain callable — they are
-- the fallback path for any caller that still sends raw text rows (an older
-- cached page, a direct API script, or a client bug that skipped
-- resolution), so a malformed upload degrades to "resolved server-side,
-- same as before 0056" rather than silently storing wrong or empty values.
--
-- WHAT THE CLIENT NOW SENDS PER ROW (dds_ingest_resolved)
--   asset_id, event_code, event_count   — normalized strings/number
--   start_time, update_time, end_time   — ISO 8601 timestamps (parsed once
--                                          client-side; end_time nullable)
--   operator                            — raw operator text as typed, kept
--                                          verbatim (same reasoning as
--                                          0019: the raw string is the
--                                          evidence behind any resolution
--                                          decision, never discarded)
--   emp_no                              — client-resolved employee number,
--                                          or null if unresolved
--   shift, shift_date, actionable, sync_seconds
--                                        — client-computed via the same
--                                          formulas dds_shift()/
--                                          dds_shift_date()/dds_actionable()
--                                          implement (0055 converted these
--                                          from GENERATED to plain columns
--                                          specifically so this insert can
--                                          supply them); the BEFORE trigger
--                                          added in 0055 fills any of these
--                                          the client leaves null, so an
--                                          incomplete row still lands
--                                          correctly rather than with nulls
--   tier, distance, candidates          — the client resolver's own
--                                          diagnostic output, carried
--                                          through to import_name_review
--                                          exactly as dds_ingest() already
--                                          does today, so the Name Review
--                                          queue (0054) is fed identically
--                                          regardless of which side resolved
--                                          the name
--
-- WHAT STAYS SERVER-SIDE, DELIBERATELY
--   - asset_id trim() (0032's fix — cheap, and a client bug here would
--     otherwise silently break the MineStat join with no visible symptom)
--   - the events unique-key conflict rule (on conflict do nothing) — this
--     is a DATABASE INTEGRITY guarantee, not a normalization step, and
--     must not depend on the client getting it right
--   - import_name_review population for any row whose operator text is
--     non-blank but emp_no is null — the review queue's correctness must
--     not depend on the client remembering to write it
--   - imports.row_count / unresolved_count bookkeeping
-- ============================================================================

create or replace function public.dds_ingest_resolved(
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

  -- Same review-queue population rule as dds_ingest() (0019/0032): a
  -- non-blank operator with no resolved emp_no is queued for human review;
  -- a blank operator is not (it is a known, expected gap, not a linking
  -- failure — see driverLinkLabel() in index.html).
  insert into public.import_name_review (
    import_id, raw_name, norm_name, tier, distance, candidates, row_count
  )
  select p_import_id, n.raw_name, n.norm_name, n.tier, n.distance, n.candidates, n.row_count
  from (
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
  ) n
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
$$;

revoke all on function public.dds_ingest_resolved(uuid, jsonb) from public, anon;
grant execute on function public.dds_ingest_resolved(uuid, jsonb) to authenticated;

-- Same shape for MineStat: client sends asset_id/shift_date/shift as given
-- (SHIFT_DATE is still trusted from the file, unchanged from 0032 — the
-- MineStat/DDS date-convention question 0032 raised is orthogonal to who
-- does name resolution) plus name fields, resolved emp_no, and tier/
-- distance/candidates. operator_key stays a GENERATED column (0043) — it
-- is a dedup/PK-widening mechanism over last/first/middle name, not
-- something the client computes or sends.

create or replace function public.dds_minestat_ingest_resolved(
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

  -- Same "last occurrence in the batch wins for one operator_key" pre-dedup
  -- as dds_minestat_ingest() (0043) — required because Postgres forbids one
  -- ON CONFLICT DO UPDATE statement from touching the same target row twice.
  drop table if exists _rmdeduped;
  create temporary table _rmdeduped on commit drop as
  select distinct on (m.asset_id, m.shift_date, m.shift,
                       public.dds_minestat_operator_key(m.last_name, m.first_name, m.middle_name))
    m.*
  from _rmchunk m
  order by m.asset_id, m.shift_date, m.shift,
           public.dds_minestat_operator_key(m.last_name, m.first_name, m.middle_name),
           m.ord desc;

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
        updated_at    = now();

  get diagnostics v_inserted = row_count;

  -- Review-queue population: counted against the UNDEDUPED rows, same
  -- reasoning as 0043 — "how many file rows named this person" shouldn't
  -- shrink just because same-operator-key rows collapsed into one stored
  -- shift record.
  insert into public.minestat_name_review (
    import_id, raw_name, norm_name, tier, distance, candidates, row_count
  )
  select p_import_id, n.raw_name, n.norm_name, n.tier, n.distance, n.candidates, n.row_count
  from (
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
  ) n
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
$$;

revoke all on function public.dds_minestat_ingest_resolved(uuid, jsonb) from public, anon;
grant execute on function public.dds_minestat_ingest_resolved(uuid, jsonb) to authenticated;
