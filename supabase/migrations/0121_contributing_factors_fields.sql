-- ============================================================================
-- DDS — 0121_contributing_factors_fields
-- ----------------------------------------------------------------------------
-- Contributing Factors' manual-entry form only ever captured Factor
-- (detail) and Category (factor_type) — start_time was silently set to
-- "now" at save time, standing in for both "when this happened" and "when
-- it was logged". Per direct instruction the manual form now captures:
-- Date, Shift, Type of factors, Description, Duration (hrs), with Time Lag
-- shown as an automated timestamp rather than typed in.
--
-- Date/Type of factors/Description reuse the existing start_time/
-- factor_type/detail columns (start_time is now the picked Date, not
-- "now"). Time Lag reuses the existing logged_at column, already a
-- DB-side now() default — no schema change needed for it. Shift and
-- Duration (hrs) have no existing column, hence this migration.
-- Both nullable: the 126 rows already logged before this change have
-- neither value, and there's no way to backfill either from what was
-- captured at the time.
-- ============================================================================
alter table public.contributing_factors
  add column if not exists shift text check (shift in ('DAY', 'NIGHT')),
  add column if not exists duration_hours numeric check (duration_hours >= 0);
