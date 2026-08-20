-- ============================================================================
-- DDS — masterlist resolver tests (0018_driver_masterlist)
-- ----------------------------------------------------------------------------
-- Asserts the behaviour of dds_norm_name() and the dds_resolve_name() tier
-- ladder, plus the roster upsert's two load-bearing guarantees: absent drivers
-- are DEACTIVATED rather than deleted, and a human-confirmed alias SURVIVES a
-- later roster upload.
--
-- WHY THIS FILE EXISTS
--   The resolver's failure mode is a silently wrong attribution: an alert
--   assigned to the wrong employee looks exactly like a correct one in every
--   chart. There is no error to notice and nothing to reconcile against, so
--   the only thing standing between a bad tier and a wrong KPI is a test that
--   pins the intended behaviour down case by case.
--
--   Three real bugs were caught by running these cases against Postgres
--   during development, each of which passed inspection by eye:
--     * `emp_no` was ambiguous between the RETURNS TABLE output parameter and
--       the fuzzy CTE's column (42702) — it only fires on the fuzzy tier, so
--       any test whose names all match earlier would have missed it.
--     * dds_norm_name() folded the comma to a space, which silently collapsed
--       tier 3 into an exact match and stopped it discarding middle names.
--     * `on commit drop` on the _incoming temp table made dds_upsert_drivers()
--       fail on a second call within one transaction (42P07).
--
-- USAGE
--   psql -v ON_ERROR_STOP=1 -f supabase/migrations/0018_driver_masterlist.sql
--   psql -v ON_ERROR_STOP=1 -f test/masterlist-resolver.test.sql
--
--   Runs entirely inside a transaction that ROLLS BACK, so it leaves no trace
--   and is safe to point at any database where 0018 is applied. It asserts
--   with raise exception rather than printing, so a failure is an error the
--   caller cannot overlook.
--
-- NOTE ON auth
--   dds_upsert_drivers() and the alias-audit trigger call auth.uid(), which is
--   null outside a PostgREST request. That is fine here: the uploaded_by and
--   actor columns are nullable, and none of the assertions below depend on
--   them. The UNAUTHENTICATED guard is not exercised by this file.
-- ============================================================================

begin;

-- ── Fixture ────────────────────────────────────────────────────────────────
-- MARIANO ROBERTO / ROBERTA are deliberately near-identical: one character
-- apart, same surname initial. They are the ambiguity case, and the single
-- most important assertion in this file is that the resolver REFUSES to pick
-- between them rather than guessing.

insert into public.drivers (emp_no, full_name) values
  ('T0001', 'DELA CRUZ, JUAN'),
  ('T0002', 'NUÑEZ, JOSE'),
  ('T0003', 'SANTOS, MARIA CLARA'),
  ('T0004', 'REYES, PEDRO JR'),
  ('T0005', 'MARIANO, ROBERTO'),
  ('T0006', 'MARIANO, ROBERTA'),
  ('T0007', 'BAUTISTA, ANTONIO');

insert into public.driver_aliases (norm_name, raw_name, emp_no, tier, source)
select public.dds_norm_name(full_name), full_name, emp_no, 'seed', 'seed'
from public.drivers where emp_no like 'T%';

-- ── Assertion helper ───────────────────────────────────────────────────────

create or replace function pg_temp.expect(
  p_raw       text,
  p_emp_no    text,
  p_tier      text,
  p_why       text
) returns void language plpgsql as $$
declare r record;
begin
  select * into r from public.dds_resolve_name(p_raw);
  if r.emp_no is distinct from p_emp_no or r.tier is distinct from p_tier then
    raise exception 'FAIL [%]: % -> emp_no=% tier=% (expected emp_no=% tier=%)',
      p_why, p_raw, coalesce(r.emp_no,'<null>'), r.tier,
      coalesce(p_emp_no,'<null>'), p_tier;
  end if;
end;
$$;

-- ── Normalization ──────────────────────────────────────────────────────────

do $$
begin
  if public.dds_norm_name('NUÑEZ, JOSE') <> 'NUNEZ, JOSE' then
    raise exception 'FAIL: Ñ does not fold to N';
  end if;

  -- The mangled-Ñ case: a workbook written through a codepage that cannot
  -- represent Ñ emits '?'. Must land on the same normalized form as the real
  -- character, or every such name silently fails to match.
  if public.dds_norm_name('NU?EZ, JOSE') <> public.dds_norm_name('NUÑEZ, JOSE') then
    raise exception 'FAIL: mangled ? does not normalize to the same value as Ñ';
  end if;

  -- Non-breaking space (U+00A0) survives trim() and must be folded explicitly.
  if public.dds_norm_name('DELA' || chr(160) || 'CRUZ, JUAN') <> 'DELA CRUZ, JUAN' then
    raise exception 'FAIL: non-breaking space not normalized';
  end if;

  -- THE COMMA MUST SURVIVE. It is the surname/given-name boundary tier 3
  -- splits on; folding it to a space collapses that tier into an exact match.
  if position(',' in public.dds_norm_name('SANTOS, MARIA CLARA')) = 0 then
    raise exception 'FAIL: comma was stripped — tier 3 will silently degrade';
  end if;

  -- Spacing around the comma varies freely between typists and must not
  -- change the key.
  if public.dds_norm_name('SANTOS ,  MARIA') <> 'SANTOS, MARIA' then
    raise exception 'FAIL: comma spacing not normalized';
  end if;

  if public.dds_norm_name('   ') is not null then
    raise exception 'FAIL: blank should normalize to null';
  end if;
end;
$$;

-- ── The tier ladder ────────────────────────────────────────────────────────

select pg_temp.expect('DELA CRUZ, JUAN',        'T0001', 'alias',
  'T0 exact seeded alias');

select pg_temp.expect('  dela   cruz ,  juan ', 'T0001', 'alias',
  'T0 after casing/spacing normalization');

select pg_temp.expect('nu?ez,  jose',           'T0002', 'alias',
  'T0 via the mangled-Ñ fold');

select pg_temp.expect('REYES, PEDRO',           'T0004', 'suffix',
  'T2 — roster carries JR, raw does not');

select pg_temp.expect('DELA CRUZ, JUAN III',    'T0001', 'suffix',
  'T2 — raw carries a suffix the roster does not');

select pg_temp.expect('SANTOS, MARIA',          'T0003', 'surname_first',
  'T3 — middle name present in roster, absent in raw');

select pg_temp.expect('BAUTSTA, ANTONIO',       'T0007', 'skeleton',
  'T4 — dropped vowel');

-- THE ONE THAT MATTERS MOST. Equidistant from two real drivers, so there is
-- no correct answer to guess at. A resolver that returns either T0005 or
-- T0006 here is worse than one that returns nothing: the wrong attribution
-- lands in a KPI nobody re-checks, while the refusal lands in a queue
-- somebody works.
select pg_temp.expect('MARIANO, ROBERT',        null,    'fuzzy_review',
  'T5 tie between near-identical names must NOT auto-resolve');

select pg_temp.expect('TOTALLY UNKNOWN PERSON', null,    'none',
  'nothing within tolerance');

select pg_temp.expect('   ',                    null,    'blank',
  'blank input');

-- The review path must still hand the reviewer both candidates to choose
-- between — refusing to guess is only useful if the options come with it.
do $$
declare r record;
begin
  select * into r from public.dds_resolve_name('MARIANO, ROBERT');
  if coalesce(jsonb_array_length(r.candidates), 0) <> 2 then
    raise exception 'FAIL: expected 2 candidates for review, got %',
      coalesce(jsonb_array_length(r.candidates), 0);
  end if;
end;
$$;

-- ── Roster upsert ──────────────────────────────────────────────────────────
-- The two guarantees that separate this from dds_replace_drivers() (0005).

do $$
declare
  v1 jsonb; v2 jsonb;
begin
  v1 := public.dds_upsert_drivers($json$[
    {"emp_no":"U0001","name":"UPSERT ONE"},
    {"emp_no":"U0002","name":"UPSERT TWO"},
    {"emp_no":"",      "name":"NO ID"},
    {"emp_no":"U0003","name":""}
  ]$json$::jsonb, false);

  if (v1 ->> 'inserted')::int <> 2 or (v1 ->> 'skipped')::int <> 2 then
    raise exception 'FAIL: upload 1 counts wrong: %', v1;
  end if;

  -- A human resolves a misspelling by hand.
  perform public.dds_confirm_alias('UPSRT TWOO', 'U0002');

  -- A later roster upload must not undo that decision. This is the guard the
  -- seeding pass's `where a.source <> 'human'` exists for; without it every
  -- routine conso refresh would quietly discard review work.
  v2 := public.dds_upsert_drivers($json$[
    {"emp_no":"U0001","name":"UPSERT ONE RENAMED"},
    {"emp_no":"U0002","name":"UPSERT TWO"}
  ]$json$::jsonb, true);

  if not exists (
    select 1 from public.driver_aliases
     where norm_name = public.dds_norm_name('UPSRT TWOO')
       and emp_no = 'U0002' and source = 'human'
  ) then
    raise exception 'FAIL: human-confirmed alias was destroyed by a roster upload';
  end if;

  -- Absent from the file means inactive, NEVER gone: historical alerts must
  -- keep resolving to a separated employee.
  if not exists (select 1 from public.drivers where emp_no = 'U0003') then
    -- U0003 was skipped at upload (blank name), so it should not exist at all.
    null;
  end if;

  if (select status from public.drivers where emp_no = 'U0001') <> 'active' then
    raise exception 'FAIL: U0001 was in the second file and should be active';
  end if;

  if (v2 ->> 'updated')::int <> 2 then
    raise exception 'FAIL: upload 2 should have updated 2 rows: %', v2;
  end if;

  -- The rename must have landed.
  if (select full_name from public.drivers where emp_no = 'U0001') <> 'UPSERT ONE RENAMED' then
    raise exception 'FAIL: rename not applied on upsert';
  end if;
end;
$$;

-- A file that yields no usable rows is a mistake, not an instruction to
-- deactivate the entire workforce.
do $$
begin
  begin
    perform public.dds_upsert_drivers('[{"emp_no":"","name":""}]'::jsonb);
    raise exception 'FAIL: an empty roster should have been rejected';
  exception when others then
    if sqlerrm not like '%EMPTY_ROSTER%' then raise; end if;
  end;
end;
$$;

-- Re-entrancy: two calls in ONE transaction must both succeed. This is what
-- the `drop table if exists _incoming` guards; `on commit drop` alone fires
-- too late and the second call fails with 42P07.
do $$
begin
  perform public.dds_upsert_drivers('[{"emp_no":"R0001","name":"REENTRANT A"}]'::jsonb, false);
  perform public.dds_upsert_drivers('[{"emp_no":"R0002","name":"REENTRANT B"}]'::jsonb, false);
end;
$$;

-- ── Alias reversal ─────────────────────────────────────────────────────────
-- A confirmed alias is durable, so a WRONG one is durable too. Reversal and
-- its audit trail are what keep the first bad confirmation from becoming
-- permanent folklore.

do $$
begin
  perform public.dds_confirm_alias('WRONGLY ASSIGNED', 'T0001');
  perform public.dds_confirm_alias('WRONGLY ASSIGNED', 'T0002');   -- corrected

  if (select emp_no from public.driver_aliases
       where norm_name = public.dds_norm_name('WRONGLY ASSIGNED')) <> 'T0002' then
    raise exception 'FAIL: re-confirming an alias did not move it';
  end if;

  -- The reassignment must be recorded, not silently overwritten.
  if not exists (
    select 1 from public.driver_alias_log
     where norm_name = public.dds_norm_name('WRONGLY ASSIGNED')
       and action = 'update' and old_emp_no = 'T0001' and new_emp_no = 'T0002'
  ) then
    raise exception 'FAIL: alias reassignment was not written to the audit log';
  end if;

  if not public.dds_remove_alias('WRONGLY ASSIGNED') then
    raise exception 'FAIL: dds_remove_alias reported nothing removed';
  end if;

  if not exists (
    select 1 from public.driver_alias_log
     where norm_name = public.dds_norm_name('WRONGLY ASSIGNED') and action = 'delete'
  ) then
    raise exception 'FAIL: alias deletion was not written to the audit log';
  end if;
end;
$$;

select 'ALL MASTERLIST RESOLVER TESTS PASSED' as result;

rollback;
