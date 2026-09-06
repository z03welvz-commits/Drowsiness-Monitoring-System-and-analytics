-- ============================================================================
-- DDS — 0033_entity_monitoring
-- ----------------------------------------------------------------------------
-- Persists the Driver & Asset Monitoring page's risk/action model for real.
-- Phase 0 of the Application A/B migration (see MIGRATION_MAP.md, Decision 1)
-- settled a real fork: Application A already has a working driver/asset
-- severity feature (driver_asset_severity, 0020, applySeverity()'s 4-band
-- critical/warning/caution/normal system), but the destination UI
-- (dds_overview_1_.html, "Application B") ships a DIFFERENT, self-contained
-- risk model — a 3-tier High/Medium/Low formula and an 8-value action
-- vocabulary (Counseled/Suspended/Reassigned/Cleared/Spare 3 Days/Monitor/
-- Continue/Other) — currently only backed by that mock's own localStorage.
--
-- DECISION 1 (already made, not reopened here): the mock's model ships. It
-- does not replace driver_asset_severity/driver_asset_actions — those stay
-- exactly as they are, unused by this feature, in case anything else still
-- depends on them (nothing currently does, per Phase 0's read, but deleting
-- a working table on a guess is exactly what the master prompt's
-- reconciliation rules warn against). This migration adds a SEPARATE,
-- parallel set of objects for the mock's specific model, so there are two
-- independently-correct features living side by side, not one feature
-- computed two competing ways.
--
-- WHAT THE MOCK ACTUALLY NEEDS (read directly from dds_overview_1_.html's
-- own <script> block, not guessed):
--   - state[kind][i].days: { Mon: [13], Tue: [15,4], ... } — one array of
--     individual per-alert event_count values per day. This is NOT a table
--     to write to; it's exactly what public.events already contains,
--     grouped by (entity, shift_date). A new query, not new storage.
--   - state[kind][i].status: 'required' | 'actioned' — whether this week's
--     flag has been closed out by a logged action. Needs a small, current-
--     state table (entity_status below).
--   - state[kind][i].history[]: append-only log of past actions
--     ({type, note, by, at}). Needs a history table (entity_action_log
--     below) — same append-only shape driver_asset_actions (0007) already
--     established for a different feature; not reused because its
--     action_type vocabulary is a different, incompatible list (0007's
--     comment: 'Replace driver'/'Disciplinary action'/'Noted'/'Other' vs.
--     this feature's 8-value Counseled/Suspended/.../Continue/Other list).
--   - computeRisk()'s formula (daysOver10>=2 OR total>20 -> high; any
--     alerts -> medium; zero -> low) and recommendation() are pure functions
--     over the days shape above — computed in the RPC below, not stored,
--     exactly the same "compute on read, don't duplicate storage" choice
--     0020's own header already made for the OTHER severity feature.
--
-- REOPENING ON A NEW ALERT (master-prompt-mandated: "a previous action
-- remains historical; a new qualifying alert flips status back to Action
-- Required"): implemented as an AFTER INSERT trigger on public.events,
-- mirroring trg_driver_alias_audit's existing trigger pattern (0018) rather
-- than adding bespoke logic to dds_ingest() itself — dds_ingest() has been
-- redefined 4 times already (0001/0015/0019/0032) and every version keeps an
-- identical dedup contract; a trigger keeps that function's own logic
-- untouched and this feature's behavior colocated with the table it reacts
-- to.
--
-- KEYING: drivers by emp_no (falling back to a literal 'UNSPECIFIED'
-- sentinel when emp_no is null, exactly the precedent 0028_dds_metrics_emp_no
-- established — never raw operator text, which is exactly what emp_no
-- grouping exists to stop fragmenting). Assets by asset_id (no resolution
-- layer exists or is needed for assets, same as every other asset-keyed
-- query in this schema).
--
-- NOT APPLIED to the live database from this session — no Supabase MCP or
-- psql/python3 access was available (this Windows machine's python3 is the
-- Microsoft Store stub, confirmed non-functional per README). This file is
-- ready to apply via the Supabase SQL editor or CLI; see
-- docs/DATA_MIGRATION_STATUS.md for how to verify it after applying.
-- ============================================================================

-- ── entity_action_log — APPEND-ONLY history, one row per logged action ─────
-- Mirrors driver_asset_actions' (0007) shape and RLS pattern exactly, with a
-- different (this feature's own) action_type vocabulary. No update/delete
-- policy at all, by design — "never overwrite historical actions" is a
-- direct master-prompt requirement, not a style choice.
create table public.entity_action_log (
  id                uuid primary key default gen_random_uuid(),

  entity_type       text not null check (entity_type in ('driver', 'asset')),
  entity_id         text not null,        -- emp_no (or 'UNSPECIFIED') for drivers, asset_id for assets

  action_type       text not null check (action_type in (
                       'Counseled', 'Suspended', 'Reassigned', 'Cleared',
                       'Spare 3 Days', 'Monitor', 'Continue', 'Other'
                     )),
  action_other_text text,                 -- populated only when action_type = 'Other', matches the mock's da-other-input field
  note              text,                 -- matches the mock's "Note / remarks" field

  logged_by         text not null,        -- free text, matches the mock's "Logged by" field (name/employee ID, not necessarily the account holder)
  actor_user_id     uuid references auth.users(id) on delete set null,

  created_at        timestamptz not null default now()
);

create index idx_eal_entity on public.entity_action_log (entity_type, entity_id, created_at desc);

alter table public.entity_action_log enable row level security;

create policy eal_read on public.entity_action_log
  for select using (auth.uid() is not null);
create policy eal_insert on public.entity_action_log
  for insert with check (auth.uid() is not null and actor_user_id = auth.uid());

-- ── entity_status — CURRENT state, one row per entity ───────────────────────
-- Mirrors driver_asset_severity's (0020) single-row-per-entity shape. Only
-- tracks what the mock's UI actually branches on: required vs. actioned.
create table public.entity_status (
  entity_type text not null check (entity_type in ('driver', 'asset')),
  entity_id   text not null,

  status      text not null default 'required' check (status in ('required', 'actioned')),

  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id) on delete set null,

  primary key (entity_type, entity_id)
);

alter table public.entity_status enable row level security;

create policy es_read on public.entity_status
  for select using (auth.uid() is not null);
create policy es_upsert on public.entity_status
  for insert with check (auth.uid() is not null and updated_by = auth.uid());
create policy es_update on public.entity_status
  for update using (auth.uid() is not null) with check (updated_by = auth.uid());

-- ── Write: log a new action, flips the entity to 'actioned' ────────────────
-- security definer: needs to write both tables in one transaction (a client
-- upsert to entity_status alone could race against this insert and leave
-- the two out of sync — logging an action and closing the flag are one
-- unit of work here, unlike driver_asset_severity's independent-upsert
-- design, because THIS feature's status is entirely derived from whether an
-- action was logged, not from a separately-computed value).
create or replace function public.dds_log_entity_action(
  p_entity_type       text,
  p_entity_id         text,
  p_action_type       text,
  p_action_other_text text,
  p_note              text,
  p_logged_by         text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  if p_entity_type not in ('driver', 'asset') then
    raise exception 'INVALID_ENTITY_TYPE' using errcode = '22023';
  end if;

  if coalesce(trim(p_logged_by), '') = '' then
    raise exception 'LOGGED_BY_REQUIRED' using errcode = '22023';
  end if;

  insert into public.entity_action_log (
    entity_type, entity_id, action_type, action_other_text, note,
    logged_by, actor_user_id
  ) values (
    p_entity_type, p_entity_id, p_action_type, p_action_other_text, p_note,
    trim(p_logged_by), auth.uid()
  )
  returning id into v_id;

  insert into public.entity_status (entity_type, entity_id, status, updated_by)
  values (p_entity_type, p_entity_id, 'actioned', auth.uid())
  on conflict (entity_type, entity_id)
  do update set status = 'actioned', updated_at = now(), updated_by = excluded.updated_by;

  return v_id;
end;
$$;

revoke all on function public.dds_log_entity_action(text, text, text, text, text, text) from public, anon;
grant execute on function public.dds_log_entity_action(text, text, text, text, text, text) to authenticated;

-- ── Reopen on a new qualifying alert ────────────────────────────────────────
-- "A previous action remains historical; a new alert flips status back to
-- Action Required" (master prompt, explicit requirement). Fires after every
-- events insert — dds_ingest()'s own on-conflict-do-nothing dedup means this
-- only ever fires for genuinely new rows, never a re-sent duplicate chunk,
-- so a retried import cannot spuriously reopen an already-actioned entity.
-- Only touches a row that already exists AND is currently 'actioned' — an
-- entity with no row yet (never flagged before) is left alone; its first
-- flag is computed on read by dds_driver_asset_weekly() below, not created
-- here, since 'required' is that table's own default the first time
-- anything writes a row for it (i.e. the first logged action, or never, if
-- it's simply never actioned).
create or replace function public.dds_entity_status_reopen()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_asset_id text;
  v_driver_key text;
begin
  v_asset_id := new.asset_id;
  update public.entity_status
    set status = 'required', updated_at = now(), updated_by = null
    where entity_type = 'asset' and entity_id = v_asset_id and status = 'actioned';

  v_driver_key := coalesce(new.emp_no, 'UNSPECIFIED');
  update public.entity_status
    set status = 'required', updated_at = now(), updated_by = null
    where entity_type = 'driver' and entity_id = v_driver_key and status = 'actioned';

  return new;
end;
$$;

drop trigger if exists trg_entity_status_reopen on public.events;
create trigger trg_entity_status_reopen
  after insert on public.events
  for each row execute function public.dds_entity_status_reopen();

-- ── Read: weekly per-entity alert shape + status + last action ─────────────
-- Returns exactly the shape dds_overview_1_.html's computeRisk()/render
-- code already expects: one entry per entity with a days object
-- ({"Mon":[13],"Tue":[15,4]}), current status, and the most recent logged
-- action (for the table's "last action" column / detail drawer). Risk
-- itself (high/medium/low) and recommendation() are left for the CLIENT to
-- compute from the returned days — reproducing the identical formula here
-- in a second place is exactly the "no duplicate business logic" trap
-- 0020's header already named for the other severity feature; the raw
-- per-day counts are the one source of truth both a chart and a table read
-- from.
--
-- security invoker: RLS on events/entity_status/entity_action_log already
-- gates this correctly (auth.uid() is not null everywhere), same choice
-- 0020's dds_driver_asset_severity() made for the same reason.
create or replace function public.dds_driver_asset_weekly(
  p_from date default null,
  p_to   date default null
)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  with filtered as (
    select
      coalesce(emp_no, 'UNSPECIFIED') as driver_key,
      asset_id,
      shift_date,
      event_count
    from public.events
    where (p_from is null or shift_date >= p_from)
      and (p_to   is null or shift_date <= p_to)
  ),
  driver_days as (
    select driver_key as entity_id,
           to_char(shift_date, 'Dy') as day_label,
           jsonb_agg(event_count order by event_count desc) as counts
    from filtered
    group by driver_key, to_char(shift_date, 'Dy')
  ),
  asset_days as (
    select asset_id as entity_id,
           to_char(shift_date, 'Dy') as day_label,
           jsonb_agg(event_count order by event_count desc) as counts
    from filtered
    group by asset_id, to_char(shift_date, 'Dy')
  ),
  driver_entities as (
    select distinct driver_key as entity_id from filtered
  ),
  asset_entities as (
    select distinct asset_id as entity_id from filtered
  ),
  driver_names as (
    select coalesce(d.full_name, e.entity_id) as name, e.entity_id as driver_key
    from driver_entities e
    left join public.drivers d on d.emp_no = e.entity_id
  ),
  last_actions as (
    select distinct on (entity_type, entity_id)
      entity_type, entity_id, action_type, note, logged_by, created_at
    from public.entity_action_log
    order by entity_type, entity_id, created_at desc
  ),
  drivers_out as (
    select jsonb_build_object(
      'id', e.entity_id,
      'name', case when e.entity_id = 'UNSPECIFIED' then 'Unspecified' else n.name end,
      'days', coalesce((
        select jsonb_object_agg(day_label, counts)
        from driver_days dd where dd.entity_id = e.entity_id
      ), '{}'::jsonb),
      'status', coalesce((select status from public.entity_status
                           where entity_type = 'driver' and entity_id = e.entity_id), 'required'),
      'lastAction', (
        select jsonb_build_object(
          'type', la.action_type, 'note', la.note, 'by', la.logged_by,
          'at', to_char(la.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
        )
        from last_actions la where la.entity_type = 'driver' and la.entity_id = e.entity_id
      )
    ) as row
    from driver_entities e
    left join driver_names n on n.driver_key = e.entity_id
  ),
  assets_out as (
    select jsonb_build_object(
      'id', e.entity_id,
      'name', e.entity_id,
      'days', coalesce((
        select jsonb_object_agg(day_label, counts)
        from asset_days ad where ad.entity_id = e.entity_id
      ), '{}'::jsonb),
      'status', coalesce((select status from public.entity_status
                           where entity_type = 'asset' and entity_id = e.entity_id), 'required'),
      'lastAction', (
        select jsonb_build_object(
          'type', la.action_type, 'note', la.note, 'by', la.logged_by,
          'at', to_char(la.created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
        )
        from last_actions la where la.entity_type = 'asset' and la.entity_id = e.entity_id
      )
    ) as row
    from asset_entities e
  )
  select jsonb_build_object(
    'drivers', coalesce((select jsonb_agg(row) from drivers_out), '[]'::jsonb),
    'assets',  coalesce((select jsonb_agg(row) from assets_out), '[]'::jsonb)
  );
$$;

revoke all on function public.dds_driver_asset_weekly(date, date) from public, anon;
grant execute on function public.dds_driver_asset_weekly(date, date) to authenticated;

-- ── Read: full action history for one entity, newest first ─────────────────
-- Same shape/purpose as dds_entity_actions() (0007) but reading this
-- feature's own table — the two are deliberately not merged into one
-- function (mismatched action_type vocabularies, see header).
create or replace function public.dds_entity_action_history(
  p_entity_type text,
  p_entity_id   text
)
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'actionType', action_type,
    'actionOtherText', action_other_text,
    'note', note,
    'loggedBy', logged_by,
    'createdAt', to_char(created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  ) order by created_at desc), '[]'::jsonb)
  from public.entity_action_log
  where entity_type = p_entity_type and entity_id = p_entity_id;
$$;

revoke all on function public.dds_entity_action_history(text, text) from public, anon;
grant execute on function public.dds_entity_action_history(text, text) to authenticated;
