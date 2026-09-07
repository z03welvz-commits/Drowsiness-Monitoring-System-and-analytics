-- ============================================================================
-- DDS — 0089_latest_event_date
-- ----------------------------------------------------------------------------
-- Backs Overview's new date-range filter: the default range should be "7
-- days prior to the latest real data", not 7 days prior to today's real
-- calendar date — those differ whenever uploads lag behind the calendar
-- (a weekend with no import, a late file). A single indexed max() is a
-- cheap, direct answer, cheaper and more robust than inferring it from
-- whatever the trend array of some other call happened to fetch.
-- ============================================================================

create or replace function public.dds_latest_event_date()
returns date
language plpgsql
stable
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;
  return (select max(shift_date) from public.events);
end;
$$;

revoke all on function public.dds_latest_event_date() from public, anon;
grant execute on function public.dds_latest_event_date() to authenticated;
