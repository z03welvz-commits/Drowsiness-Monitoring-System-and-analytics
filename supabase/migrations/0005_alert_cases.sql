-- ============================================================================
-- DDS — 0005_alert_cases
-- ----------------------------------------------------------------------------
-- BACKFILLED FROM THE LIVE DATABASE (project rispydfovrnvnwvfwrnw), not
-- written fresh. These objects were deployed without ever being committed, so
-- the migration sequence could not be replayed on an empty project: 0009 and
-- 0012 both join public.alert_cases, and 0016 replaces dds_alert_logs(), so a
-- from-scratch run failed on an unknown table and an unknown function.
--
-- Everything below was read back from the live catalog immediately before
-- writing (pg_get_functiondef / information_schema.columns / pg_indexes /
-- pg_policies / pg_constraint) rather than trusted from memory. That mattered:
-- dds_alert_logs() has since grown p_sort/p_dir, so the version that belongs
-- here is NOT the one this file originally carried — see the note below.
--
-- Contains:
--   * public.alert_cases   — the review/action record attached to one event
--   * public.driver_master — the uploaded driver roster the name picker
--                            autocompletes against
--   * public.dds_replace_drivers() — replaces that roster wholesale
--
-- DELIBERATELY NOT HERE: dds_alert_logs(). Its current 9-argument definition
-- (with sorting) is created by 0016_sorting_and_group_details.sql, which also
-- drops the old 7-argument overload. Defining a 7-arg version here and letting
-- 0016 add a 9-arg one would leave BOTH on a fresh replay — and PostgREST
-- cannot choose between two candidates when the client omits the new params,
-- so every Alert Logs request would fail. One definition, in one file.
--
-- CURRENT STATE, OVERWRITE ON EDIT — the opposite of driver_asset_actions
-- (0007), which is append-only history. An alert has at most one case row
-- (enforced by uq_alert_cases_event below); editing a case overwrites it. Use
-- alert_cases for "what is the current disposition of this alert",
-- driver_asset_actions for "what has been done about this driver/unit over
-- time".
--
-- WRITTEN DIRECTLY BY THE CLIENT, not through an RPC. Unlike every other write
-- path in this app, index.html upserts alert_cases through PostgREST
-- (.from('alert_cases')) rather than a security-definer function, so the RLS
-- policies at the bottom of this file are the ONLY thing standing between a
-- signed-in user and this table. They are load-bearing, not decorative.
-- ============================================================================

-- pg_trgm backs the fuzzy driver-name index below. It is live on the project
-- but was never declared in any migration, so a from-scratch replay failed on
-- idx_driver_master_name_trgm without this. Note it is installed into `public`
-- on this project (unlike pgcrypto, which lives in `extensions`), which is why
-- gin_trgm_ops resolves unqualified.
create extension if not exists "pg_trgm";

-- ── Alert cases ────────────────────────────────────────────────────────────
-- One row per reviewed event. The ABSENCE of a row means "never reviewed",
-- which dds_alert_summary() treats as Pending — see the load-bearing
-- coalesce(bool_and(...), false) in 0012 and its comment for why that
-- distinction breaks silently if handled naively.

create table if not exists public.alert_cases (
  id              uuid primary key default gen_random_uuid(),
  event_id        bigint not null references public.events(id) on delete cascade,

  -- Free text, NOT a foreign key to driver_master. The roster is an
  -- autocomplete convenience; a driver can be named on a case before (or
  -- without) ever appearing in an uploaded roster, and dds_replace_drivers()
  -- deletes the whole roster on every upload, which would cascade or block if
  -- this were a real FK.
  driver_name     text,

  action_type     text,
  action_is_other boolean not null default false,

  -- 'Completed' is the exact value dds_alert_summary() tests for when deriving
  -- Closed vs Pending. Changing this string changes that function's meaning.
  status_value    text,
  status_is_other boolean not null default false,

  remarks         text,

  updated_by      uuid references auth.users(id) on delete set null,
  updated_at      timestamptz not null default now(),
  created_at      timestamptz not null default now()
);

-- At most one case per event: this is what makes "current state, overwrite on
-- edit" enforceable rather than merely conventional, and it is the conflict
-- target the client's upsert relies on.
create unique index if not exists uq_alert_cases_event
  on public.alert_cases (event_id);

create index if not exists idx_alert_cases_status
  on public.alert_cases (status_value);

-- lower(driver_name) so dds_alert_logs()'s case-insensitive driver search can
-- use an index instead of scanning.
create index if not exists idx_alert_cases_driver
  on public.alert_cases (lower(driver_name));

-- ── Driver master ──────────────────────────────────────────────────────────
-- The uploaded driver roster. Replaced wholesale on each upload rather than
-- merged — see dds_replace_drivers() below.

create table if not exists public.driver_master (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  employee_id text,
  uploaded_by uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);

-- Case-insensitive uniqueness: "J. Cruz" and "j. cruz" are one driver. This is
-- also what dds_replace_drivers()'s distinct on (lower(name)) protects against
-- violating when a roster file lists the same name twice in different casing.
create unique index if not exists uq_driver_master_name
  on public.driver_master (lower(name));

-- Trigram index for the fuzzy name search the driver picker performs.
create index if not exists idx_driver_master_name_trgm
  on public.driver_master using gin (lower(name) gin_trgm_ops);

-- ── Row Level Security ─────────────────────────────────────────────────────
-- Single tenant, same rule as events/imports in 0001_init.sql: any signed-in
-- user reads and writes. As the header says, these policies are the only
-- access control on these two tables, because the client writes both directly
-- rather than through a security-definer RPC.
--
-- No UPDATE policy on driver_master: the roster is replace-only via
-- dds_replace_drivers() (delete + insert), so granting UPDATE would permit a
-- write path nothing in the app actually uses.

alter table public.alert_cases   enable row level security;
alter table public.driver_master enable row level security;

create policy alert_cases_read on public.alert_cases
  for select using (auth.uid() is not null);
-- updated_by = auth.uid() on INSERT: a user cannot attribute a case they
-- created to somebody else. UPDATE deliberately does not re-check this, so one
-- reviewer can amend another's case (single-tenant shared-queue model) —
-- matching the live policy set exactly.
create policy alert_cases_insert on public.alert_cases
  for insert with check (auth.uid() is not null and updated_by = auth.uid());
create policy alert_cases_update on public.alert_cases
  for update using (auth.uid() is not null);
create policy alert_cases_delete on public.alert_cases
  for delete using (auth.uid() is not null);

create policy driver_master_read on public.driver_master
  for select using (auth.uid() is not null);
create policy driver_master_insert on public.driver_master
  for insert with check (auth.uid() is not null);
create policy driver_master_delete on public.driver_master
  for delete using (auth.uid() is not null);

-- ── Driver roster replace ──────────────────────────────────────────────────
-- REPLACE, not merge: the uploaded file is the authoritative roster, so a
-- driver removed from it should disappear rather than linger. SECURITY DEFINER
-- because it deletes every row in the table — the delete is scoped by the
-- function's own logic, not by the caller's policies.
--
-- distinct on (lower(name)) dedupes within the uploaded file itself, since
-- uq_driver_master_name would otherwise abort the whole insert when a roster
-- lists the same person twice in different casing.
--
-- Transcribed verbatim from the live definition.

create or replace function public.dds_replace_drivers(p_names jsonb)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_inserted integer;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED' using errcode = '42501'; end if;

  delete from public.driver_master;

  insert into public.driver_master (name, employee_id, uploaded_by)
  select distinct on (lower(r->>'name')) r->>'name', nullif(r->>'employee_id', ''), auth.uid()
  from jsonb_array_elements(p_names) r
  where nullif(trim(r->>'name'), '') is not null;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

revoke all on function public.dds_replace_drivers(jsonb) from public;
revoke all on function public.dds_replace_drivers(jsonb) from anon;
grant execute on function public.dds_replace_drivers(jsonb) to authenticated;
