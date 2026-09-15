-- ============================================================================
-- DDS — 0131_drop_stale_driver_streaks_overloads
-- ----------------------------------------------------------------------------
-- Audit finding: three overloads of dds_driver_streaks() coexisted live —
-- the current 12-arg version (...p_status, p_from, p_to), and two STALE ones
-- left behind by earlier migrations that changed the signature via
-- `create or replace` (which only replaces a function with the IDENTICAL
-- argument list) instead of dropping the old one first:
--   (p_search, p_min_streak, p_sort, p_dir, p_limit, p_offset, p_window_days)
--     — predates p_shift/p_asset/p_status (pre-0122-era).
--   (...through p_status, no p_from/p_to)
--     — predates 0120's date-range filter.
--
-- This is not harmless dead code. Every real call site in index.html passes
-- a SUBSET of named arguments (the rest take defaults), and all three
-- overloads share the first 6-10 parameter NAMES identically — so a call
-- naming only those shared params is genuinely ambiguous. Confirmed live:
--   select dds_driver_streaks(p_search=>null, p_min_streak=>1,
--     p_sort=>'streak_days', p_dir=>'desc', p_limit=>1, p_offset=>0)
-- fails outright with "function ... is not unique" — this is EXACTLY the
-- call the sidebar's cross-page "needs attention" nav badge
-- (refreshDriverStreaksNavBadge(), index.html ~L4440) makes on every page
-- load, app-wide. Its .catch() only console.errors and leaves the badge in
-- its default `hidden` state — so this badge has been silently non-
-- functional (always hidden, regardless of how many drivers need
-- attention) for as long as these stale overloads have coexisted, entirely
-- independent of any of this session's logic changes. The main table load,
-- export, and per-row detail calls all pass p_status/p_from/p_to too, so
-- they happened to keep working, but were exposed to the same ambiguity
-- risk from any future call site that didn't name every parameter.
--
-- Fix: drop both stale signatures, leaving the one real implementation.
-- ============================================================================
drop function if exists public.dds_driver_streaks(
  text, integer, text, text, integer, integer, integer
);
drop function if exists public.dds_driver_streaks(
  text, integer, text, text, integer, integer, integer, text, text, text
);
