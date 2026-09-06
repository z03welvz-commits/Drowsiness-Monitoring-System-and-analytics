-- ============================================================================
-- DDS — 0066_drop_orphaned_fns_correct_signatures
-- ----------------------------------------------------------------------------
-- 0058's cleanup pass intended to drop dds_alert_summary, dds_entity_day_
-- breakdown, and dds_metrics_multi as confirmed-orphaned (zero references
-- in index.html, zero pg_depend dependents), alongside 9 other objects.
-- Verified after the fact (a routine "is everything actually applied"
-- check) that all 9 others were correctly dropped, but these 3 were NOT —
-- 0058 guessed their argument signatures from stale local migration files
-- instead of querying the live pg_proc, and `DROP FUNCTION IF EXISTS
-- name(wrong_signature)` silently no-ops on a signature mismatch rather
-- than erroring. The real live signatures (confirmed via
-- pg_get_function_identity_arguments before this migration was written):
--   dds_alert_summary(date, date, text, text[], text[], text, integer, integer)
--   dds_entity_day_breakdown(text, text, integer, date, date)
--   dds_metrics_multi(jsonb)
-- Re-confirmed zero pg_depend dependents on all three immediately before
-- this migration, same standard as the original 0058 cleanup.
-- ============================================================================

drop function if exists public.dds_alert_summary(date, date, text, text[], text[], text, integer, integer);
drop function if exists public.dds_entity_day_breakdown(text, text, integer, date, date);
drop function if exists public.dds_metrics_multi(jsonb);
