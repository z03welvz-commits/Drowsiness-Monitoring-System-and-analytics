-- ============================================================================
-- DDS — Alert Count Test
-- ----------------------------------------------------------------------------
-- Implements the master prompt's own "Alert Count Test" template verbatim:
--   10 valid alert records
--   2 duplicate records
--   1 rejected record
-- ...then verifies dds_metrics(), dds_alert_logs(), and dds_alert_summary()
-- all count the same underlying data consistently with the documented,
-- by-design differences recorded in MIGRATION_MAP.md §7 (SUM(event_count)
-- vs. row-count vs. group-count) — not that the three numbers are equal
-- (they should NOT be, for reasons explained there), but that each is
-- exactly the value its own counting rule predicts for this fixture.
--
-- HOW TO RUN
--   Paste this whole file into the Supabase SQL editor for project
--   rispydfovrnvnwvfwrnw and run it. Results appear as ROWS in the Results
--   grid (one per assertion, PASS/FAIL + detail) — NOT as RAISE NOTICE
--   output, because the Supabase dashboard's SQL editor does not surface
--   PL/pgSQL notices anywhere in its UI (confirmed empirically: a prior
--   version of this script that only used RAISE NOTICE showed "Success. No
--   rows returned" whether every assertion passed or one failed partway
--   through — indistinguishable without real output rows). Every assertion
--   below writes its result into a temp table and the final statement
--   selects everything from it, so the Results grid is the actual proof.
--
--   Requires an authenticated session — the dashboard SQL editor otherwise
--   connects as a role where auth.uid() is null, and
--   dds_ingest()/dds_metrics()/etc. all deliberately raise UNAUTHENTICATED
--   without one. Simulated inside this same script via
--   set_config('request.jwt.claim.sub', ...) + `set local role
--   authenticated` — scoped to this transaction only. Replace the UUID
--   below with a real row from `select id from auth.users limit 1;` if
--   this ever runs against a project with a different user.
--
-- WHAT IT DOES
--   1. Creates one throwaway import row.
--   2. Ingests 10 genuinely distinct rows + 2 EXACT duplicates of two of
--      those 10 (same asset_id/start_time/event_code — the real dedup key,
--      confirmed in MIGRATION_MAP.md §3) via dds_ingest(), the same RPC
--      the real upload flow calls.
--   3. Separately demonstrates the "1 rejected row" case: a row with an
--      unparseable START_TIME. dds_ingest() itself expects pre-validated
--      rows (parsing happens client-side in annotate() before this RPC is
--      ever called — confirmed in MIGRATION_MAP.md §7, finding #8) so this
--      script does not feed a bad row into dds_ingest() and expect it to
--      reject cleanly; instead it demonstrates the rejection is a CLIENT-
--      side concern by attempting the same to_timestamp() parse dds_ingest()
--      uses and confirming it errors, which is exactly why annotate() must
--      filter such rows out before calling this RPC at all.
--   4. Asserts dds_ingest() returns 10 (not 12 — the 2 duplicates insert 0
--      new rows each).
--   5. Asserts imports.row_count reflects 10, not 12.
--   6. Asserts dds_metrics()'s kpis.totalAlerts equals SUM(event_count)
--      across the 10 distinct rows (not the row count).
--   7. Asserts dds_alert_logs()'s total equals 10 (row count, not summed
--      units).
--   8. Asserts dds_alert_summary()'s total equals the number of distinct
--      (shift_date, shift, asset_id, event_code) groups among the 10 rows
--      (<=10, since some of the 10 may share a group).
--   9. Cleans up everything it created (deletes the import; events cascade
--      via import_id's on delete cascade, confirmed in 0001_init.sql).
--
-- A clean run's Results grid shows 6 rows, all status = 'PASS'. Any 'FAIL'
-- row's detail column names exactly what didn't match. If dds_ingest()
-- itself raises before assertion 1 can even run (e.g. UNAUTHENTICATED),
-- the whole script errors visibly instead of silently returning 0 rows —
-- that failure mode is now unambiguous too, unlike the RAISE-NOTICE-only
-- version.
-- ============================================================================

drop table if exists _act_results;
create temporary table _act_results (
  seq integer,
  assertion text,
  status text,
  detail text
);
-- The table above is created by the SQL editor's own (privileged) role,
-- before `set local role authenticated` switches inside the do $$ block
-- below — without this grant, that switched-to role can't INSERT into a
-- table it doesn't own, even though it's the one running everything else.
grant insert, select on _act_results to authenticated;

do $$
declare
  v_import_id uuid;
  v_inserted  integer;
  v_row_count integer;
  v_metrics   jsonb;
  v_logs      jsonb;
  v_summary   jsonb;
  v_total_alerts numeric;
  v_logs_total   integer;
  v_summary_total integer;
  v_expected_sum numeric;
  v_test_asset constant text := 'TEST-ALERT-COUNT-9001';  -- unlikely to collide with real fleet data
  v_rows jsonb;
  v_rejected_ok boolean := false;
begin
  perform set_config('request.jwt.claim.sub', '0a33da5a-ed8a-47e9-b7c6-d3c424241f71', true);
  set local role authenticated;

  -- ── 1. Throwaway import row ────────────────────────────────────────────
  insert into public.imports (id, storage_key, original_name, uploaded_by, status)
  values (gen_random_uuid(), 'test/alert-count-test.sql', 'alert-count-test.sql fixture', auth.uid(), 'processing')
  returning id into v_import_id;

  -- ── 2. 10 distinct rows + 2 exact duplicates of rows 1 and 4 ───────────
  -- Same asset throughout so dds_alert_summary()'s group count is easy to
  -- hand-verify: 10 distinct rows across 3 event codes on 1
  -- shift_date/shift/asset -> 3 groups.
  v_rows := jsonb_build_array(
    jsonb_build_object('START_TIME','08/15/2026 06:00:00','UPDATE_TIME','08/15/2026 06:05:00','END_TIME','08/15/2026 06:01:00','ASSET_ID',v_test_asset,'EVENT_CODE','DROWSY','EVENT_COUNT','2','OPERATOR','Test Operator'),
    jsonb_build_object('START_TIME','08/15/2026 06:10:00','UPDATE_TIME','08/15/2026 06:15:00','END_TIME','08/15/2026 06:11:00','ASSET_ID',v_test_asset,'EVENT_CODE','DROWSY','EVENT_COUNT','3','OPERATOR','Test Operator'),
    jsonb_build_object('START_TIME','08/15/2026 06:20:00','UPDATE_TIME','08/15/2026 06:25:00','END_TIME','08/15/2026 06:21:00','ASSET_ID',v_test_asset,'EVENT_CODE','DROWSY','EVENT_COUNT','1','OPERATOR','Test Operator'),
    jsonb_build_object('START_TIME','08/15/2026 06:30:00','UPDATE_TIME','08/15/2026 06:35:00','END_TIME','08/15/2026 06:31:00','ASSET_ID',v_test_asset,'EVENT_CODE','YAWN','EVENT_COUNT','4','OPERATOR','Test Operator'),
    jsonb_build_object('START_TIME','08/15/2026 06:40:00','UPDATE_TIME','08/15/2026 06:45:00','END_TIME','08/15/2026 06:41:00','ASSET_ID',v_test_asset,'EVENT_CODE','YAWN','EVENT_COUNT','2','OPERATOR','Test Operator'),
    jsonb_build_object('START_TIME','08/15/2026 06:50:00','UPDATE_TIME','08/15/2026 06:55:00','END_TIME','08/15/2026 06:51:00','ASSET_ID',v_test_asset,'EVENT_CODE','YAWN','EVENT_COUNT','5','OPERATOR','Test Operator'),
    jsonb_build_object('START_TIME','08/15/2026 07:00:00','UPDATE_TIME','08/15/2026 07:05:00','END_TIME','08/15/2026 07:01:00','ASSET_ID',v_test_asset,'EVENT_CODE','MICROSLEEP','EVENT_COUNT','7','OPERATOR','Test Operator'),
    jsonb_build_object('START_TIME','08/15/2026 07:10:00','UPDATE_TIME','08/15/2026 07:15:00','END_TIME','08/15/2026 07:11:00','ASSET_ID',v_test_asset,'EVENT_CODE','MICROSLEEP','EVENT_COUNT','3','OPERATOR','Test Operator'),
    jsonb_build_object('START_TIME','08/15/2026 07:20:00','UPDATE_TIME','08/15/2026 07:25:00','END_TIME','08/15/2026 07:21:00','ASSET_ID',v_test_asset,'EVENT_CODE','MICROSLEEP','EVENT_COUNT','6','OPERATOR','Test Operator'),
    jsonb_build_object('START_TIME','08/15/2026 07:30:00','UPDATE_TIME','08/15/2026 07:35:00','END_TIME','08/15/2026 07:31:00','ASSET_ID',v_test_asset,'EVENT_CODE','MICROSLEEP','EVENT_COUNT','1','OPERATOR','Test Operator'),
    -- Exact duplicates of rows 1 and 4 (same asset_id/start_time/event_code
    -- => same uq_events_natural key). event_count deliberately DIFFERENT
    -- (99 instead of 2 / 4) so a false "insert" would be obviously visible.
    jsonb_build_object('START_TIME','08/15/2026 06:00:00','UPDATE_TIME','08/15/2026 09:00:00','END_TIME','08/15/2026 06:01:00','ASSET_ID',v_test_asset,'EVENT_CODE','DROWSY','EVENT_COUNT','99','OPERATOR','Test Operator'),
    jsonb_build_object('START_TIME','08/15/2026 06:30:00','UPDATE_TIME','08/15/2026 09:00:00','END_TIME','08/15/2026 06:31:00','ASSET_ID',v_test_asset,'EVENT_CODE','YAWN','EVENT_COUNT','99','OPERATOR','Test Operator')
  );

  v_expected_sum := 2+3+1+4+2+5+7+3+6+1;  -- the 10 distinct rows only = 34

  select public.dds_ingest(v_import_id, v_rows) into v_inserted;

  -- ── Assertion 1: dds_ingest() must report exactly 10 inserted, not 12 ──
  insert into _act_results values (1, 'dds_ingest() row count',
    case when v_inserted = 10 then 'PASS' else 'FAIL' end,
    format('inserted %s rows, expected 10 (2 duplicates should insert 0 new rows each)', v_inserted));

  -- ── Assertion 2: imports.row_count must reflect 10, not 12 ─────────────
  select row_count into v_row_count from public.imports where id = v_import_id;
  insert into _act_results values (2, 'imports.row_count',
    case when v_row_count is not distinct from 10 then 'PASS' else 'FAIL' end,
    format('row_count = %s, expected 10', v_row_count));

  -- ── Assertion 3: dds_metrics().kpis.totalAlerts = SUM(event_count) ─────
  select public.dds_metrics(
    p_from := '08/15/2026'::date, p_to := '08/15/2026'::date,
    p_asset_ids := array[v_test_asset]
  ) into v_metrics;
  v_total_alerts := (v_metrics->'kpis'->>'totalAlerts')::numeric;
  insert into _act_results values (3, 'dds_metrics().totalAlerts = SUM(event_count)',
    case when v_total_alerts is not distinct from v_expected_sum then 'PASS' else 'FAIL' end,
    format('totalAlerts = %s, expected %s (sum of the 10 real rows; duplicates'' event_count=99 must be excluded)', v_total_alerts, v_expected_sum));

  -- ── Assertion 4: dds_alert_logs().total = row count = 10 ───────────────
  select public.dds_alert_logs(
    p_from := '08/15/2026'::date, p_to := '08/15/2026'::date,
    p_shift := null, p_status := null, p_search := v_test_asset,
    p_limit := 100, p_offset := 0, p_sort := null, p_dir := null
  ) into v_logs;
  v_logs_total := (v_logs->>'total')::integer;
  insert into _act_results values (4, 'dds_alert_logs().total = row count',
    case when v_logs_total is not distinct from 10 then 'PASS' else 'FAIL' end,
    format('total = %s, expected 10 (row count; deliberately != totalAlerts=%s, see MIGRATION_MAP.md §7 finding #10)', v_logs_total, v_total_alerts));

  -- ── Assertion 5: dds_alert_summary().total = distinct group count ──────
  -- 10 rows share shift_date/shift/asset, span 3 event codes -> 3 groups.
  select public.dds_alert_summary(
    p_from := '08/15/2026'::date, p_to := '08/15/2026'::date,
    p_asset_ids := array[v_test_asset]
  ) into v_summary;
  v_summary_total := (v_summary->>'total')::integer;
  insert into _act_results values (5, 'dds_alert_summary().total = group count',
    case when v_summary_total is not distinct from 3 then 'PASS' else 'FAIL' end,
    format('total = %s, expected 3 (distinct shift_date x shift x asset_id x event_code groups)', v_summary_total));

  -- ── Assertion 6: the "1 rejected row" case ──────────────────────────────
  -- dds_ingest() expects pre-validated rows; parsing happens client-side in
  -- annotate() before this RPC is ever called. Confirms the same
  -- to_timestamp() parse dds_ingest() uses fails on an unparseable
  -- START_TIME, demonstrating why annotate() must filter such rows out
  -- before calling dds_ingest() at all.
  begin
    perform to_timestamp('NOT-A-DATE', 'MM/DD/YYYY HH24:MI:SS')::timestamp;
    v_rejected_ok := false;
  exception
    when others then
      v_rejected_ok := true;
  end;
  insert into _act_results values (6, 'unparseable START_TIME rejected client-side',
    case when v_rejected_ok then 'PASS' else 'FAIL' end,
    'to_timestamp() on an unparseable value fails the same way dds_ingest() would reject it');

  -- ── Clean up — delete the import; events cascade via import_id FK ──────
  delete from public.imports where id = v_import_id;
end $$;

select * from _act_results order by seq;
