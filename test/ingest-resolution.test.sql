-- ============================================================================
-- DDS — ingest resolution tests (0019_events_emp_no)
-- ----------------------------------------------------------------------------
-- Asserts the phase-2 guarantees: resolution happens at ingest, and NOTHING is
-- lost when it fails.
--
-- THE INVARIANT THIS FILE DEFENDS
--   An unresolved driver name must never cost an alert row. Every row loads;
--   the ones that could not be attributed carry emp_no null and are surfaced
--   in import_name_review for a human. A regression here is silent — the
--   dashboard would simply show fewer alerts than the file contained, with no
--   error anywhere — so it is pinned down case by case below.
--
-- USAGE
--   psql -v ON_ERROR_STOP=1 -f supabase/migrations/0018_driver_masterlist.sql
--   psql -v ON_ERROR_STOP=1 -f supabase/migrations/0019_events_emp_no.sql
--   psql -v ON_ERROR_STOP=1 -f test/ingest-resolution.test.sql
--
--   Runs inside a transaction that ROLLS BACK. Asserts with raise exception so
--   a failure cannot be overlooked in the output.
--
-- NOTE ON auth
--   dds_ingest() and the review functions guard on auth.uid(), which is null
--   outside a PostgREST request, so this file calls the underlying logic
--   through a test harness rather than the RPCs where that guard would fire.
--   The guard itself is not exercised here; RLS and grants are asserted in the
--   migration, not in this file.
-- ============================================================================

begin;

-- ── Fixture ────────────────────────────────────────────────────────────────
-- MARIANO ROBERTO / ROBERTA again: the ambiguity pair. An import containing a
-- name equidistant from both must queue it rather than attribute it.

insert into public.drivers (emp_no, full_name) values
  ('I001', 'DELA CRUZ, JUAN'),
  ('I002', 'SANTOS, MARIA CLARA'),
  ('I003', 'MARIANO, ROBERTO'),
  ('I004', 'MARIANO, ROBERTA');

insert into public.driver_aliases (norm_name, raw_name, emp_no, tier, source)
select public.dds_norm_name(full_name), full_name, emp_no, 'seed', 'seed'
from public.drivers where emp_no like 'I00%';

insert into public.imports (id, storage_key, original_name, status)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'test/key', 'test.csv', 'pending');

-- ── Ingest, chunk 1 ────────────────────────────────────────────────────────
-- Five rows covering every disposition: a seeded alias hit, a tier-3 match, an
-- ambiguous fuzzy pair, a completely unknown name, and a BLANK operator.

do $$
declare v_inserted integer;
begin
  v_inserted := public.dds_ingest('aaaaaaaa-0000-0000-0000-000000000001', $j$[
    {"UPDATE_TIME":"01/05/2026 08:00:00","START_TIME":"01/05/2026 07:00:00","ASSET_ID":"IT1","EVENT_CODE":"D","EVENT_COUNT":"3","OPERATOR":"dela cruz, juan"},
    {"UPDATE_TIME":"01/05/2026 08:05:00","START_TIME":"01/05/2026 07:05:00","ASSET_ID":"IT2","EVENT_CODE":"D","EVENT_COUNT":"2","OPERATOR":"SANTOS, MARIA"},
    {"UPDATE_TIME":"01/05/2026 08:10:00","START_TIME":"01/05/2026 07:10:00","ASSET_ID":"IT3","EVENT_CODE":"D","EVENT_COUNT":"5","OPERATOR":"MARIANO, ROBERT"},
    {"UPDATE_TIME":"01/05/2026 08:15:00","START_TIME":"01/05/2026 07:15:00","ASSET_ID":"IT4","EVENT_CODE":"D","EVENT_COUNT":"1","OPERATOR":"WHO IS THIS"},
    {"UPDATE_TIME":"01/05/2026 08:20:00","START_TIME":"01/05/2026 07:20:00","ASSET_ID":"IT5","EVENT_CODE":"D","EVENT_COUNT":"4","OPERATOR":""}
  ]$j$::jsonb);

  -- THE CORE INVARIANT. Every row loads, including the three that could not
  -- be attributed to anybody.
  if v_inserted <> 5 then
    raise exception 'FAIL: expected 5 rows inserted, got % — an unresolved name cost an alert row', v_inserted;
  end if;
end;
$$;

do $$
begin
  if (select emp_no from public.events where asset_id='IT1') <> 'I001' then
    raise exception 'FAIL: alias hit did not attribute';
  end if;

  if (select emp_no from public.events where asset_id='IT2') <> 'I002' then
    raise exception 'FAIL: tier-3 match did not attribute';
  end if;

  -- Ambiguous: must be left unattributed rather than guessed.
  if (select emp_no from public.events where asset_id='IT3') is not null then
    raise exception 'FAIL: ambiguous name was attributed — the resolver guessed';
  end if;

  if (select emp_no from public.events where asset_id='IT4') is not null then
    raise exception 'FAIL: unknown name was attributed';
  end if;

  -- The raw text must survive intact on every row. It is the evidence any
  -- later review depends on.
  if (select operator from public.events where asset_id='IT1') <> 'dela cruz, juan' then
    raise exception 'FAIL: raw operator text was modified at ingest';
  end if;

  -- A blank OPERATOR is a known gap, not a review item. Filing it as a
  -- decision a human must make would bury the real misspellings.
  if exists (select 1 from public.import_name_review where raw_name = '') then
    raise exception 'FAIL: a blank operator was queued for review';
  end if;

  if (select count(*) from public.import_name_review
       where import_id='aaaaaaaa-0000-0000-0000-000000000001') <> 2 then
    raise exception 'FAIL: expected exactly 2 queued names (ambiguous + unknown)';
  end if;

  -- The ambiguous case must hand the reviewer both options. Refusing to guess
  -- is only useful if the alternatives come with the refusal.
  if (select jsonb_array_length(candidates) from public.import_name_review
       where norm_name = public.dds_norm_name('MARIANO, ROBERT')) <> 2 then
    raise exception 'FAIL: ambiguous review row does not carry both candidates';
  end if;
end;
$$;

-- ── Ingest, chunk 2 ────────────────────────────────────────────────────────
-- The same unresolved name arrives again, plus a spacing variant of it. Both
-- must fold into the SAME review row: one decision, not three.

do $$
declare v_inserted integer;
begin
  v_inserted := public.dds_ingest('aaaaaaaa-0000-0000-0000-000000000001', $j$[
    {"UPDATE_TIME":"01/05/2026 09:00:00","START_TIME":"01/05/2026 08:00:00","ASSET_ID":"IT6","EVENT_CODE":"D","EVENT_COUNT":"1","OPERATOR":"WHO IS THIS"},
    {"UPDATE_TIME":"01/05/2026 09:05:00","START_TIME":"01/05/2026 08:05:00","ASSET_ID":"IT7","EVENT_CODE":"D","EVENT_COUNT":"1","OPERATOR":"who is  this"}
  ]$j$::jsonb);
  if v_inserted <> 2 then
    raise exception 'FAIL: chunk 2 inserted %, expected 2', v_inserted;
  end if;
end;
$$;

do $$
begin
  -- Still 2 review rows, not 4: the uq_import_name_review conflict target
  -- accumulated rather than duplicating.
  if (select count(*) from public.import_name_review
       where import_id='aaaaaaaa-0000-0000-0000-000000000001') <> 2 then
    raise exception 'FAIL: a repeated name created a second review row';
  end if;

  -- 1 from chunk 1 + 2 from chunk 2 (including the spacing variant).
  if (select row_count from public.import_name_review
       where norm_name = public.dds_norm_name('WHO IS THIS')) <> 3 then
    raise exception 'FAIL: row_count did not accumulate across chunks';
  end if;

  -- unresolved_count counts ROWS waiting, not names: 3 + 1.
  if (select unresolved_count from public.imports
       where id='aaaaaaaa-0000-0000-0000-000000000001') <> 4 then
    raise exception 'FAIL: imports.unresolved_count wrong';
  end if;
end;
$$;

-- ── Re-ingesting a chunk ───────────────────────────────────────────────────
-- A retried chunk must not double-count. uq_events_natural + do nothing.

do $$
declare v_inserted integer; v_before bigint;
begin
  select count(*) into v_before from public.events where asset_id like 'IT%';
  v_inserted := public.dds_ingest('aaaaaaaa-0000-0000-0000-000000000001', $j$[
    {"UPDATE_TIME":"01/05/2026 08:00:00","START_TIME":"01/05/2026 07:00:00","ASSET_ID":"IT1","EVENT_CODE":"D","EVENT_COUNT":"3","OPERATOR":"dela cruz, juan"}
  ]$j$::jsonb);
  if v_inserted <> 0 then
    raise exception 'FAIL: re-sent row was inserted again (%)', v_inserted;
  end if;
  if (select count(*) from public.events where asset_id like 'IT%') <> v_before then
    raise exception 'FAIL: re-ingest changed the row count';
  end if;
end;
$$;

-- ── Resolving a queued name ────────────────────────────────────────────────
-- The decision must (a) learn an alias, (b) re-attribute the events that were
-- waiting on it, and (c) close the queue row and update the import count.

do $$
declare v_id bigint; v_res jsonb;
begin
  select id into v_id from public.import_name_review
   where norm_name = public.dds_norm_name('MARIANO, ROBERT');

  v_res := public.dds_resolve_review(v_id, 'I003');

  if (v_res ->> 'rowsUpdated')::int <> 1 then
    raise exception 'FAIL: resolving did not re-attribute the waiting event: %', v_res;
  end if;

  if (select emp_no from public.events where asset_id='IT3') <> 'I003' then
    raise exception 'FAIL: event was not re-attributed after review';
  end if;

  -- The decision must be learned, so the same spelling never asks again.
  if not exists (select 1 from public.driver_aliases
     where norm_name = public.dds_norm_name('MARIANO, ROBERT')
       and emp_no = 'I003' and source = 'human') then
    raise exception 'FAIL: resolving did not write a human alias';
  end if;

  if (select state from public.import_name_review where id = v_id) <> 'resolved' then
    raise exception 'FAIL: queue row not closed';
  end if;

  -- Only the unknown name's 3 rows remain outstanding.
  if (select unresolved_count from public.imports
       where id='aaaaaaaa-0000-0000-0000-000000000001') <> 3 then
    raise exception 'FAIL: unresolved_count not refreshed after resolving';
  end if;
end;
$$;

-- A later import of the same misspelling must now resolve silently at tier 0.
-- This is the property that makes the queue shrink over time.
do $$
begin
  perform public.dds_ingest('aaaaaaaa-0000-0000-0000-000000000001', $j$[
    {"UPDATE_TIME":"01/06/2026 08:00:00","START_TIME":"01/06/2026 07:00:00","ASSET_ID":"IT8","EVENT_CODE":"D","EVENT_COUNT":"2","OPERATOR":"MARIANO, ROBERT"}
  ]$j$::jsonb);

  if (select emp_no from public.events where asset_id='IT8') <> 'I003' then
    raise exception 'FAIL: a learned alias did not apply on a later import';
  end if;
end;
$$;

-- ── Undo ───────────────────────────────────────────────────────────────────
-- A confirmed alias is durable, so a WRONG one is durable too. Reopening must
-- drop the alias AND un-attribute the events, or the queue and the data
-- disagree: the name would show as unresolved while its rows still pointed at
-- the employee just disavowed.

do $$
declare v_id bigint;
begin
  select id into v_id from public.import_name_review
   where norm_name = public.dds_norm_name('MARIANO, ROBERT');

  perform public.dds_reopen_review(v_id, true);

  if exists (select 1 from public.driver_aliases
       where norm_name = public.dds_norm_name('MARIANO, ROBERT')) then
    raise exception 'FAIL: reopening did not remove the alias';
  end if;

  if (select emp_no from public.events where asset_id='IT3') is not null then
    raise exception 'FAIL: reopening left events attributed to the disavowed employee';
  end if;

  if (select state from public.import_name_review where id = v_id) <> 'open' then
    raise exception 'FAIL: queue row not reopened';
  end if;
end;
$$;

-- ── Ignore ─────────────────────────────────────────────────────────────────
-- Not-a-driver. No alias is written: an ignore says the string is not a
-- person, not that it maps to one.

do $$
declare v_id bigint;
begin
  select id into v_id from public.import_name_review
   where norm_name = public.dds_norm_name('WHO IS THIS');

  perform public.dds_ignore_review(v_id);

  if (select state from public.import_name_review where id = v_id) <> 'ignored' then
    raise exception 'FAIL: queue row not ignored';
  end if;

  if exists (select 1 from public.driver_aliases
       where norm_name = public.dds_norm_name('WHO IS THIS')) then
    raise exception 'FAIL: ignoring wrote an alias';
  end if;

  -- The rows stay in events, still counted, still carrying their raw text.
  if (select count(*) from public.events
       where operator is not null
         and public.dds_norm_name(operator) = public.dds_norm_name('WHO IS THIS')) <> 3 then
    raise exception 'FAIL: ignoring a name removed its alert rows';
  end if;
end;
$$;

-- ── Backfill ───────────────────────────────────────────────────────────────
-- History must participate in the merge, not just new imports.

do $$
declare v_res jsonb;
begin
  -- An event that predates the masterlist: raw text, no emp_no.
  insert into public.events (update_time, start_time, asset_id, event_code, event_count, operator)
  values ('01/07/2026 08:00:00', '01/07/2026 07:00:00', 'ITB', 'D', 9, 'DELA CRUZ, JUAN');

  v_res := public.dds_backfill_emp_no(500);

  if (select emp_no from public.events where asset_id='ITB') <> 'I001' then
    raise exception 'FAIL: backfill did not attribute a historical row: %', v_res;
  end if;
end;
$$;

-- ── Telemetry ──────────────────────────────────────────────────────────────
-- The point of phase 2: report how resolution actually performed, so phase 4
-- can be gated on evidence rather than hope.

do $$
declare v jsonb;
begin
  v := public.dds_resolution_stats('aaaaaaaa-0000-0000-0000-000000000001');
  if v -> 'rows' ->> 'total' is null then
    raise exception 'FAIL: resolution stats returned no row totals: %', v;
  end if;
  if (v -> 'rows' ->> 'resolved')::int < 1 then
    raise exception 'FAIL: stats report nothing resolved: %', v;
  end if;
end;
$$;

select 'ALL INGEST RESOLUTION TESTS PASSED' as result;

rollback;
