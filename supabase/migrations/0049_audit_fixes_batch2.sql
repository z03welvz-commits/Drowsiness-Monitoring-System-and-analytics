-- ============================================================================
-- DDS — 0049_audit_fixes_batch2
-- ----------------------------------------------------------------------------
-- Three more independent fixes from the code-correctness audit. No table
-- structure changes beyond two additive indexes; nothing here is destructive.
--
-- 1. CORRECTION to 0033's header comment (documentation only, no functional
--    change — migration files are an append-only log, so this doesn't edit
--    0033 in place). 0033 claimed driver_master, driver_asset_actions, and
--    driver_asset_severity are unused ("nothing currently does" depend on
--    them). Checked against every migration through 0048: all three are
--    still actively read AND written today —
--      driver_master          <- dds_replace_drivers() (0005), truncated by
--                                 dds_reset_fleet_data() (0022); read by the
--                                 client's driver-picker autocomplete under
--                                 the driver_master_read RLS policy (0005).
--      driver_asset_actions   <- dds_log_driver_asset_action() (0007);
--                                 read by dds_entity_actions() (0007) and
--                                 dds_latest_entity_actions() (0008).
--      driver_asset_severity  <- direct client-side upsert under RLS (0020);
--                                 read by dds_driver_asset_severity() (0020).
--    None of the three is ever DROPped anywhere in 0001-0048. 0033's claim
--    is only true in the narrow sense "the new Monitoring feature doesn't
--    depend on them" — a future migration that drops these tables on the
--    strength of 0033's comment alone would break three live RPCs plus the
--    driver-picker autocomplete. This note is the correction; the tables
--    themselves need no change.
--
-- 2. events.start_time had no dedicated index. The client's upload-preflight
--    duplicate check (index.html, fetchExistingDdsKeys) filters this exact
--    column by range, and only the derived shift_date column was indexed —
--    a different value (shift_date is a local calendar date computed from
--    start_time; a raw start_time range does not reduce to a shift_date
--    range in general). Added as a plain btree index.
--
-- 3. alert_cases.emp_no (added 0026) had no index. Not filtered directly by
--    any current RPC, but dds_alert_logs() reads it via
--    coalesce(c.emp_no, e.emp_no) and dds_bulk_log_case_action() writes it
--    (0046) — adding the index now is cheap and forecloses a seq-scan trap
--    for any future "filter Alert Logs by emp_no directly" feature.
-- ============================================================================

create index if not exists idx_events_start_time on public.events (start_time);

create index if not exists idx_alert_cases_emp_no on public.alert_cases (emp_no)
  where emp_no is not null;
