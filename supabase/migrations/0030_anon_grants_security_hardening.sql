-- ============================================================================
-- DDS — 0030_anon_grants_security_hardening
-- ----------------------------------------------------------------------------
-- Closes a live security gap confirmed via the Supabase security advisor and a
-- direct information_schema.role_routine_grants query against the running
-- database (not a re-derivation from migration files, which — per 0026's own
-- header — have already been shown to diverge from live grant state at least
-- once before): 8 functions currently hold `anon` EXECUTE where every other
-- RPC in this schema correctly revokes it.
--
-- ROOT CAUSE, so the next migration doesn't repeat it: 0009, 0017, and 0020
-- each wrote `revoke all on function ... from public;` WITHOUT the `, anon`
-- that 0018/0019's own precedent already established. `anon` does not
-- automatically lose EXECUTE just because PUBLIC did on a project where it
-- was ever separately granted, so this was a live, exploitable-if-noticed gap
-- (though `auth.uid() is null` inside every one of these functions already
-- rejects an unauthenticated caller at runtime — this migration removes
-- unnecessary attack surface, not a live data-access hole).
--
-- dds_driver_alias_audit() is a trigger function (fires only via
-- trg_driver_alias_audit on driver_aliases writes) and gets no re-grant to
-- `authenticated` either — nobody should ever call it directly via RPC.
-- Triggers execute with the definer's own privileges regardless of what
-- grants exist on the function itself, so revoking direct-execute here does
-- not break the trigger.
--
-- OUT OF SCOPE, on purpose: username_to_email(text) and rls_auto_enable()
-- were also found live-anon-executable but are not touched here.
-- username_to_email is genuinely called pre-authentication from both
-- index.html and login.html (the username -> email login resolver) —
-- revoking it would break sign-in. rls_auto_enable() has no confirmed
-- caller found in this pass; left as a flagged follow-up rather than a
-- same-day guess.
-- ============================================================================

revoke all on function public.dds_metrics(date, date, text, text[], text[], boolean) from public, anon;
revoke all on function public.dds_metrics_multi(jsonb) from public, anon;
revoke all on function public.dds_alert_summary(date, date, text, text[], text[], text, integer, integer) from public, anon;
revoke all on function public.dds_driver_asset_severity() from public, anon;
revoke all on function public.dds_entity_actions(text, text) from public, anon;
revoke all on function public.dds_latest_entity_actions(text) from public, anon;
revoke all on function public.dds_log_driver_asset_action(text, text, text, boolean, text, text) from public, anon;
revoke all on function public.dds_driver_alias_audit() from public, anon;

grant execute on function public.dds_metrics(date, date, text, text[], text[], boolean) to authenticated;
grant execute on function public.dds_metrics_multi(jsonb) to authenticated;
grant execute on function public.dds_alert_summary(date, date, text, text[], text[], text, integer, integer) to authenticated;
grant execute on function public.dds_driver_asset_severity() to authenticated;
grant execute on function public.dds_entity_actions(text, text) to authenticated;
grant execute on function public.dds_latest_entity_actions(text) to authenticated;
grant execute on function public.dds_log_driver_asset_action(text, text, text, boolean, text, text) to authenticated;
-- dds_driver_alias_audit(): deliberately NO grant to authenticated either.
