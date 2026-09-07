-- ============================================================================
-- DDS — case_records_minestat_raw_name_fallback
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- Inferred intent: the dds_case_records view's driver_display/driver_needs_review
-- previously fell back only to the raw events.operator text when no case,
-- resolved driver, or events.emp_no match existed. The live definition adds
-- one more fallback rung below that: for events with a null emp_no, a
-- LATERAL join picks the most-recently-updated minestat_shifts row for the
-- same asset/shift_date/shift whose own emp_no is still unresolved (null)
-- and isn't the 'no_operator' sentinel tier, and uses its raw "Last, First
-- Middle" name (ms.raw_name) as a last-resort display name. driver_display
-- now coalesces: case.driver_name -> case's driver's full_name ->
-- event's driver's full_name -> events.operator -> ms.raw_name. This lets an
-- alert row show a plausible operator name (and be flagged needs-review)
-- even when only MineStat has an unresolved name for that shift and no case
-- has been logged yet.
-- ============================================================================

create or replace view public.dds_case_records as
 SELECT e.id AS event_id,
    e.shift_date,
    e.shift,
    e.asset_id,
    e.emp_no,
    COALESCE(e.emp_no, 'UNSPECIFIED'::text) AS emp_no_norm,
    d.full_name AS emp_name,
    e.operator,
    e.event_code,
    e.event_count,
    e.start_time,
    e.end_time,
    e.update_time,
    e.sync_seconds,
    e.actionable,
    c.id AS case_id,
    c.driver_name AS case_driver_name,
    c.emp_no AS case_emp_no,
    dc.full_name AS case_emp_name,
    c.action_type AS action_performed,
    c.action_is_other,
    c.action_date,
    c.status_value AS status,
    c.status_is_other,
    c.remarks,
    c.updated_at AS case_updated_at,
    c.updated_by AS case_updated_by,
    pu.username AS action_by,
    COALESCE(NULLIF(c.driver_name, ''::text), dc.full_name, d.full_name, NULLIF(e.operator, ''::text), ms.raw_name) AS driver_display,
    COALESCE(c.emp_no, e.emp_no) AS emp_no_display,
    (e.event_code ~~* '%sleep%'::text OR e.event_code ~~* '%drowsi%'::text) AND c.status_value IS NULL AS is_unresolved_high_severity,
    COALESCE(c.emp_no, e.emp_no) IS NULL AND COALESCE(NULLIF(c.driver_name, ''::text), NULLIF(e.operator, ''::text), ms.raw_name) IS NOT NULL AS driver_needs_review
   FROM events e
     LEFT JOIN alert_cases c ON c.event_id = e.id
     LEFT JOIN drivers d ON d.emp_no = e.emp_no
     LEFT JOIN drivers dc ON dc.emp_no = c.emp_no
     LEFT JOIN profiles pu ON pu.user_id = c.updated_by
     LEFT JOIN LATERAL ( SELECT (COALESCE(m.last_name, ''::text) || ', '::text) || TRIM(BOTH FROM (COALESCE(m.first_name, ''::text) || ' '::text) || COALESCE(m.middle_name, ''::text)) AS raw_name
           FROM minestat_shifts m
          WHERE m.asset_id = e.asset_id AND m.shift_date = e.shift_date AND m.shift = e.shift AND m.emp_no IS NULL AND m.tier IS DISTINCT FROM 'no_operator'::text
          ORDER BY m.updated_at DESC
         LIMIT 1) ms ON e.emp_no IS NULL;
