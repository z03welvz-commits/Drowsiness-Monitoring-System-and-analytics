-- ============================================================================
-- DDS — 0024_minestat
-- ----------------------------------------------------------------------------
-- Adds a THIRD data source, MineStat: daily per-unit/per-shift records of who
-- operated that unit (Last/First/Middle name) plus a utilization-hours
-- breakdown (Operating/Down/Delay/Standby/Total).
--
-- WHY THIS EXISTS
--   Real DDS alert exports carry no operator/driver field at all — OPERATOR
--   has always been optional (see OPTIONAL_COLUMNS in dds-state.js) and is
--   absent in practice, so every alert resolves to UNSPECIFIED_OPERATOR
--   today. MineStat is what actually records who was running a unit on a
--   given shift; this migration lets that identity flow onto DDS alerts via
--   a (asset_id, shift_date, shift) join — the same key events.shift/
--   events.shift_date are already GENERATED from (0001_init.sql).
--
-- REUSED, NOT REBUILT
--   dds_norm_name()/dds_resolve_name() (0018) are generic tiered name
--   resolvers — nothing DDS-specific about them. MineStat's Last/First/
--   Middle columns are joined into one "SURNAME, GIVEN MIDDLE" string (the
--   masterlist's own NAME format) and fed straight through the same
--   resolver DDS operator names already use. A name learned via MineStat
--   (dds_confirm_alias(), driver_aliases) benefits DDS resolution too, and
--   vice versa — the alias table is the one shared brain, not the ingest
--   code around it.
--
-- WHY A PARALLEL REVIEW QUEUE, NOT A SHARED ONE
--   import_name_review/dds_ingest()/dds_resolve_review()/dds_reopen_review()
--   (0019) are hard-coded to events.operator/events.emp_no — none are
--   parameterized by table or column. Generalizing a SECURITY DEFINER
--   function by table/column name means dynamic SQL, a real injection-
--   surface increase, to save a modest amount of near-duplicate SQL that
--   never runs on the hot DDS ingest path anyway. minestat_name_review is a
--   structural clone instead — same shape, same state machine, zero risk to
--   the already-shipped, already-tested DDS resolution code.
--
-- WHY events.emp_no IS BACKFILLED, NOT JOINED LIVE
--   events.emp_no stays the ONE column every consumer reads (dds_metrics(),
--   derive(), the still-deferred phase-4 regroup), regardless of whether the
--   value came from OPERATOR text or a MineStat join — exactly the "one
--   place a calculation happens" rule 0020's own comments describe. A live
--   join inside dds_metrics() would mean two attribution paths that could
--   silently disagree, and would touch a function test/parity.sh already
--   holds to a byte-identical JS/SQL contract. dds_backfill_emp_no_from_
--   minestat() below mirrors dds_backfill_emp_no()'s existing, already-
--   shipped, console-invoked precedent instead.
--
-- WHY imports GETS A `kind` COLUMN
--   imports is a shared table (dds_ingest and dds_minestat_ingest below both
--   FK into it). The EXISTING dds_refresh_unresolved_counts() (0019)
--   recomputes unresolved_count for EVERY imports row from
--   import_name_review, unconditionally. Left unchanged, that function would
--   zero out a MineStat import's unresolved_count the moment any DDS review
--   action fired anywhere in the system (a MineStat import's id never
--   appears in import_name_review, so its sum comes back null -> 0) — and
--   symmetrically, a naive MineStat-only refresh function would do the same
--   to DDS imports. `kind` lets each refresh function scope its own broad
--   UPDATE to only the rows it actually owns, so the two review systems
--   cannot stomp each other's bookkeeping despite sharing one table.
-- ============================================================================

-- ── imports.kind ────────────────────────────────────────────────────────────
-- Existing rows default to 'dds' (every import before this migration was a
-- DDS alert file); the MineStat upload path sets 'minestat' explicitly when
-- it creates its own imports row.

alter table public.imports
  add column if not exists kind text not null default 'dds'
    check (kind in ('dds', 'minestat'));

-- Patch 0019's broad refresh to only touch the DDS imports it was always
-- meant to own — see the header comment above for why this is required now
-- that a second `kind` of import shares this table. Behaviour for existing
-- DDS imports is byte-identical to before; only the WHERE clause is new.
create or replace function public.dds_refresh_unresolved_counts()
returns void
language sql
security definer
set search_path = public
as $$
  update public.imports i
     set unresolved_count = coalesce((
       select sum(r.row_count) from public.import_name_review r
        where r.import_id = i.id and r.state = 'open'
     ), 0)
   where i.kind = 'dds';
$$;

-- ── minestat_shifts ─────────────────────────────────────────────────────────
-- One row per (asset_id, shift_date, shift) — the confirmed real-world grain
-- (a MineStat export carries exactly one utilization/operator record per
-- unit per shift per day). A re-uploaded file CORRECTS the record rather
-- than appending to a log: unlike a DDS alert (an immutable historical
-- event), a MineStat row is a statement of fact about a shift that a later,
-- more complete export can supersede. Hence UPSERT semantics below, the
-- opposite of dds_ingest()'s `on conflict do nothing`.
--
-- emp_no/tier/distance/candidates mirror driver_aliases'/import_name_review's
-- shape so the resolution story reads the same way it does for DDS names.
-- tier additionally carries 'no_operator' — a MineStat-specific state for the
-- "NO OPERATOR / EQUIPMENT DOWN / OR STANDBY" sentinel a real export uses to
-- mean "nobody ran this unit that shift." That is not an unresolved name; it
-- is a genuine absence of one, and must never reach the review queue.

create table if not exists public.minestat_shifts (
  asset_id      text not null,
  shift_date    date not null,
  shift         text not null check (shift in ('DAY', 'NIGHT')),

  last_name     text,
  first_name    text,
  middle_name   text,

  operating_hrs numeric not null default 0,
  down_hrs      numeric not null default 0,
  delay_hrs     numeric not null default 0,
  standby_hrs   numeric not null default 0,
  total_hrs     numeric not null default 0,

  -- No FK to drivers — same rationale as events.emp_no (0019): a stale
  -- roster must never block ingest, and integrity drift is reported (see a
  -- future dds_orphaned_emp_no()-style check if needed), not enforced here.
  emp_no        text,
  tier          text,
  distance      integer,
  candidates    jsonb not null default '[]'::jsonb,

  import_id     uuid references public.imports(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  primary key (asset_id, shift_date, shift)
);

create index if not exists idx_minestat_emp_date
  on public.minestat_shifts (emp_no, shift_date) where emp_no is not null;

-- ── minestat_name_review ────────────────────────────────────────────────────
-- Structural clone of import_name_review (0019) — see the header comment on
-- why this is a parallel table rather than a shared, source-tagged one.

create table if not exists public.minestat_name_review (
  id          bigint generated always as identity primary key,
  import_id   uuid references public.imports(id) on delete cascade,

  raw_name    text not null,
  norm_name   text not null,
  tier        text,
  distance    integer,
  candidates  jsonb not null default '[]'::jsonb,

  row_count   integer not null default 0,
  state       text not null default 'open'
                check (state in ('open', 'resolved', 'ignored')),

  resolved_by uuid references auth.users(id) on delete set null,
  resolved_at timestamptz,
  created_at  timestamptz not null default now()
);

create unique index if not exists uq_minestat_name_review
  on public.minestat_name_review (import_id, norm_name);

create index if not exists idx_minestat_name_review_state
  on public.minestat_name_review (state, row_count desc);

-- ── Ingest with resolution ──────────────────────────────────────────────────
-- Mirrors dds_ingest()'s chunk/LATERAL shape (0019): resolve once per
-- DISTINCT name per chunk, not once per row.
--
-- UPSERT, not `do nothing`: see the table comment above for why a MineStat
-- row is corrigible. Re-sending an already-ingested chunk simply re-states
-- the same facts (idempotent in effect, if not in the literal SQL sense).

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

  -- Client sends already-validated, canonically-keyed rows (see
  -- toCanonicalMinestat() in index.html): UNIT, SHIFT_DATE ('YYYY-MM-DD'),
  -- SHIFT ('DAY'/'NIGHT'), LAST_NAME/FIRST_NAME/MIDDLE_NAME, and the five
  -- *_HRS numeric fields. Malformed values were already row-rejected
  -- client-side per the agreed "reject at import" rule, so casts here are
  -- expected to succeed — same trust boundary dds_ingest() itself relies on.
  drop table if exists _mchunk;
  create temporary table _mchunk on commit drop as
  select
    r->>'UNIT'                          as asset_id,
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

  -- The sentinel ("nobody ran this unit this shift") and the "SURNAME, GIVEN
  -- MIDDLE" raw name string dds_resolve_name() expects, computed once per
  -- row up front so both the upsert and the resolution step below read the
  -- same values.
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

  -- Resolve distinct non-sentinel names once per chunk, same batching
  -- dds_ingest() uses for the same reason: fuzzy matching is the expensive
  -- rung, and a chunk's names repeat across many unit/shift rows.
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

  -- Queue names that did not resolve (never the sentinel — see _mresolved's
  -- own WHERE, which excludes no_operator rows entirely up front).
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

revoke all on function public.dds_minestat_ingest(uuid, jsonb) from public, anon;
grant execute on function public.dds_minestat_ingest(uuid, jsonb) to authenticated;

-- ── MineStat review queue actions ───────────────────────────────────────────
-- Structural clones of dds_resolve_review()/dds_ignore_review()/
-- dds_reopen_review() (0019), targeting minestat_shifts/minestat_name_review
-- instead of events/import_name_review. Both write paths still go through
-- dds_confirm_alias()/driver_aliases — the shared learning layer — so a name
-- confirmed here is instantly usable by DDS resolution too.

create or replace function public.dds_minestat_refresh_unresolved_counts()
returns void
language sql
security definer
set search_path = public
as $$
  update public.imports i
     set unresolved_count = coalesce((
       select sum(r.row_count) from public.minestat_name_review r
        where r.import_id = i.id and r.state = 'open'
     ), 0)
   where i.kind = 'minestat';
$$;

create or replace function public.dds_minestat_resolve_review(
  p_review_id bigint,
  p_emp_no    text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_norm text;
  v_raw  text;
  v_rows integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select norm_name, raw_name into v_norm, v_raw
  from public.minestat_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  perform public.dds_confirm_alias(coalesce(v_raw, v_norm), p_emp_no);

  -- tier='human' alongside emp_no — leaving the pre-resolution tier (e.g.
  -- 'none' or 'fuzzy_review') in place would make a manually-confirmed row
  -- look like it was never actually resolved, the same distinction
  -- driver_aliases itself draws between an auto tier and 'human'.
  update public.minestat_shifts
     set emp_no = p_emp_no, tier = 'human', updated_at = now()
   where emp_no is null
     and public.dds_norm_name(
           coalesce(last_name, '') || ', ' ||
           trim(coalesce(first_name, '') || ' ' || coalesce(middle_name, ''))
         ) = v_norm;
  get diagnostics v_rows = row_count;

  update public.minestat_name_review
     set state = 'resolved', resolved_by = auth.uid(), resolved_at = now()
   where norm_name = v_norm and state = 'open';

  perform public.dds_minestat_refresh_unresolved_counts();

  return jsonb_build_object('normName', v_norm, 'empNo', p_emp_no, 'rowsUpdated', v_rows);
end;
$$;

create or replace function public.dds_minestat_ignore_review(p_review_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_norm text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select norm_name into v_norm from public.minestat_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  update public.minestat_name_review
     set state = 'ignored', resolved_by = auth.uid(), resolved_at = now()
   where norm_name = v_norm and state = 'open';

  perform public.dds_minestat_refresh_unresolved_counts();
  return true;
end;
$$;

create or replace function public.dds_minestat_reopen_review(
  p_review_id   bigint,
  p_clear_alias boolean default true
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_norm text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select norm_name into v_norm from public.minestat_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  if p_clear_alias then
    delete from public.driver_aliases where norm_name = v_norm;
    -- Clear tier along with emp_no — leaving 'human' behind would make a
    -- disavowed row look like it is still a confirmed match.
    update public.minestat_shifts
       set emp_no = null, tier = null, updated_at = now()
     where public.dds_norm_name(
             coalesce(last_name, '') || ', ' ||
             trim(coalesce(first_name, '') || ' ' || coalesce(middle_name, ''))
           ) = v_norm;
  end if;

  update public.minestat_name_review
     set state = 'open', resolved_by = null, resolved_at = null
   where norm_name = v_norm and state <> 'open';

  perform public.dds_minestat_refresh_unresolved_counts();
  return true;
end;
$$;

revoke all on function public.dds_minestat_resolve_review(bigint, text)   from public, anon;
revoke all on function public.dds_minestat_ignore_review(bigint)          from public, anon;
revoke all on function public.dds_minestat_reopen_review(bigint, boolean) from public, anon;
revoke all on function public.dds_minestat_refresh_unresolved_counts()    from public, anon;

grant execute on function public.dds_minestat_resolve_review(bigint, text)   to authenticated;
grant execute on function public.dds_minestat_ignore_review(bigint)          to authenticated;
grant execute on function public.dds_minestat_reopen_review(bigint, boolean) to authenticated;
grant execute on function public.dds_minestat_refresh_unresolved_counts()    to authenticated;

-- ── DDS attribution from MineStat ───────────────────────────────────────────
-- Mirrors dds_backfill_emp_no()'s existing, already-shipped shape (0019):
-- batched, resumable, console-invoked (not wired to any UI button — same
-- precedent as dds_backfill_emp_no() itself, which is granted to
-- `authenticated` today but called from no client code path).
--
-- Only ever fills emp_no where it is NULL — a value already present was
-- either resolved from the row's own OPERATOR text or corrected by a human,
-- and neither should be silently overwritten by a MineStat join.

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

revoke all on function public.dds_backfill_emp_no_from_minestat(integer) from public, anon;
grant execute on function public.dds_backfill_emp_no_from_minestat(integer) to authenticated;

-- ── Row Level Security ──────────────────────────────────────────────────────
-- Same single-tenant rule as import_name_review (0019): any signed-in user
-- reads; all writes go through the SECURITY DEFINER functions above, so
-- neither table is directly writable through PostgREST.

alter table public.minestat_shifts enable row level security;
alter table public.minestat_name_review enable row level security;

drop policy if exists minestat_shifts_read on public.minestat_shifts;
create policy minestat_shifts_read on public.minestat_shifts
  for select using (auth.uid() is not null);

drop policy if exists minestat_name_review_read on public.minestat_name_review;
create policy minestat_name_review_read on public.minestat_name_review
  for select using (auth.uid() is not null);
