-- ============================================================================
-- DDS — 0031_search_path_pin_remaining
-- ----------------------------------------------------------------------------
-- Finishes the search_path pinning 0029 started. Confirmed live via
-- pg_proc.proconfig ahead of this migration that none of the nine
-- normalization/classification functions had search_path pinned, despite
-- being written as `language sql` — an unpinned search_path on a SECURITY
-- DEFINER function is the classic hijacking vector, and while none of these
-- nine are SECURITY DEFINER, the Supabase security advisor flags it
-- regardless (function_search_path_mutable) since a mutable search_path is
-- still a latent risk if a function's language or security context ever
-- changes later without someone remembering to add the pin then.
--
-- 0029 already pinned dds_norm_name, dds_surname_of, dds_strip_suffix while
-- rewriting them for the diacritics/surname-prefix fix. These six are the
-- ones nothing else touched this round — reissued here with the pin added
-- and the body otherwise byte-identical to their current live definitions
-- (0001_init.sql for the first three, 0018_driver_masterlist.sql for the
-- rest).
-- ============================================================================

create or replace function public.dds_shift(start_time timestamp)
returns text
language sql immutable parallel safe
set search_path = public
as $$
  select case
    when start_time::time >= time '05:21:00'
     and start_time::time <= time '17:20:59'
    then 'DAY' else 'NIGHT'
  end;
$$;

create or replace function public.dds_shift_date(start_time timestamp)
returns date
language sql immutable parallel safe
set search_path = public
as $$
  select case
    -- Early-morning tail: belongs to the previous day's night shift.
    when start_time::time < time '05:21:00' then (start_time::date - 1)
    else start_time::date
  end;
$$;

create or replace function public.dds_actionable(
  start_time timestamp, update_time timestamp
) returns boolean
language sql immutable parallel safe
set search_path = public
as $$
  select case public.dds_shift(start_time)
    when 'DAY' then
      update_time >= public.dds_shift_date(start_time) + time '05:21:00'
      and update_time <= public.dds_shift_date(start_time) + time '17:20:59'
    else
      update_time >= public.dds_shift_date(start_time) + time '17:21:00'
      and update_time <= public.dds_shift_date(start_time) + interval '1 day'
                                                          + time '05:20:59'
  end;
$$;

create or replace function public.dds_name_skeleton(s text)
returns text
language sql immutable parallel safe
set search_path = public
as $$
  select nullif(translate(coalesce(s, ''), 'AEIOUH ', ''), '');
$$;

create or replace function public.dds_first_of(s text)
returns text
language sql immutable parallel safe
set search_path = public
as $$
  select case when position(',' in coalesce(s, '')) > 0
    then split_part(trim(split_part(s, ',', 2)), ' ', 1)
  end;
$$;

create or replace function public.dds_surname_first_key(s text)
returns text
language sql immutable parallel safe
set search_path = public
as $$
  select nullif(concat_ws(' ',
    public.dds_surname_of(s),
    public.dds_first_of(s)
  ), '');
$$;

-- username_lookup_attempts' RLS-enabled-no-policy advisory (INFO level) is
-- deliberately left alone by this migration: deny-all is the intended, safe
-- state for a rate-limit table — writes happen only through
-- username_to_email()'s own SECURITY DEFINER logic, and nothing needs to
-- read it directly via PostgREST. No schema change follows from that
-- observation; noted here so it reads as a decision, not an oversight.
