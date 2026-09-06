-- ============================================================================
-- DDS — 0062_events_unspecified_index
-- ----------------------------------------------------------------------------
-- FIX: dds_driver_asset_weekly() times out against the app's 8s
-- statement_timeout (authenticated role), even though it runs in ~2s over a
-- direct connection — reproduced live via Playwright: the Driver & Asset
-- Monitoring page's High/Medium/Low Risk tiles always show 0 while the
-- table below (a different RPC) shows real data. Root cause, found via
-- EXPLAIN ANALYZE: idx_events_emp_no / idx_events_emp_no_date (0019) are
-- BOTH partial indexes scoped `WHERE emp_no IS NOT NULL` — deliberately, to
-- keep them small while most of history was unresolved. But
-- dds_current_streak('driver', 'UNSPECIFIED') (called once per entity by
-- dds_driver_asset_weekly, and by the events-insert trigger
-- dds_entity_status_reopen) needs exactly the OPPOSITE rows: every event
-- with emp_no IS NULL. With no index covering that case, this one call
-- (out of ~84 in a typical week) falls back to a full Seq Scan with an
-- external disk sort — confirmed via EXPLAIN ANALYZE (53ms alone, vs 5ms
-- for the equivalent indexed asset_id lookup), and the dominant cost in a
-- ~2s total runtime that intermittently exceeds 8s under concurrent load
-- on a busier pooled connection.
--
-- This adds the complementary partial index the NULL-emp_no case was
-- always missing — same shape as idx_events_emp_no_date, just inverted.
-- Only the driver branch of dds_current_streak's WHERE clause needs this:
-- coalesce(emp_no, 'UNSPECIFIED') = 'UNSPECIFIED' is satisfiable only when
-- emp_no IS NULL, and that branch groups by shift_date alone (no asset_id
-- filter) — verified against the function's own source, not assumed.
-- ============================================================================

create index if not exists idx_events_unspecified_date
  on public.events (shift_date)
  where emp_no is null;
