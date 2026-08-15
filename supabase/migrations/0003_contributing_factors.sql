-- ============================================================================
-- DDS — 0003_contributing_factors
-- ----------------------------------------------------------------------------
-- A standalone log of conditions/context that can help explain alert activity
-- over a time window — e.g. "Heavy rain, Aug 10 22:00–06:00" or "Power
-- interruption at the depot" — deliberately NOT tied to a specific
-- alert/event row or asset.
-- Does not feed annotate()/derive()/dds_metrics(); the Analytics KPIs and
-- charts are untouched by this table. It exists to be read alongside the
-- dashboard, not aggregated into it.
--
-- TIME SEMANTICS — same rule as 0001_init.sql: `timestamp` WITHOUT time zone,
-- UTC-naive wall clock, matching the client's Date.UTC()/getUTC* handling.
-- Never migrate to timestamptz without re-deriving anything that reads these
-- columns.
-- ============================================================================

create table if not exists public.contributing_factors (
  id           uuid primary key default gen_random_uuid(),
  logged_by    uuid references auth.users(id) on delete set null,
  logged_at    timestamptz not null default now(),   -- when the record was entered, not the event window

  factor_type  text not null,        -- 'Power Interruption' | 'Weather Condition' | 'Others'
  detail       text,                 -- free-text specifics, e.g. "Heavy rain, visibility <50m"
  start_time   timestamp not null,
  end_time     timestamp,            -- nullable: an ongoing or point-in-time factor may have no known end yet

  notes        text,

  created_at   timestamptz not null default now(),
  check (end_time is null or end_time >= start_time)
);

create index if not exists idx_factors_start on public.contributing_factors (start_time);
create index if not exists idx_factors_type  on public.contributing_factors (factor_type);

alter table public.contributing_factors enable row level security;

-- Single tenant, same as events/imports in 0001_init.sql: any signed-in user
-- reads and writes all rows. No site scoping, no per-user ownership on
-- read/update/delete — a factor logged by one coordinator must be visible
-- and editable by any other signed-in user, since it describes shared fleet
-- context, not personal data.
create policy factors_read on public.contributing_factors
  for select using (auth.uid() is not null);
create policy factors_insert on public.contributing_factors
  for insert with check (auth.uid() is not null and logged_by = auth.uid());
create policy factors_update on public.contributing_factors
  for update using (auth.uid() is not null);
create policy factors_delete on public.contributing_factors
  for delete using (auth.uid() is not null);
