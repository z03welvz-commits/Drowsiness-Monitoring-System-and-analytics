-- ============================================================================
-- DDS — 0089_latest_event_date
-- ----------------------------------------------------------------------------
-- RECONSTRUCTED from live database state on 2026-09-07 — original migration
-- SQL text was not recoverable from Supabase's migration history
-- (supabase_migrations.schema_migrations only stores version+name, not the
-- applied SQL body). This file reflects the live definition as of
-- reconstruction time, not necessarily the original diff.
--
-- Inferred intent: new small helper RPC returning the most recent
-- events.shift_date in the whole dataset, likely so the frontend can anchor
-- default date-range pickers / "as of" labels to actual data recency instead
-- of client-side current_date (which can be ahead of the latest imported
-- shift).
-- ============================================================================

create or replace function public.dds_latest_event_date()
returns date
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  return (select max(shift_date) from public.events);
end;
$function$;
