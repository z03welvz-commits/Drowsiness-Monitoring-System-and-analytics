-- ============================================================================
-- DDS — 0067_fix_minestat_ingest_dropped_columns
-- ----------------------------------------------------------------------------
-- CRITICAL FIX: dds_minestat_ingest_resolved() (0056) was never updated
-- after 0061 dropped minestat_shifts.operating_hrs/down_hrs/delay_hrs/
-- standby_hrs/total_hrs as confirmed-unused columns. The function still
-- tries to INSERT into those 5 dropped columns on every call — meaning
-- every MineStat file upload AND the MineStat Manual Add Record form have
-- been failing outright since 0061 was applied, with no caller having
-- actually exercised the path until now (found while fixing an unrelated
-- Data Management UI issue — the MineStat manual-add form's fields not
-- matching the real file header — and cross-checking the RPC body before
-- touching the JS payload it's built from).
--
-- Fix: same function, same signature, minus the 5 dropped columns from
-- both the parse step and the INSERT/UPDATE. Everything else (dedup,
-- operator_key conflict target, no_operator sentinel handling, review
-- queue population) is untouched.
-- ============================================================================

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
    emp_no, tier, distance, candidates, import_id, updated_at
  )
  select
    m.asset_id, m.shift_date, m.shift, m.last_name, m.first_name, m.middle_name,
    case when m.no_operator then null else m.emp_no end,
    case when m.no_operator then 'no_operator' else m.tier end,
    m.distance, m.candidates,
    p_import_id, now()
  from _rmdeduped m
  on conflict (asset_id, shift_date, shift, operator_key) do update
    set last_name     = excluded.last_name,
        first_name    = excluded.first_name,
        middle_name   = excluded.middle_name,
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

revoke all on function public.dds_minestat_ingest_resolved(uuid, jsonb) from public, anon;
grant execute on function public.dds_minestat_ingest_resolved(uuid, jsonb) to authenticated;
