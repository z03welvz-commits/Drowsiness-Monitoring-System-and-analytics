-- ============================================================================
-- DDS — 0087_no_operator_sentinel_emp_no
-- ----------------------------------------------------------------------------
-- MineStat ingest already detects the literal "NO OPERATOR / EQUIPMENT DOWN /
-- OR STANDBY" placeholder a real export uses for "nobody was assigned this
-- shift" (since 0024) and correctly keeps it out of the name-review queue
-- (minestat_name_review only ever gets rows where no_operator = false) — that
-- distinction between "confirmed no operator" and "a real name that failed to
-- match" already works and is not being touched here.
--
-- What it did NOT do: a confirmed no_operator row set emp_no = NULL — the
-- exact same value used for "we don't know who this was." Once that reaches
-- events via the DDS<->MineStat backfill, both cases render identically as
-- "Unspecified" everywhere in the app, so a genuinely-empty shift and an
-- attribution failure could never be told apart downstream.
--
-- Fix: give "confirmed no operator" a real, stable identity — emp_no
-- '0000000' — instead of null. A placeholder row in `drivers` gives every
-- join/display a clean "No Operator" label instead of a bare code. Because
-- dds_backfill_emp_no_from_minestat() already only backfills shifts where
-- minestat_shifts.emp_no is not null, this sentinel propagates to `events`
-- through that existing logic — no separate change needed on the DDS side.
-- ============================================================================

insert into public.drivers (emp_no, full_name, status)
values ('0000000', 'No Operator', 'active')
on conflict (emp_no) do nothing;

create or replace function public.dds_minestat_ingest(p_import_id uuid, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
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
    case when m.no_operator then '0000000' else r.emp_no end,
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
$function$;
