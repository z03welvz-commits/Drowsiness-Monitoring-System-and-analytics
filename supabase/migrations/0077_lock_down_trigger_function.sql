-- ============================================================================
-- DDS — 0077_lock_down_trigger_function
-- ----------------------------------------------------------------------------
-- trg_refresh_minestat_shift_operator_status() (0073) is a trigger-only
-- function (relies on tg_op and the NEW/OLD transition tables a trigger
-- context provides) — the security advisor flagged it as directly
-- callable via PostgREST by both anon and authenticated
-- (/rest/v1/rpc/trg_refresh_minestat_shift_operator_status), which was not
-- intentional. Supabase/PostgREST auto-exposes every public-schema
-- function as an RPC endpoint by default unless EXECUTE is explicitly
-- revoked.
--
-- Revoking direct EXECUTE does not break the trigger itself — Postgres
-- invokes a trigger function directly at the table-owner level when a
-- trigger fires, independent of a role's own EXECUTE privilege (verified
-- live: inserting and deleting rows on minestat_shifts still correctly
-- updated minestat_shift_operator_status after this revoke).
-- ============================================================================

revoke all on function public.trg_refresh_minestat_shift_operator_status() from public, anon, authenticated;
