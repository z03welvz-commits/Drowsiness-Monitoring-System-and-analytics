-- ============================================================================
-- DDS — 0071_drivers_resolver_generated_columns
-- ----------------------------------------------------------------------------
-- Phase 1 of the name-linking pipeline fix. dds_resolve_name()'s tiers 2-5
-- (suffix-stripped, surname-first-key, name-skeleton, fuzzy Levenshtein
-- shortlist) each ran a full sequential scan of public.drivers with a
-- function call evaluated per row, per tier, per unresolved name — zero
-- supporting index existed for any of them. Measured live: even a single
-- p_limit=100 batch of dds_reresolve_all/dds_minestat_reresolve_all can
-- time out against the 8s authenticated statement_timeout purely from this
-- cost, independent of the earlier p_limit batching fix (0070).
--
-- Fix: precompute each tier's key as a generated, stored column, matching
-- the existing precedent in 0043 (operator_key) — a real column the query
-- planner can index trivially, rather than an expression index that only
-- matches if a future migration's query text happens to reproduce the
-- exact nested function-call shape byte-for-byte (this schema's own
-- history — 0029, 0054 — shows these normalization functions get revised
-- repeatedly). All five source functions confirmed IMMUTABLE (required
-- for a generated column) via pg_proc.provolatile before writing this.
-- ============================================================================

alter table public.drivers
  add column if not exists norm_name            text generated always as (public.dds_norm_name(full_name)) stored,
  add column if not exists bare_name             text generated always as (public.dds_strip_suffix(public.dds_norm_name(full_name))) stored,
  add column if not exists surname_first_key     text generated always as (public.dds_surname_first_key(public.dds_norm_name(full_name))) stored,
  add column if not exists name_skeleton         text generated always as (public.dds_name_skeleton(public.dds_strip_suffix(public.dds_norm_name(full_name)))) stored,
  add column if not exists surname_first_letter  text generated always as (left(public.dds_surname_of(public.dds_norm_name(full_name)), 1)) stored,
  add column if not exists bare_name_len         integer generated always as (length(public.dds_strip_suffix(public.dds_norm_name(full_name)))) stored;

create index if not exists idx_drivers_norm_name on public.drivers (norm_name);
create index if not exists idx_drivers_bare_name on public.drivers (bare_name);
create index if not exists idx_drivers_surname_first_key on public.drivers (surname_first_key);
create index if not exists idx_drivers_name_skeleton on public.drivers (name_skeleton);
create index if not exists idx_drivers_surname_letter_len on public.drivers (surname_first_letter, bare_name_len) where status = 'active';
