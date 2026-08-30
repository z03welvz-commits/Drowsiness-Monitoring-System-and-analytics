-- ============================================================================
-- DDS — 0032_attribution_audit_fixes
-- ----------------------------------------------------------------------------
-- Fixes three gaps found in a full audit of the three-source driver
-- attribution pipeline (masterlist / MineStat / DDS alerts): asset_id
-- normalization asymmetry, an unverified assumption that MineStat's own
-- shift-date convention agrees with DDS's, and a silent, unloggable
-- disagreement between OPERATOR-text resolution and the MineStat join.
-- ============================================================================

-- ── 1. asset_id normalization ───────────────────────────────────────────────
-- MineStat's CLIENT trims UNIT before upload (index.html's parseMinestatRows);
-- DDS's client did not trim ASSET_ID at all until this same audit's client
-- fix (toCanonical()). Neither ingest function re-trimmed defensively at the
-- SQL layer, so the join dds_backfill_emp_no_from_minestat() relies on —
-- exact equality on (asset_id, shift_date, shift) — could silently fail to
-- match a DDS row against an otherwise-identical MineStat row over nothing
-- more than a stray leading/trailing space in a spreadsheet cell. Trimming
-- here, not just client-side, means the join key is correct regardless of
-- which upload path (or a future one) supplies the row — the same reasoning
-- 0001_init.sql already applies to shift/shift_date being SQL-computed
-- rather than trusted from the client.
--
-- Deliberately trim-only, not upper()/lower(): unlike whitespace, letter
-- case in an asset id can be a real, intentional part of a fleet's naming
-- convention (this app has no evidence either way), so folding case here
-- would risk silently changing what gets displayed for a value nobody asked
-- to have rewritten. Trimming whitespace carries no such risk — no fleet
-- convention depends on a leading space being meaningful.

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

  drop table if exists _chunk;
  create temporary table _chunk on commit drop as
  select
    to_timestamp(r->>'UPDATE_TIME', 'MM/DD/YYYY HH24:MI:SS')::timestamp as update_time,
    to_timestamp(r->>'START_TIME',  'MM/DD/YYYY HH24:MI:SS')::timestamp as start_time,
    case when nullif(r->>'END_TIME', '') is not null
      then to_timestamp(r->>'END_TIME', 'MM/DD/YYYY HH24:MI:SS')::timestamp end as end_time,
    trim(r->>'ASSET_ID') as asset_id,
    r->>'EVENT_CODE'  as event_code,
    coalesce((r->>'EVENT_COUNT')::integer, 0) as event_count,
    nullif(r->>'OPERATOR', '') as operator,
    public.dds_norm_name(r->>'OPERATOR') as norm_name
  from jsonb_array_elements(p_rows) r;

  drop table if exists _resolved;
  create temporary table _resolved on commit drop as
  select n.norm_name, n.raw_name, n.row_count,
         r.emp_no, r.tier, r.distance, r.candidates
  from (
    select c.norm_name,
           min(c.operator)   as raw_name,
           count(*)::integer as row_count
    from _chunk c
    where c.norm_name is not null
    group by c.norm_name
  ) n
  cross join lateral public.dds_resolve_name(n.raw_name) r;

  insert into public.events (
    import_id, update_time, start_time, end_time,
    asset_id, event_code, event_count, operator, emp_no
  )
  select
    p_import_id, c.update_time, c.start_time, c.end_time,
    c.asset_id, c.event_code, c.event_count, c.operator,
    r.emp_no
  from _chunk c
  left join _resolved r on r.norm_name = c.norm_name
  on conflict (asset_id, start_time, event_code) do nothing;

  get diagnostics v_inserted = row_count;

  insert into public.import_name_review (
    import_id, raw_name, norm_name, tier, distance, candidates, row_count
  )
  select p_import_id, r.raw_name, r.norm_name, r.tier, r.distance,
         coalesce(r.candidates, '[]'::jsonb), r.row_count
  from _resolved r
  where r.emp_no is null
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

-- Same trim, same reasoning, for the MineStat ingest side of the same join
-- key. UNIT here mirrors ASSET_ID above exactly.

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
    coalesce((r->>'TOTAL_HRS')::numeric, 0)     as total_hrs
  from jsonb_array_elements(p_rows) r;

  drop table if exists _mnamed;
  create temporary table _mnamed on commit drop as
  select c.*,
    (upper(coalesce(c.last_name, ''))   = 'NO OPERATOR'
     and upper(coalesce(c.first_name, '')) = 'EQUIPMENT DOWN'
     and upper(coalesce(c.middle_name, '')) = 'OR STANDBY') as no_operator,
    (coalesce(c.last_name, '') || ', ' ||
     trim(coalesce(c.first_name, '') || ' ' || coalesce(c.middle_name, ''))
    ) as raw_name
  from _mchunk c;

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
  from _mnamed m
  left join _mresolved r on r.norm_name = public.dds_norm_name(m.raw_name)
  on conflict (asset_id, shift_date, shift) do update
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

-- Backfill: rows already stored before this migration may still carry
-- untrimmed asset_id/UNIT values from before either client trimmed them.
-- A plain trim() is idempotent — safe to run unconditionally, changes
-- nothing for a row that was already clean.
update public.events        set asset_id = trim(asset_id) where asset_id <> trim(asset_id);
update public.minestat_shifts set asset_id = trim(asset_id) where asset_id <> trim(asset_id);

-- ── 2. MineStat/DDS shift-date convention reconciliation ───────────────────
-- The audit's highest-value open question: does MineStat's own file-supplied
-- SHIFT_DATE actually follow the same night-shift-rolls-back-a-day
-- convention public.dds_shift_date() computes for DDS alerts? Nothing
-- enforces this — dds_minestat_ingest() trusts SHIFT_DATE as given (see that
-- function's own comment). A disagreement doesn't corrupt data (the join is
-- exact-equality, so it can never attribute to the WRONG day's driver) but it
-- does mean a real shift silently never attributes at all, with no signal
-- that anything is wrong beyond an aggregate "still unresolved" count nobody
-- is required to look at.
--
-- This function makes that assumption checkable on demand rather than
-- leaving it undocumented: it looks for asset/day pairs where DDS alerts
-- exist for a shift that has no matching MineStat row on the SAME
-- (asset_id, shift_date, shift), but DOES have a MineStat row for that
-- asset+shift on an ADJACENT calendar day — the exact signature a one-day
-- convention mismatch would leave behind. Read-only, console-invoked (same
-- precedent as dds_backfill_emp_no_from_minestat() itself) — this is a
-- diagnostic, not something that changes data on its own.

create or replace function public.dds_check_minestat_date_convention(
  p_limit integer default 50
) returns table (
  asset_id           text,
  shift              text,
  dds_shift_date     date,
  nearby_minestat_date date,
  day_offset         integer,
  dds_alert_count    bigint
)
language sql
stable
security invoker
set search_path = public
as $$
  select e.asset_id, e.shift, e.shift_date as dds_shift_date,
         m.shift_date as nearby_minestat_date,
         (m.shift_date - e.shift_date)::integer as day_offset,
         count(*) as dds_alert_count
  from public.events e
  join public.minestat_shifts m
    on m.asset_id = e.asset_id
   and m.shift    = e.shift
   and m.shift_date <> e.shift_date
   and abs(m.shift_date - e.shift_date) <= 1
  where e.emp_no is null
    and not exists (
      select 1 from public.minestat_shifts m2
       where m2.asset_id = e.asset_id
         and m2.shift_date = e.shift_date
         and m2.shift = e.shift
    )
  group by e.asset_id, e.shift, e.shift_date, m.shift_date
  order by count(*) desc
  limit p_limit;
$$;

revoke all on function public.dds_check_minestat_date_convention(integer) from public, anon;
grant execute on function public.dds_check_minestat_date_convention(integer) to authenticated;

-- ── 3. OPERATOR-text vs MineStat disagreement visibility ───────────────────
-- dds_backfill_emp_no_from_minestat() (0028) only ever fills emp_no where it
-- is currently NULL, so an OPERATOR-text resolution made at ingest always
-- wins silently over whatever MineStat's shift record says for the same
-- (asset_id, shift_date, shift) — with no record anywhere that a
-- disagreement existed, let alone what MineStat's answer would have been.
-- This table is that record: populated as a side effect of the backfill scan
-- below, it lets a human notice a real conflict (e.g. a data-entry mistake in
-- OPERATOR, or a genuinely wrong MineStat shift record) that today leaves
-- zero trace. It does not change attribution — OPERATOR-text still wins,
-- unchanged from 0028's behaviour — this only makes the previously-invisible
-- case inspectable.

create table if not exists public.emp_no_attribution_conflicts (
  id               bigint generated always as identity primary key,
  event_id         bigint not null references public.events(id) on delete cascade,
  asset_id         text not null,
  shift_date       date not null,
  shift            text not null,
  operator_emp_no  text not null,
  minestat_emp_no  text not null,
  detected_at      timestamptz not null default now()
);

create unique index if not exists uq_emp_no_attribution_conflicts_event
  on public.emp_no_attribution_conflicts (event_id);

alter table public.emp_no_attribution_conflicts enable row level security;

drop policy if exists emp_no_attribution_conflicts_read on public.emp_no_attribution_conflicts;
create policy emp_no_attribution_conflicts_read on public.emp_no_attribution_conflicts
  for select using (auth.uid() is not null);

-- Replaces 0028's version: identical join and NULL-only fill behaviour,
-- plus one added step — record (not act on) the case where a NON-NULL
-- events.emp_no disagrees with what the MineStat join would have said.

create or replace function public.dds_backfill_emp_no_from_minestat(
  p_limit integer default 2000
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows      integer := 0;
  v_conflicts integer := 0;
  v_remaining integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with candidates as (
    select e.id, m.emp_no
    from public.events e
    join public.minestat_shifts m
      on m.asset_id   = e.asset_id
     and m.shift_date = e.shift_date
     and m.shift      = e.shift
    where e.emp_no is null
      and m.emp_no is not null
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

  -- Conflict detection: rows where OPERATOR-text resolution already set a
  -- DIFFERENT emp_no than MineStat's shift record would say. Never touches
  -- events.emp_no — read-only observation, recorded once per event (the
  -- unique index above makes this upsert idempotent across repeat calls).
  --
  -- Scoped by NOT EXISTS against emp_no_attribution_conflicts, not a bare
  -- full-table join: this function is called after every DDS/MineStat
  -- upload (see index.html), so re-scanning every already-recorded conflict
  -- on every single call would make the cost grow with total history
  -- instead of with what's actually new. capped at p_limit for the same
  -- reason the candidates CTE above is — a large backlog is cleared over
  -- repeat calls (the client already loops on rowsRemaining), not in one.
  insert into public.emp_no_attribution_conflicts (
    event_id, asset_id, shift_date, shift, operator_emp_no, minestat_emp_no
  )
  select e.id, e.asset_id, e.shift_date, e.shift, e.emp_no, m.emp_no
  from public.events e
  join public.minestat_shifts m
    on m.asset_id   = e.asset_id
   and m.shift_date = e.shift_date
   and m.shift      = e.shift
  where e.emp_no is not null
    and m.emp_no is not null
    and m.emp_no <> e.emp_no
    and not exists (
      select 1 from public.emp_no_attribution_conflicts c
       where c.event_id = e.id and c.minestat_emp_no = m.emp_no
    )
  limit p_limit
  on conflict (event_id) do update
    set asset_id        = excluded.asset_id,
        shift_date      = excluded.shift_date,
        shift           = excluded.shift,
        operator_emp_no = excluded.operator_emp_no,
        minestat_emp_no = excluded.minestat_emp_no,
        detected_at     = now();
  get diagnostics v_conflicts = row_count;

  select count(*) into v_remaining
  from public.events e
  where e.emp_no is null
    and exists (
      select 1 from public.minestat_shifts m
       where m.asset_id = e.asset_id and m.shift_date = e.shift_date
         and m.shift = e.shift and m.emp_no is not null
    );

  return jsonb_build_object(
    'rowsUpdated', v_rows,
    'rowsRemaining', v_remaining,
    'conflictsDetected', v_conflicts
  );
end;
$$;

revoke all on function public.dds_backfill_emp_no_from_minestat(integer) from public, anon;
grant execute on function public.dds_backfill_emp_no_from_minestat(integer) to authenticated;
