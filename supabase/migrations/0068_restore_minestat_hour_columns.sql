-- ============================================================================
-- DDS — 0068_restore_minestat_hour_columns
-- ----------------------------------------------------------------------------
-- REVERTS part of 0061's cleanup. operating_hrs/down_hrs/delay_hrs/
-- standby_hrs/total_hrs were dropped as "confirmed unused" based on zero
-- frontend READ path — but the user confirmed live that these are real
-- columns present in every actual MineStat file header (Unit, Date, Shift,
-- Operating, Down, Delay, Standby, Total Hour, Last Name, First Name,
-- Middle Name). "Nothing displays it" was never the same claim as "this
-- data is meaningless" — it just meant no chart/table read it back yet.
-- Dropping them silently discarded real operational data (hours worked,
-- downtime, delays) on every upload since 0061 was applied; any file
-- re-uploaded during that window already lost this data permanently for
-- those rows and can only be recovered by re-uploading the original
-- source file, not by this migration.
--
-- Same column types as the original 0024_minestat.sql definition
-- (numeric, not null default 0) — restoring exactly what existed before,
-- not inventing a new shape.
-- ============================================================================

alter table public.minestat_shifts
  add column if not exists operating_hrs numeric not null default 0,
  add column if not exists down_hrs      numeric not null default 0,
  add column if not exists delay_hrs     numeric not null default 0,
  add column if not exists standby_hrs   numeric not null default 0,
  add column if not exists total_hrs     numeric not null default 0;

-- ── dds_minestat_ingest_resolved: parse + store the 5 hour fields again ──
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

-- ── dds_minestat_ingest: same restoration for the raw-text fallback path ──
create or replace function public.dds_minestat_ingest(
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

  drop table if exists _mchunk;
  create temporary table _mchunk on commit drop as
  select
    trim(r->>'UNIT')                    as asset_id,
    (r->>'SHIFT_DATE')::date            as shift_date,
    upper(trim(r->>'SHIFT'))            as shift,
    nullif(trim(r->>'LAST_NAME'), '')   as last_name,
    nullif(trim(r->>'FIRST_NAME'), '')  as first_name,
    nullif(trim(r->>'MIDDLE_NAME'), '') as middle_name,
    coalesce((r->>'OPERATING_HRS')::numeric, 0) as operating_hrs,
    coalesce((r->>'DOWN_HRS')::numeric, 0)      as down_hrs,
    coalesce((r->>'DELAY_HRS')::numeric, 0)     as delay_hrs,
    coalesce((r->>'STANDBY_HRS')::numeric, 0)   as standby_hrs,
    coalesce((r->>'TOTAL_HRS')::numeric, 0)     as total_hrs,
    ord
  from jsonb_array_elements(p_rows) with ordinality as t(r, ord);

  drop table if exists _mnamed;
  create temporary table _mnamed on commit drop as
  select c.*,
    (upper(coalesce(c.last_name, ''))   = 'NO OPERATOR'
     and upper(coalesce(c.first_name, '')) = 'EQUIPMENT DOWN'
     and upper(coalesce(c.middle_name, '')) = 'OR STANDBY') as no_operator,
    (coalesce(c.last_name, '') || ', ' ||
     trim(coalesce(c.first_name, '') || ' ' || coalesce(c.middle_name, ''))
    ) as raw_name,
    public.dds_minestat_operator_key(c.last_name, c.first_name, c.middle_name) as operator_key
  from _mchunk c;

  drop table if exists _mdeduped;
  create temporary table _mdeduped on commit drop as
  select distinct on (m.asset_id, m.shift_date, m.shift, m.operator_key) m.*
  from _mnamed m
  order by m.asset_id, m.shift_date, m.shift, m.operator_key, m.ord desc;

  drop table if exists _mresolved;
  create temporary table _mresolved on commit drop as
  select n.norm_name, n.raw_name, n.row_count,
         r.emp_no, r.tier, r.distance, r.candidates
  from (
    select public.dds_norm_name(m.raw_name) as norm_name,
           min(m.raw_name)   as raw_name,
           count(*)::integer as row_count
    from _mnamed m
    where m.no_operator = false
      and public.dds_norm_name(m.raw_name) is not null
    group by public.dds_norm_name(m.raw_name)
  ) n
  cross join lateral public.dds_resolve_name(n.raw_name) r;

  insert into public.minestat_shifts (
    asset_id, shift_date, shift, last_name, first_name, middle_name,
    operating_hrs, down_hrs, delay_hrs, standby_hrs, total_hrs,
    emp_no, tier, distance, candidates, import_id, updated_at
  )
  select
    m.asset_id, m.shift_date, m.shift, m.last_name, m.first_name, m.middle_name,
    m.operating_hrs, m.down_hrs, m.delay_hrs, m.standby_hrs, m.total_hrs,
    case when m.no_operator then null else r.emp_no end,
    case when m.no_operator then 'no_operator' else r.tier end,
    r.distance,
    coalesce(r.candidates, '[]'::jsonb),
    p_import_id, now()
  from _mdeduped m
  left join _mresolved r on r.norm_name = public.dds_norm_name(m.raw_name)
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

  insert into public.minestat_name_review (
    import_id, raw_name, norm_name, tier, distance, candidates, row_count
  )
  select p_import_id, r.raw_name, r.norm_name, r.tier, r.distance,
         coalesce(r.candidates, '[]'::jsonb), r.row_count
  from _mresolved r
  where r.emp_no is null
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
