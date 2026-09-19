-- ============================================================================
-- DDS — 0149_edit_lock_core
-- ----------------------------------------------------------------------------
-- New feature, per direct request: "add an access control button that allow
-- one editor at a time, other user can request edit and this will pop up to
-- the user and will prompt for release edit mode or reject request. admin
-- access can override any active user in editor mode and terminate their
-- editing session with valid reason." Scoped with the user as: a whole-app
-- single lock (not per-page/per-record), auto-release after an idle timeout
-- rather than holding indefinitely, and short polling (the app has no
-- realtime/websocket infrastructure today).
--
-- This migration adds the lock's own storage and management RPCs only.
-- Retrofitting the existing write surface to actually require the lock is
-- 0150 (RLS policies on the handful of raw-client-writable tables) and 0151
-- (the ~20 SECURITY DEFINER write RPCs) — both layers are needed together:
-- a SECURITY DEFINER function bypasses RLS on the tables it touches
-- internally, and RLS alone doesn't stop a direct REST call that skips an
-- RPC entirely. Matches this repo's own documented philosophy
-- (MIGRATION_MAP.md §9): client-side checks mirror the real check, they
-- never replace it.
--
-- Deliberately NOT gated by this lock (decided during scoping, not an
-- oversight): Access Management writes (profiles approve/reject/role-change,
-- the invite-user edge function) and personal writes (own display name/
-- email/password, user_settings theme/sound preference). Gating those would
-- create a bootstrapping deadlock — an admin unable to approve a new user
-- because someone else happens to hold the edit lock — for no real
-- coordination benefit, since neither is the kind of shared operational
-- data two people could actually clobber.
-- ============================================================================

-- Singleton: exactly one row, ever. `id = 1` is enforced by the check
-- constraint, not just convention — a second row can never be inserted.
create table public.edit_lock (
  id                    integer primary key default 1 check (id = 1),
  held_by               uuid references auth.users(id) on delete set null,
  acquired_at           timestamptz,
  last_heartbeat_at     timestamptz,
  pending_request_by    uuid references auth.users(id) on delete set null,
  pending_requested_at  timestamptz
);
insert into public.edit_lock (id) values (1) on conflict (id) do nothing;

alter table public.edit_lock enable row level security;
create policy edit_lock_read on public.edit_lock for select using (auth.uid() is not null);
-- Zero write policies, deliberately — mutated only via the SECURITY DEFINER
-- RPCs below, the same deny-all-direct-writes pattern username_lookup_
-- attempts (0013) uses for the same reason (force every write through a
-- function that can enforce the real invariants atomically).

-- Append-only audit trail — same shape/naming convention as
-- emp_no_attribution_conflicts' state/resolved_by/resolved_at columns (0139).
create table public.edit_lock_log (
  id             bigint generated always as identity primary key,
  event_type     text not null check (event_type in ('acquired','released','granted','requested','denied','overridden')),
  actor_user_id  uuid references auth.users(id) on delete set null,
  target_user_id uuid references auth.users(id) on delete set null,
  reason         text,
  created_at     timestamptz not null default now()
);
create index idx_edit_lock_log_created on public.edit_lock_log (created_at desc);

alter table public.edit_lock_log enable row level security;
create policy edit_lock_log_read on public.edit_lock_log for select using (auth.uid() is not null);
-- Same deny-all-writes pattern — only the RPCs below ever insert here.

-- Single source of truth for the idle threshold. dds_edit_lock_acquire()'s
-- steal-clause and dds_edit_lock_status()'s isExpired flag both call this —
-- if the threshold ever needs tuning, changing it here changes it
-- everywhere at once, so the two can never silently drift out of sync.
create or replace function public.dds_edit_lock_is_stale(p_last_heartbeat timestamptz)
returns boolean
language sql
stable
as $function$
  select p_last_heartbeat is null or p_last_heartbeat < now() - interval '12 minutes';
$function$;

-- Used directly inside RLS policy expressions in 0150. Plain STABLE/INVOKER
-- is correct and sufficient — it only reads a table `authenticated` already
-- has RLS-gated SELECT access to, so SECURITY DEFINER would be an
-- unnecessary privilege escalation for what is just an existence check.
create or replace function public.dds_edit_lock_ok()
returns boolean
language sql
stable
as $function$
  select exists(select 1 from public.edit_lock where id = 1 and held_by = auth.uid());
$function$;
revoke all on function public.dds_edit_lock_ok() from public, anon;
grant execute on function public.dds_edit_lock_ok() to authenticated;

-- Internal-only guard for the write RPCs retrofitted in 0151. Never granted
-- to any role, including authenticated — a SECURITY DEFINER function's
-- owner always has implicit execute on its own objects, so this still works
-- when called from inside another SECURITY DEFINER function's body while
-- fully blocking any direct client RPC call to it.
create or replace function public.dds_require_edit_lock()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not public.dds_edit_lock_ok() then
    raise exception 'EDIT_LOCK_REQUIRED' using errcode = '42501';
  end if;
end;
$function$;
revoke all on function public.dds_require_edit_lock() from public, anon, authenticated;

create or replace function public.dds_edit_lock_status()
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'public'
as $function$
declare
  v jsonb;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'heldBy', l.held_by,
    'heldByName', coalesce(hp.display_name, hp.username),
    'acquiredAt', to_char(l.acquired_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'lastHeartbeatAt', to_char(l.last_heartbeat_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'isMine', l.held_by is not null and l.held_by = auth.uid(),
    'isExpired', l.held_by is not null and public.dds_edit_lock_is_stale(l.last_heartbeat_at),
    'pendingRequestBy', l.pending_request_by,
    'pendingRequestByName', coalesce(pp.display_name, pp.username),
    'pendingRequestedAt', to_char(l.pending_requested_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'isPendingMine', l.pending_request_by is not null and l.pending_request_by = auth.uid()
  ) into v
  from public.edit_lock l
  left join public.profiles hp on hp.user_id = l.held_by
  left join public.profiles pp on pp.user_id = l.pending_request_by
  where l.id = 1;

  return v;
end;
$function$;
revoke all on function public.dds_edit_lock_status() from public, anon;
grant execute on function public.dds_edit_lock_status() to authenticated;

-- Atomic acquire: a single conditional UPDATE, not a SELECT-then-UPDATE —
-- Postgres serializes concurrent UPDATEs against the same row, so if two
-- callers race for a free (or stale) lock, exactly one WHERE clause
-- evaluation sees the row still eligible and wins; the other affects zero
-- rows and raises.
create or replace function public.dds_edit_lock_acquire()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rows integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  update public.edit_lock
     set held_by = auth.uid(), acquired_at = now(), last_heartbeat_at = now(),
         pending_request_by = null, pending_requested_at = null
   where id = 1
     and (held_by is null or held_by = auth.uid() or public.dds_edit_lock_is_stale(last_heartbeat_at));
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    raise exception 'EDIT_LOCK_HELD' using errcode = '42501';
  end if;

  insert into public.edit_lock_log (event_type, actor_user_id) values ('acquired', auth.uid());
  return public.dds_edit_lock_status();
end;
$function$;
revoke all on function public.dds_edit_lock_acquire() from public, anon;
grant execute on function public.dds_edit_lock_acquire() to authenticated;

-- Called periodically by the current holder while genuinely active (wired
-- to real mouse/keyboard/upload-progress activity client-side, not just a
-- timer) — proves liveness so dds_edit_lock_acquire()'s steal-clause only
-- ever fires against a truly abandoned lock. NOT_LOCK_HOLDER is expected and
-- silent-resync-worthy the moment the lock has already changed hands
-- (stolen, released, overridden) — the client's next status() poll picks
-- up the real state.
create or replace function public.dds_edit_lock_heartbeat()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rows integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  update public.edit_lock set last_heartbeat_at = now() where id = 1 and held_by = auth.uid();
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    raise exception 'NOT_LOCK_HOLDER' using errcode = '42501';
  end if;

  return public.dds_edit_lock_status();
end;
$function$;
revoke all on function public.dds_edit_lock_heartbeat() from public, anon;
grant execute on function public.dds_edit_lock_heartbeat() to authenticated;

-- Only meaningful against a lock someone else currently holds — requesting
-- an unheld lock is nonsensical (the client should just acquire() directly),
-- and requesting your own lock is a no-op error too. v1 tracks only one
-- pending requester at a time ("last request wins"): a second request()
-- while one is already pending simply replaces it — the outbid requester's
-- own isPendingMine flips false on their next status() poll and their badge
-- reverts on its own, so no extra queue/notification plumbing is needed for
-- this deliberately simple v1 behavior.
create or replace function public.dds_edit_lock_request()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rows integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  update public.edit_lock
     set pending_request_by = auth.uid(), pending_requested_at = now()
   where id = 1 and held_by is not null and held_by <> auth.uid();
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    raise exception 'NOT_HELD' using errcode = '42501';
  end if;

  insert into public.edit_lock_log (event_type, actor_user_id) values ('requested', auth.uid());
  return public.dds_edit_lock_status();
end;
$function$;
revoke all on function public.dds_edit_lock_request() from public, anon;
grant execute on function public.dds_edit_lock_request() to authenticated;

-- The current holder's own "I'm done" action. `select ... for update` reads
-- the pre-update pending_request_by atomically (within the same row lock as
-- the update that follows), so this can't race a concurrent request()/
-- reject_request() call into logging the wrong outcome. Default behavior
-- (p_grant_to_pending = true) directly implements the "prompt for release
-- edit mode" half of the requested UX: if someone is waiting, releasing
-- hands the lock straight to them rather than leaving it open for anyone.
create or replace function public.dds_edit_lock_release(p_grant_to_pending boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_pending_by uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  select pending_request_by into v_pending_by
  from public.edit_lock where id = 1 and held_by = auth.uid()
  for update;

  if not found then
    raise exception 'NOT_LOCK_HOLDER' using errcode = '42501';
  end if;

  if p_grant_to_pending and v_pending_by is not null then
    update public.edit_lock
       set held_by = v_pending_by, acquired_at = now(), last_heartbeat_at = now(),
           pending_request_by = null, pending_requested_at = null
     where id = 1;
    insert into public.edit_lock_log (event_type, actor_user_id, target_user_id)
    values ('granted', auth.uid(), v_pending_by);
  else
    update public.edit_lock
       set held_by = null, acquired_at = null, last_heartbeat_at = null,
           pending_request_by = null, pending_requested_at = null
     where id = 1;
    insert into public.edit_lock_log (event_type, actor_user_id) values ('released', auth.uid());
  end if;

  return public.dds_edit_lock_status();
end;
$function$;
revoke all on function public.dds_edit_lock_release(boolean) from public, anon;
grant execute on function public.dds_edit_lock_release(boolean) to authenticated;

-- The current holder's "reject request" action — the other half of
-- "prompt for release edit mode or reject request." Keeps holding the
-- lock; only clears the pending request.
create or replace function public.dds_edit_lock_reject_request()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_rows integer;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  update public.edit_lock set pending_request_by = null, pending_requested_at = null
   where id = 1 and held_by = auth.uid() and pending_request_by is not null;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    raise exception 'NO_PENDING_REQUEST' using errcode = '42501';
  end if;

  insert into public.edit_lock_log (event_type, actor_user_id) values ('denied', auth.uid());
  return public.dds_edit_lock_status();
end;
$function$;
revoke all on function public.dds_edit_lock_reject_request() from public, anon;
grant execute on function public.dds_edit_lock_reject_request() to authenticated;

-- "Admin access can override any active user in editor mode and terminate
-- their editing session with valid reason." Admin check follows this
-- codebase's existing inline-EXISTS idiom (no is_admin() helper exists yet
-- anywhere in this schema — see profiles_update_admin / 0038's
-- profiles_guard_self_update trigger for the same shape). `select ... for
-- update` reads the pre-update held_by atomically so the audit log's
-- target_user_id is always correct — a plain `update ... returning
-- held_by` would return the POST-image (null), and a separate SELECT before
-- the UPDATE would be a TOCTOU race against a concurrent release/acquire.
-- No-ops (no log row) if nothing is currently held — nothing to override.
create or replace function public.dds_edit_lock_override(p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_prev_holder uuid;
begin
  if auth.uid() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.user_id = auth.uid() and p.role = 'admin' and p.status = 'approved'
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if coalesce(trim(p_reason), '') = '' then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;

  select held_by into v_prev_holder from public.edit_lock where id = 1 for update;

  if v_prev_holder is not null then
    update public.edit_lock
       set held_by = null, acquired_at = null, last_heartbeat_at = null,
           pending_request_by = null, pending_requested_at = null
     where id = 1;
    insert into public.edit_lock_log (event_type, actor_user_id, target_user_id, reason)
    values ('overridden', auth.uid(), v_prev_holder, trim(p_reason));
  end if;

  return public.dds_edit_lock_status();
end;
$function$;
revoke all on function public.dds_edit_lock_override(text) from public, anon;
grant execute on function public.dds_edit_lock_override(text) to authenticated;
