-- ============================================================================
-- DDS — 0094_case_records_minestat_raw_name_fallback
-- ----------------------------------------------------------------------------
-- Direct instruction: show a driver's name even when it never matched the
-- Employee Masterlist, as long as it matches real DDS or MineStat data —
-- and flag that name for review rather than showing it as if it were a
-- confirmed identity.
--
-- dds_case_records' driver_display already fell back to DDS's own raw
-- operator text when no masterlist emp_no was found (NULLIF(e.operator,''))
-- — that part already existed. The gap: when DDS's own operator field is
-- ALSO blank (nothing captured on the device side) but MineStat recorded a
-- real name for that exact asset+shift_date+shift that simply never
-- resolved to any masterlist emp_no (dds_resolve_name tier 'none' or
-- 'fuzzy_review'), there was no path to that name at all — the event
-- showed as flatly unspecified even though a name existed one join away.
-- Confirmed live before this change: DT-674, 2026-01-02 NIGHT has 3 real
-- Sleep Alert events with emp_no/operator both null, while
-- minestat_shifts for that exact asset+date+shift already has "LUTCHAVEZ,
-- ALBERT N" sitting unresolved (tier 'none') — the name was always there,
-- nothing surfaced it.
--
-- Adds one LATERAL fallback (only evaluated when e.emp_no is null, so it
-- costs nothing for the common resolved case) plus an explicit
-- driver_needs_review boolean — true only when no masterlist emp_no was
-- found ANYWHERE (case override or event) but a real name still surfaced
-- from DDS's own unresolved operator text or this new MineStat fallback.
-- Deliberately excludes the genuine "No Operator" shift (tier =
-- 'no_operator' is filtered out of the fallback join itself) — that case
-- has nothing to review, nobody was driving.
--
-- Verified live before applying, three cases:
--   - DT-674 / 2026-01-02 NIGHT (the real unresolved-name case above):
--     driver_display now "LUTCHAVEZ, ALBERT N", driver_needs_review true.
--   - DT-674 / 2026-08-31 (already-resolved Hontiveros/9650237 case):
--     unchanged, driver_needs_review false — no regression on a real match.
--   - A genuine no-operator shift (DT-649 / 2026-09-01 NIGHT):
--     driver_display stays null, driver_needs_review false.
--
-- New column appended at the END of the view (Postgres's CREATE OR REPLACE
-- VIEW cannot reorder or insert a column mid-list without dropping the
-- view first) so every existing SELECT * or positional consumer is
-- unaffected.
-- ============================================================================

create or replace view public.dds_case_records as
select e.id as event_id,
    e.shift_date,
    e.shift,
    e.asset_id,
    e.emp_no,
    coalesce(e.emp_no, 'UNSPECIFIED'::text) as emp_no_norm,
    d.full_name as emp_name,
    e.operator,
    e.event_code,
    e.event_count,
    e.start_time,
    e.end_time,
    e.update_time,
    e.sync_seconds,
    e.actionable,
    c.id as case_id,
    c.driver_name as case_driver_name,
    c.emp_no as case_emp_no,
    dc.full_name as case_emp_name,
    c.action_type as action_performed,
    c.action_is_other,
    c.action_date,
    c.status_value as status,
    c.status_is_other,
    c.remarks,
    c.updated_at as case_updated_at,
    c.updated_by as case_updated_by,
    pu.username as action_by,
    coalesce(nullif(c.driver_name, ''::text), dc.full_name, d.full_name, nullif(e.operator, ''::text), ms.raw_name) as driver_display,
    coalesce(c.emp_no, e.emp_no) as emp_no_display,
    (e.event_code ~~* '%sleep%'::text or e.event_code ~~* '%drowsi%'::text) and c.status_value is null as is_unresolved_high_severity,
    (coalesce(c.emp_no, e.emp_no) is null
     and coalesce(nullif(c.driver_name, ''::text), nullif(e.operator, ''::text), ms.raw_name) is not null
    ) as driver_needs_review
from events e
    left join alert_cases c on c.event_id = e.id
    left join drivers d on d.emp_no = e.emp_no
    left join drivers dc on dc.emp_no = c.emp_no
    left join profiles pu on pu.user_id = c.updated_by
    left join lateral (
      select (coalesce(m.last_name, '') || ', ' || trim(coalesce(m.first_name, '') || ' ' || coalesce(m.middle_name, ''))) as raw_name
      from public.minestat_shifts m
      where m.asset_id = e.asset_id and m.shift_date = e.shift_date and m.shift = e.shift
        and m.emp_no is null and m.tier is distinct from 'no_operator'
      order by m.updated_at desc
      limit 1
    ) ms on e.emp_no is null;
