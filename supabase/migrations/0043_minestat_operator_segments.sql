-- ============================================================================
-- DDS — 0043_minestat_operator_segments
-- ----------------------------------------------------------------------------
-- Bug: a real Minestat file upload failed with "ON CONFLICT DO UPDATE command
-- cannot affect row a second time". Cause: minestat_shifts' primary key is
-- (asset_id, shift_date, shift) — ONE row per asset per shift per day — but a
-- real file can have more than one row for that same key (e.g. an operator
-- handover partway through a shift). dds_minestat_ingest() inserts a whole
-- batch in one statement with `on conflict ... do update`, which Postgres
-- refuses the moment two rows in the same statement target the same existing
-- row.
--
-- Decision (confirmed with the operator of this system): two rows sharing an
-- asset+shift+day are the SAME record (e.g. a duplicate line in the source
-- file) if they name the same operator, and should collapse to one; they are
-- DIFFERENT records if they name different operators, and should both be
-- kept as separate rows.
--
-- Safety note, not a request to change: the real file has no per-operator
-- time-in/time-out, so once a shift has two distinct operators there is no
-- data in the file that says which one was driving at the moment a specific
-- DDS alert fired. dds_backfill_emp_no_from_minestat() joins events to
-- minestat_shifts on (asset_id, shift_date, shift) alone to attribute an
-- alert to a driver; left unchanged, a shift with two operators would make
-- that join match two rows and Postgres would pick one arbitrarily — a
-- silent, non-deterministic mis-attribution in a fatigue-monitoring system.
-- This migration keeps that function honest instead: it now backfills
-- emp_no only when a shift's operator is unambiguous (exactly one distinct
-- emp_no across its row(s)), and leaves an ambiguous shift's events alone
-- rather than guessing. That function is not currently called from the
-- client (grepped index.html/dds-state.js — no caller today; 0024's own
-- comment already anticipated console/manual use), so this is a latent-bug
-- fix, not a behavior change anyone is relying on right now.
-- ============================================================================

-- ── operator_key: the "same operator?" grouping key ─────────────────────────
-- Same normalization dds_minestat_ingest() already uses to build raw_name and
-- detect the "NO OPERATOR / EQUIPMENT DOWN / OR STANDBY" placeholder — pulled
-- into one immutable helper so the generated column below and the ingest
-- RPC's own dedup step can never drift apart from each other.
create or replace function public.dds_minestat_operator_key(
  p_last_name   text,
  p_first_name  text,
  p_middle_name text
) returns text
language sql immutable parallel safe
set search_path = public
as $$
  select case
    when upper(coalesce(p_last_name, ''))   = 'NO OPERATOR'
     and upper(coalesce(p_first_name, ''))  = 'EQUIPMENT DOWN'
     and upper(coalesce(p_middle_name, '')) = 'OR STANDBY'
    then '__no_operator__'
    else coalesce(
      public.dds_norm_name(
        coalesce(p_last_name, '') || ', ' ||
        trim(coalesce(p_first_name, '') || ' ' || coalesce(p_middle_name, ''))
      ),
      ''
    )
  end
$$;

revoke all on function public.dds_minestat_operator_key(text, text, text) from public, anon;
grant execute on function public.dds_minestat_operator_key(text, text, text) to authenticated;

-- ── Widen minestat_shifts' identity to (asset_id, shift_date, shift, operator) ─
-- A STORED generated column so it's always in sync with last/first/middle
-- name — including for any future direct UPDATE, not just ingest. Postgres
-- computes it for every existing row as part of this ALTER (a full table
-- rewrite — expect a brief lock proportional to minestat_shifts' size; run
-- this during a quiet window on a large table).
alter table public.minestat_shifts
  drop constraint if exists minestat_shifts_pkey;

alter table public.minestat_shifts
  add column if not exists operator_key text
    generated always as (
      public.dds_minestat_operator_key(last_name, first_name, middle_name)
    ) stored;

alter table public.minestat_shifts
  add primary key (asset_id, shift_date, shift, operator_key);

-- ── dds_minestat_ingest(): dedupe by the new key before inserting ───────────
-- Same "distinct on ... order by ord desc" last-row-wins pattern
-- dds_upsert_drivers() (0018) already uses for its own duplicate-emp_no
-- problem — collapses same-operator repeats within one file/batch so the
-- ON CONFLICT below only ever targets a row once per statement. Rows for the
-- same asset+shift+day with a DIFFERENT operator_key are not duplicates at
-- all now and are inserted as separate rows.
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

  -- Last row (by original file position) wins for a repeated
  -- asset+shift+day+operator — the exact "same operator, keep only one"
  -- rule confirmed above.
  drop table if exists _mdeduped;
  create temporary table _mdeduped on commit drop as
  select distinct on (m.asset_id, m.shift_date, m.shift, m.operator_key) m.*
  from _mnamed m
  order by m.asset_id, m.shift_date, m.shift, m.operator_key, m.ord desc;

  -- Resolution counts stay against the UNDEDUPED rows (_mnamed): the review
  -- queue's row_count is "how many file rows named this person", which
  -- shouldn't shrink just because some of those rows collapsed into one
  -- stored shift record.
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

-- ── dds_backfill_emp_no_from_minestat(): never guess across two operators ───
-- Only difference from 0024's version: candidates now come from shifts whose
-- (asset_id, shift_date, shift) resolves to exactly ONE distinct emp_no.
-- A shift with two different operators is left alone — no time-of-day data
-- exists to say which of them was driving when a given alert fired, so an
-- unresolved emp_no here surfaces as "still needs review", not a coin flip.
create or replace function public.dds_backfill_emp_no_from_minestat(
  p_limit integer default 2000
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows      integer := 0;
  v_remaining integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with unambiguous_shifts as (
    select asset_id, shift_date, shift, max(emp_no) as emp_no
    from public.minestat_shifts
    where emp_no is not null
    group by asset_id, shift_date, shift
    having count(distinct emp_no) = 1
  ),
  candidates as (
    select e.id, u.emp_no
    from public.events e
    join unambiguous_shifts u
      on u.asset_id   = e.asset_id
     and u.shift_date = e.shift_date
     and u.shift      = e.shift
    where e.emp_no is null
    limit p_limit
  ),
  upd as (
    update public.events e
       set emp_no = c.emp_no
      from candidates c
     where e.id = c.id
    returning 1
  )
  select count(*) into v_rows from upd;

  select count(*) into v_remaining
  from public.events e
  where e.emp_no is null
    and exists (
      select 1 from public.minestat_shifts m
       where m.asset_id = e.asset_id and m.shift_date = e.shift_date
         and m.shift = e.shift and m.emp_no is not null
    );

  return jsonb_build_object('rowsUpdated', v_rows, 'rowsRemaining', v_remaining);
end;
$$;
