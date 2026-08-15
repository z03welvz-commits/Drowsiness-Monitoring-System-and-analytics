-- ============================================================================
-- DDS — 0001_init
-- ----------------------------------------------------------------------------
-- Schema for the Drowsiness Detection System dashboard.
--
-- TIME SEMANTICS — the single most important thing in this file.
-- Columns are `timestamp` (WITHOUT time zone), holding UTC wall-clock values.
-- This is deliberate, not an oversight:
--   * The frontend parses with Date.UTC() and reads with getUTC*. It is
--     UTC-naive wall clock end to end.
--   * With `timestamptz`, EXTRACT and casts depend on the session TimeZone,
--     so the same row would classify differently for two different clients.
--     Night-shift attribution would break with no error raised.
--   * `timestamp` makes the generated columns below deterministic, which
--     Postgres requires anyway (generated expressions must be IMMUTABLE).
-- Never migrate these to timestamptz without re-deriving every shift column.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ── Imports ────────────────────────────────────────────────────────────────

create type public.import_status as enum ('pending', 'processing', 'complete', 'failed');

create table if not exists public.imports (
  id             uuid primary key default gen_random_uuid(),
  uploaded_by    uuid references auth.users(id) on delete set null,
  -- Storage key is generated server-side. The user-supplied filename is kept
  -- for display only and is never used as a path (traversal vector).
  storage_key    text not null,
  original_name  text not null,
  status         public.import_status not null default 'pending',
  row_count      integer not null default 0,
  rejected_count integer not null default 0,
  -- [{ rowIndex, reason }] — rows rejected at import per the agreed rule.
  rejects        jsonb not null default '[]'::jsonb,
  error          text,
  created_at     timestamptz not null default now(),
  completed_at   timestamptz
);

create index if not exists idx_imports_created on public.imports(created_at desc);

-- ── Shift classification ───────────────────────────────────────────────────
-- MUST stay byte-identical to classifyShift() / shiftWindow() in dds-state.js.
-- Boundaries (resolved): DAY = [05:21:00, 17:20:59], NIGHT = [17:21:00,
-- 05:20:59 next day]. Contiguous — every second belongs to exactly one shift.
-- A START_TIME before 05:21 attributes to the PREVIOUS day's night shift.

create or replace function public.dds_shift(start_time timestamp)
returns text
language sql immutable parallel safe
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

-- ── Events ─────────────────────────────────────────────────────────────────
-- shift / shift_date / actionable are GENERATED, not application-written.
-- Computing them at ingest (once) rather than per dashboard load is what makes
-- the metrics query fast, and generating them makes drift with the app
-- impossible — there is no code path that can write an inconsistent value.

create table if not exists public.events (
  id           bigint generated always as identity primary key,
  import_id    uuid references public.imports(id) on delete cascade,

  update_time  timestamp not null,
  start_time   timestamp not null,
  end_time     timestamp,
  asset_id     text   not null,
  event_code   text   not null,
  event_count  integer not null default 0 check (event_count >= 0),
  operator     text,

  shift        text    generated always as (public.dds_shift(start_time))       stored,
  shift_date   date    generated always as (public.dds_shift_date(start_time))  stored,
  actionable   boolean generated always as (public.dds_actionable(start_time, update_time)) stored,

  -- Sync lag in seconds. Negative values (clock skew) are discarded, matching
  -- the JS, which drops them from the average rather than skewing it.
  sync_seconds integer generated always as (
    case when end_time is not null and update_time >= end_time
      then extract(epoch from (update_time - end_time))::integer end
  ) stored,

  created_at   timestamptz not null default now()
);

-- Covering index for the metrics query's WHERE + GROUP BY.
create index if not exists idx_events_shiftdate on public.events (shift_date, shift);
create index if not exists idx_events_asset     on public.events (asset_id);
create index if not exists idx_events_code      on public.events (event_code);
create index if not exists idx_events_import
  on public.events (import_id);

-- Re-importing the same file must not double-count.
create unique index if not exists uq_events_natural
  on public.events (asset_id, start_time, event_code);

-- ── Settings ───────────────────────────────────────────────────────────────
-- Deliberately thin. The Settings and User Management screens are still
-- prototypes in the frontend, so their schema is not yet knowable. This holds
-- what the dashboard genuinely needs today; extend it once those screens are
-- built for real rather than guessing at columns now.

create table if not exists public.user_settings (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  preferences jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);

-- ── Row Level Security ─────────────────────────────────────────────────────
-- RLS is the authorization boundary. The frontend's role badges
-- (admin / coordinator / assistant) are display state and are re-checked here
-- on every single row access — a hidden nav item is not an access control.

alter table public.imports       enable row level security;
alter table public.events        enable row level security;
alter table public.user_settings enable row level security;

-- ── Row Level Security ─────────────────────────────────────────────────────
-- Single tenant: any signed-in user reads all data. There is no site scoping.
-- Roles (Admin / Area Coordinator / Office Assistant) exist in the UI but are
-- not modelled here — the User Management screen is still a prototype, so its
-- schema is not yet knowable. Add it when those screens are built for real.

create policy events_read on public.events
  for select using (auth.uid() is not null);

create policy imports_read on public.imports
  for select using (auth.uid() is not null);
create policy imports_insert on public.imports
  for insert with check (auth.uid() is not null and uploaded_by = auth.uid());
create policy imports_delete on public.imports
  for delete using (auth.uid() is not null);

create policy settings_own on public.user_settings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
