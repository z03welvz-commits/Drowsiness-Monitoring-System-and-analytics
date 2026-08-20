-- ============================================================================
-- DDS — 0019_events_emp_no
-- ----------------------------------------------------------------------------
-- PHASE 2 of the employee-number identity work begun in 0018. Resolution now
-- RUNS, but nothing consumes it yet: events carry emp_no, unresolved names
-- collect in a review queue, and imports report how many need attention.
--
-- STILL OBSERVE-ONLY. dds_metrics() and derive() are untouched and continue to
-- group by the raw operator string, so every existing chart, KPI and
-- consistency flag produces byte-identical output to before this migration.
-- That is deliberate: phase 2 exists to answer a question with real data —
-- what fraction of raw names resolve at each tier? — before any number the
-- business reads depends on the answer. Switching the grouping is phase 4.
--
-- THE THREE THINGS THIS ADDS
--   1. events.emp_no        — nullable, resolved at ingest, alongside (never
--                             instead of) the raw operator text
--   2. import_name_review   — one row per distinct unresolved name per import
--   3. dds_backfill_emp_no()— applies the same resolver to existing history
--
-- WHY emp_no IS NOT A FOREIGN KEY TO drivers
--   A FK would make ingest fail when a roster is stale, which inverts the
--   rule this design is built on: an unresolved name must never cost an alert
--   row. It is also a hot insert path — 45,000-row imports arrive in chunks —
--   and a per-row FK check against a table the resolver just consulted is
--   redundant work. Integrity is maintained by the resolver and by
--   dds_orphaned_emp_no() below, which reports (rather than enforces) drift.
-- ============================================================================

-- ── events.emp_no ──────────────────────────────────────────────────────────
-- NULLABLE and NOT backfilled by this DDL. Existing rows stay null until
-- dds_backfill_emp_no() is run deliberately, so applying this migration is
-- fast and non-locking on a large events table.
--
-- events.operator is NOT touched, now or ever. The raw string is the evidence
-- for every resolution decision: without it, a wrong alias cannot be
-- diagnosed, re-reviewed, or reversed, because the only surviving record
-- would be the identity the resolver invented. Phase 4 changes what the
-- dashboard GROUPS BY; it does not delete what the import actually said.

alter table public.events
  add column if not exists emp_no text;

-- Partial index: the phase-4 grouping only ever reads non-null emp_no, and
-- excluding nulls keeps the index small while history is still unresolved.
create index if not exists idx_events_emp_no
  on public.events (emp_no) where emp_no is not null;

-- Supports the per-driver day rollups phase 4 will need (emp_no x shift_date),
-- mirroring idx_events_shiftdate's role for the existing asset grouping.
create index if not exists idx_events_emp_no_date
  on public.events (emp_no, shift_date) where emp_no is not null;

-- ── imports.unresolved_count ───────────────────────────────────────────────
-- Parallel to the existing rejected_count. An import that loaded every row but
-- could not attribute some of them is COMPLETE WITH A WARNING, not a failure:
-- the alerts are all present and every total is whole. Surfacing the count
-- here is what lets the import list say "complete · 3 names need review"
-- rather than looking clean while three drivers' alerts sit unattributed.

alter table public.imports
  add column if not exists unresolved_count integer not null default 0;

-- ── The review queue ───────────────────────────────────────────────────────
-- One row per DISTINCT unresolved name per import, not per event row. A
-- misspelling appearing on 400 alerts is one decision for a human, not 400.
-- row_count carries how many alert rows are waiting on that decision, which
-- is what lets the queue be worked in impact order.
--
-- CANDIDATES ARE STORED, not recomputed on open. The resolver's shortlist is
-- a snapshot of what the masterlist looked like at ingest; recomputing later
-- would silently change the options as the roster shifts, and a reviewer
-- would have no way to know the list they are looking at is not the list the
-- import actually saw.

create table if not exists public.import_name_review (
  id          bigint generated always as identity primary key,
  import_id   uuid references public.imports(id) on delete cascade,

  raw_name    text not null,
  norm_name   text not null,

  -- Which rung the resolver reached before giving up: 'none', 'fuzzy_review',
  -- 'ambiguous_exact'. Distinguishes "nobody looks like this" from "two people
  -- look exactly like this", which are different review tasks.
  tier        text,
  distance    integer,

  -- [{emp_no, name, tier, distance}] — ranked, possibly empty.
  candidates  jsonb not null default '[]'::jsonb,

  row_count   integer not null default 0,

  -- 'open'     — awaiting a decision
  -- 'resolved' — an alias was confirmed; events re-attributed
  -- 'ignored'  — not a driver (TEST, N/A, a plate in the wrong column).
  --              Kept visible under a filter rather than deleted, so an
  --              over-eager ignore can be found and undone.
  state       text not null default 'open'
                check (state in ('open', 'resolved', 'ignored')),

  resolved_by uuid references auth.users(id) on delete set null,
  resolved_at timestamptz,
  created_at  timestamptz not null default now()
);

-- One row per name per import. The conflict target dds_ingest()'s upsert
-- relies on: chunk 7 re-encountering a name chunk 2 already queued must add to
-- its row_count, not create a second review item for the same decision.
create unique index if not exists uq_import_name_review
  on public.import_name_review (import_id, norm_name);

create index if not exists idx_import_name_review_state
  on public.import_name_review (state, row_count desc);

-- ── Ingest with resolution ─────────────────────────────────────────────────
-- Replaces 0015's dds_ingest(). Signature, return value and row_count
-- semantics are unchanged, so the client needs no modification to keep
-- working — the added behaviour is entirely in what it writes alongside.
--
-- RESOLUTION IS PER DISTINCT NAME, NOT PER ROW. A 2,000-row chunk typically
-- carries a few dozen distinct operators; resolving once per name and joining
-- turns thousands of resolver calls into dozens. The fuzzy tier is the
-- expensive rung and this is what keeps it affordable at import scale.
--
-- STILL `on conflict do nothing`: re-sending a chunk must not double-count,
-- and must not overwrite an emp_no that a human may since have corrected via
-- the review queue. A re-import is not a mandate to undo review work.

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

  -- Parse the chunk once into a temp table. dds_resolve_name() is called
  -- against the DISTINCT names only, then joined back on the normalized form.
  drop table if exists _chunk;
  create temporary table _chunk on commit drop as
  select
    to_timestamp(r->>'UPDATE_TIME', 'MM/DD/YYYY HH24:MI:SS')::timestamp as update_time,
    to_timestamp(r->>'START_TIME',  'MM/DD/YYYY HH24:MI:SS')::timestamp as start_time,
    case when nullif(r->>'END_TIME', '') is not null
      then to_timestamp(r->>'END_TIME', 'MM/DD/YYYY HH24:MI:SS')::timestamp end as end_time,
    r->>'ASSET_ID'    as asset_id,
    r->>'EVENT_CODE'  as event_code,
    coalesce((r->>'EVENT_COUNT')::integer, 0) as event_count,
    nullif(r->>'OPERATOR', '') as operator,
    public.dds_norm_name(r->>'OPERATOR') as norm_name
  from jsonb_array_elements(p_rows) r;

  -- Collapse to distinct names FIRST, then resolve each exactly once via
  -- LATERAL. Calling the resolver inside the grouped select (as
  -- `(dds_resolve_name(min(operator))).*`) would work, but LATERAL states the
  -- once-per-name intent directly rather than depending on the planner not to
  -- re-evaluate a set-returning function per output column.
  drop table if exists _resolved;
  create temporary table _resolved on commit drop as
  select n.norm_name, n.raw_name, n.row_count,
         r.emp_no, r.tier, r.distance, r.candidates
  from (
    select c.norm_name,
           min(c.operator)   as raw_name,   -- a representative raw spelling
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

  -- Queue the names that did not resolve. A blank/absent OPERATOR is NOT a
  -- review item: it is a known and expected gap (see OPTIONAL_COLUMNS in
  -- dds-state.js — some assets simply do not report a driver), and filing it
  -- as a decision a human must make would bury the real misspellings under
  -- noise nobody can act on. Those rows keep emp_no null and are counted as
  -- unattributed, not as errors.
  insert into public.import_name_review (
    import_id, raw_name, norm_name, tier, distance, candidates, row_count
  )
  select p_import_id, r.raw_name, r.norm_name, r.tier, r.distance,
         coalesce(r.candidates, '[]'::jsonb), r.row_count
  from _resolved r
  where r.emp_no is null
  on conflict (import_id, norm_name) do update
    -- Accumulate across chunks: the same name in chunk 2 and chunk 7 is one
    -- decision covering the rows of both.
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

revoke all on function public.dds_ingest(uuid, jsonb) from public, anon;
grant execute on function public.dds_ingest(uuid, jsonb) to authenticated;

-- ── Backfill ───────────────────────────────────────────────────────────────
-- Applies the resolver to events already in the table, so history
-- participates in the identity merge rather than only new imports.
--
-- BATCHED and RESUMABLE by design. events is the largest table here and a
-- single UPDATE over all of it would hold locks for the duration; this
-- processes p_limit distinct names per call and returns how many remain, so
-- the caller can drive it to completion in bounded steps.
--
-- Only ever fills emp_no where it is NULL. A value already present was either
-- resolved by an earlier run or corrected by a human, and neither should be
-- silently recomputed by a maintenance pass.

create or replace function public.dds_backfill_emp_no(
  p_limit integer default 500
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_names     integer := 0;
  v_rows      integer := 0;
  v_remaining integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  drop table if exists _todo;
  create temporary table _todo on commit drop as
  select norm_name, min(operator) as raw_name
  from (
    select operator, public.dds_norm_name(operator) as norm_name
    from public.events
    where emp_no is null and operator is not null
  ) s
  where norm_name is not null
  group by norm_name
  limit p_limit;

  select count(*) into v_names from _todo;

  if v_names > 0 then
    with resolved as (
      select t.norm_name, r.emp_no
      from _todo t
      cross join lateral public.dds_resolve_name(t.raw_name) r
    ),
    upd as (
      update public.events e
         set emp_no = r.emp_no
        from resolved r
       where e.emp_no is null
         and r.emp_no is not null
         and public.dds_norm_name(e.operator) = r.norm_name
      returning 1
    )
    select count(*) into v_rows from upd;
  end if;

  select count(distinct public.dds_norm_name(operator)) into v_remaining
  from public.events where emp_no is null and operator is not null;

  return jsonb_build_object(
    'namesProcessed', v_names,
    'rowsUpdated',    v_rows,
    'namesRemaining', v_remaining
  );
end;
$$;

revoke all on function public.dds_backfill_emp_no(integer) from public, anon;
grant execute on function public.dds_backfill_emp_no(integer) to authenticated;

-- ── Tier telemetry ─────────────────────────────────────────────────────────
-- THE POINT OF PHASE 2. Reports how the resolver actually performed against
-- real data, which is the evidence phase 4 should be gated on:
--
--   * a large fuzzy share means the tolerances are too loose and should be
--     tightened before any KPI depends on them
--   * a large unresolved share means the masterlist is incomplete, and
--     switching the grouping would strand real alerts under no driver
--
-- Deliberately a function rather than a view so it can be granted to
-- authenticated without exposing the underlying tables to PostgREST.

create or replace function public.dds_resolution_stats(
  p_import_id uuid default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  result jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  with scope as (
    select * from public.events
     where p_import_id is null or import_id = p_import_id
  ),
  totals as (
    select
      count(*)                                              as rows_total,
      count(*) filter (where emp_no is not null)            as rows_resolved,
      count(*) filter (where operator is null)              as rows_no_operator,
      count(*) filter (where emp_no is null
                         and operator is not null)          as rows_unresolved,
      count(distinct emp_no) filter (where emp_no is not null) as distinct_drivers,
      count(distinct operator) filter (where operator is not null) as distinct_raw_names
    from scope
  ),
  by_tier as (
    select a.tier, count(*) as n
    from public.driver_aliases a
    group by a.tier
  ),
  queue as (
    select state, count(*) as names, coalesce(sum(row_count), 0) as rows
    from public.import_name_review
    where p_import_id is null or import_id = p_import_id
    group by state
  )
  select jsonb_build_object(
    'rows', jsonb_build_object(
      'total',       t.rows_total,
      'resolved',    t.rows_resolved,
      'unresolved',  t.rows_unresolved,
      'noOperator',  t.rows_no_operator,
      'resolvedPct', case when t.rows_total > 0
        then round((t.rows_resolved::numeric / t.rows_total) * 100, 2) else 0 end
    ),
    'distinct', jsonb_build_object(
      'drivers',  t.distinct_drivers,
      'rawNames', t.distinct_raw_names
    ),
    'aliasesByTier', coalesce(
      (select jsonb_object_agg(tier, n) from by_tier), '{}'::jsonb),
    'reviewQueue', coalesce(
      (select jsonb_object_agg(state, jsonb_build_object('names', names, 'rows', rows))
         from queue), '{}'::jsonb)
  )
  into result
  from totals t;

  return result;
end;
$$;

revoke all on function public.dds_resolution_stats(uuid) from public, anon;
grant execute on function public.dds_resolution_stats(uuid) to authenticated;

-- ── Drift detection ────────────────────────────────────────────────────────
-- events.emp_no has no FK (see the header for why), so nothing at the database
-- level prevents an emp_no from outliving the driver row it pointed at. This
-- reports that drift instead of enforcing it — a report can be acted on
-- deliberately, whereas an FK would have failed the import that discovered it.

create or replace function public.dds_orphaned_emp_no()
returns table (emp_no text, rows bigint)
language sql
stable
security invoker
set search_path = public
as $$
  select e.emp_no, count(*) as rows
  from public.events e
  where e.emp_no is not null
    and not exists (select 1 from public.drivers d where d.emp_no = e.emp_no)
  group by e.emp_no
  order by count(*) desc;
$$;

revoke all on function public.dds_orphaned_emp_no() from public, anon;
grant execute on function public.dds_orphaned_emp_no() to authenticated;

-- ── Review queue actions ───────────────────────────────────────────────────
-- The write paths phase 3's UI will call. Defined here, with the queue itself,
-- so the table is never edited ad hoc — every state change goes through a
-- function that also re-attributes the affected events and keeps
-- imports.unresolved_count honest.

-- Recomputes unresolved_count for every import from the queue. Called after
-- each queue action rather than maintained incrementally: the queue is small,
-- and a count derived on demand cannot drift from the rows it summarizes.
create or replace function public.dds_refresh_unresolved_counts()
returns void
language sql
security definer
set search_path = public
as $
  update public.imports i
     set unresolved_count = coalesce((
       select sum(r.row_count) from public.import_name_review r
        where r.import_id = i.id and r.state = 'open'
     ), 0);
$;

-- Confirm a name against an employee. Writes the alias (so the decision is
-- learned and never asked again), re-attributes every matching event ACROSS
-- ALL IMPORTS — not just this one, since a spelling means the same person
-- wherever it appeared — and closes the queue rows.
create or replace function public.dds_resolve_review(
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
  from public.import_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  perform public.dds_confirm_alias(coalesce(v_raw, v_norm), p_emp_no);

  update public.events
     set emp_no = p_emp_no
   where emp_no is null
     and operator is not null
     and public.dds_norm_name(operator) = v_norm;
  get diagnostics v_rows = row_count;

  -- Close every open queue row for this name, in every import. The same
  -- misspelling queued by three separate imports is one decision.
  update public.import_name_review
     set state = 'resolved', resolved_by = auth.uid(), resolved_at = now()
   where norm_name = v_norm and state = 'open';

  perform public.dds_refresh_unresolved_counts();

  return jsonb_build_object('normName', v_norm, 'empNo', p_emp_no, 'rowsUpdated', v_rows);
end;
$$;

-- Mark a queued name as not-a-driver. No alias is written: an ignore is a
-- statement that the string is not a person, not a mapping to one. Recorded
-- rather than deleted so it stays findable and reversible.
create or replace function public.dds_ignore_review(p_review_id bigint)
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

  select norm_name into v_norm from public.import_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  update public.import_name_review
     set state = 'ignored', resolved_by = auth.uid(), resolved_at = now()
   where norm_name = v_norm and state = 'open';

  perform public.dds_refresh_unresolved_counts();
  return true;
end;
$$;

-- Reopen a resolved or ignored queue row. The undo path: a wrong confirmation
-- is as durable as a right one, and without this the first bad decision is
-- permanent. Removing the alias is what actually reverses it — the queue row
-- alone is bookkeeping.
create or replace function public.dds_reopen_review(
  p_review_id     bigint,
  p_clear_alias   boolean default true
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

  select norm_name into v_norm from public.import_name_review where id = p_review_id;
  if v_norm is null then raise exception 'UNKNOWN_REVIEW'; end if;

  if p_clear_alias then
    delete from public.driver_aliases where norm_name = v_norm;
    -- Un-attribute the events this alias had claimed, so the queue count and
    -- the data agree. Without this the name would reappear as unresolved
    -- while its rows stayed pointed at the employee just disavowed.
    update public.events set emp_no = null
     where operator is not null and public.dds_norm_name(operator) = v_norm;
  end if;

  update public.import_name_review
     set state = 'open', resolved_by = null, resolved_at = null
   where norm_name = v_norm and state <> 'open';

  perform public.dds_refresh_unresolved_counts();
  return true;
end;
$$;

-- ── Row Level Security ─────────────────────────────────────────────────────
-- Same single-tenant rule as everywhere else: any signed-in user reads.
-- Writes go through the SECURITY DEFINER functions above, so no write policy
-- is granted — the queue cannot be edited directly through PostgREST, which
-- is what keeps event re-attribution and the unresolved counts in step with
-- the state changes that caused them.

alter table public.import_name_review enable row level security;

drop policy if exists import_name_review_read on public.import_name_review;
create policy import_name_review_read on public.import_name_review
  for select using (auth.uid() is not null);

revoke all on function public.dds_resolve_review(bigint, text)      from public, anon;
revoke all on function public.dds_ignore_review(bigint)             from public, anon;
revoke all on function public.dds_reopen_review(bigint, boolean)    from public, anon;
revoke all on function public.dds_refresh_unresolved_counts()       from public, anon;

grant execute on function public.dds_resolve_review(bigint, text)   to authenticated;
grant execute on function public.dds_ignore_review(bigint)          to authenticated;
grant execute on function public.dds_reopen_review(bigint, boolean) to authenticated;
