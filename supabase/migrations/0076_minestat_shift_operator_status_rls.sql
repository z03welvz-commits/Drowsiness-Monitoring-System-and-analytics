-- ============================================================================
-- DDS — 0076_minestat_shift_operator_status_rls
-- ----------------------------------------------------------------------------
-- minestat_shift_operator_status (0073) was created with RLS enabled
-- (project default) but no policy — the security advisor flagged this as
-- "RLS Enabled No Policy". Read-only policy matching this schema's
-- standard convention for internal cache/derived tables (any signed-in
-- user may read; all writes happen only via the SECURITY DEFINER trigger
-- function, which bypasses RLS).
-- ============================================================================

create policy minestat_shift_operator_status_read
  on public.minestat_shift_operator_status
  for select
  to authenticated
  using (auth.uid() is not null);
