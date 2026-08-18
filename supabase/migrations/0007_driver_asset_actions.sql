-- ============================================================================
-- DDS — 0007_driver_asset_actions
-- ----------------------------------------------------------------------------
-- Action HISTORY for the Driver & Asset Monitoring page, keyed by driver name
-- or asset/unit ID rather than by a single alert row — a driver/unit flagged
-- High there is an aggregate across many alerts, so there is no one event_id
-- to attach an action to the way alert_cases (applied live; not checked in) does.
--
-- APPEND-ONLY, unlike alert_cases: alert_cases is "current state, overwrite
-- on edit" (see its own comment in index.html). This table is the opposite —
-- every action taken is its own row, newest first, so "coached on 8/10, then
-- reassigned to a different unit on 8/14" both stay visible instead of the
-- second action erasing the first. No update/delete policy is granted below;
-- once logged, a row is permanent history.
--
-- SAME ACTION VOCABULARY AS ALERT LOGS — action_type reuses the exact same
-- option set alert_cases.action_type already uses ('Replace driver',
-- 'Disciplinary action', 'Other' + free text), so an action logged from
-- Monitoring reads as the same kind of record as one logged from Alert Logs,
-- not a parallel/incompatible taxonomy. 'Noted' is added as a neutral
-- default suited to units (which "Replace driver"/"Disciplinary action"
-- don't fit) and to drivers when no other category applies.
--
-- actor_username is DENORMALIZED (copied at insert time, not looked up via a
-- join to profiles) so history reads correctly even if that account is later
-- renamed or removed — the same tradeoff Cloud.myUsername() callers already
-- accept elsewhere in this app (see Auth.lastUsername's own comment on why a
-- point-in-time username is preferred over a live foreign-key lookup for
-- display purposes).
-- ============================================================================

create table public.driver_asset_actions (
  id            uuid primary key default gen_random_uuid(),

  entity_type   text not null check (entity_type in ('driver', 'asset')),
  entity_id     text not null,        -- OPERATOR name or ASSET_ID, matched as typed (see index.html's UNSPECIFIED_OPERATOR handling for the 'Unspecified' driver bucket)

  action_type   text not null,        -- 'Replace driver' | 'Disciplinary action' | 'Noted' | 'Other' (+ free text via action_is_other)
  action_is_other boolean not null default false,
  remarks       text,

  -- Where this action was logged from — Monitoring's own "Add action" flow,
  -- or carried over automatically when a matching alert_cases action is
  -- upserted from Alert Logs (see dds_log_driver_asset_action() below and
  -- the client-side call added alongside Cloud.upsertAlertCase).
  source        text not null default 'monitoring' check (source in ('monitoring', 'alert_logs')),

  actor_user_id uuid references auth.users(id) on delete set null,
  actor_username text,

  created_at    timestamptz not null default now()
);

create index idx_daa_entity on public.driver_asset_actions (entity_type, entity_id, created_at desc);

alter table public.driver_asset_actions enable row level security;

-- Single tenant, same shape as contributing_factors (0003) and profiles
-- (0004): any signed-in user reads all history, any signed-in user may add
-- a new action (attributed to themselves — with-check pins actor_user_id to
-- auth.uid(), same pattern as factors_insert). No update/delete policy at
-- all — see the append-only note above.
create policy daa_read on public.driver_asset_actions
  for select using (auth.uid() is not null);
create policy daa_insert on public.driver_asset_actions
  for insert with check (auth.uid() is not null and actor_user_id = auth.uid());

-- ── Read: full history for one entity, newest first ─────────────────────────
create or replace function public.dds_entity_actions(
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
    'actionIsOther', action_is_other,
    'remarks', remarks,
    'source', source,
    'actorUsername', actor_username,
    'createdAt', to_char(created_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  ) order by created_at desc), '[]'::jsonb)
  from public.driver_asset_actions
  where entity_type = p_entity_type and entity_id = p_entity_id;
$$;

revoke all on function public.dds_entity_actions from public;
grant execute on function public.dds_entity_actions to authenticated;

-- ── Write: log a new action, attributed to the caller ────────────────────────
-- security definer so actor_username can be resolved server-side from
-- profiles (the client only sends what it wants recorded, not who — that
-- comes from auth.uid()/the session, same trust boundary dds_ingest() and
-- username_to_email() already draw elsewhere in this schema).
create or replace function public.dds_log_driver_asset_action(
  p_entity_type   text,
  p_entity_id     text,
  p_action_type   text,
  p_action_is_other boolean,
  p_remarks       text,
  p_source        text default 'monitoring'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_username text;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select username into v_username from public.profiles where user_id = auth.uid();

  insert into public.driver_asset_actions (
    entity_type, entity_id, action_type, action_is_other, remarks,
    source, actor_user_id, actor_username
  ) values (
    p_entity_type, p_entity_id, p_action_type, coalesce(p_action_is_other, false), p_remarks,
    coalesce(p_source, 'monitoring'), auth.uid(), v_username
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.dds_log_driver_asset_action from public;
grant execute on function public.dds_log_driver_asset_action to authenticated;
