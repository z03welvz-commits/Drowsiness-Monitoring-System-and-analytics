-- ============================================================================
-- DDS — 0004_auth_profiles
-- ----------------------------------------------------------------------------
-- Real accounts, at last — see 0001_init.sql's note that "Roles exist in the
-- UI but are not modelled here... Add it when those screens are built for
-- real." This is that.
--
-- USERNAME LOGIN — Supabase Auth is fundamentally email-based (auth.users.email
-- must be unique); there is no native username identity. This table maps a
-- chosen username to an auth.users row, and username_to_email() below resolves
-- username -> email so the client can call signInWithPassword() with the
-- username the person actually typed. The email itself may be real (entered at
-- sign-up or added later in Settings, and is what password-reset emails go to)
-- or a synthetic '<username>@no-email.invalid' placeholder — '.invalid' is an
-- RFC 6761 reserved TLD specifically for addresses that are guaranteed never to
-- resolve or be deliverable, so this can never collide with or misdirect mail
-- to a domain someone else owns.
--
-- APPROVAL — self-service sign-ups land as status='pending' and cannot sign in
-- (username_to_email() only resolves 'approved' rows) until an admin approves
-- them via Settings > User Management. Admin-created accounts (same table,
-- same signUp() call, just triggered from User Management instead of the
-- public sign-up form) are inserted as status='approved' directly — no
-- pending step, since an admin creating the account IS the approval.
--
-- BOOTSTRAP — profiles_update_admin below requires an existing approved admin
-- to approve anyone, which is unsatisfiable for the very first account. After
-- the first real sign-up, promote it once by hand via the Supabase SQL editor:
--   update public.profiles set role = 'admin', status = 'approved'
--     where username = '<first admin''s username>';
-- This is a deliberate one-time manual step, not something the app can safely
-- do itself (nothing should be able to self-promote to admin).
-- ============================================================================

create table public.profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  username     text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  role         text not null default 'oa' check (role in ('admin', 'oa', 'b2b')),
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  display_name text,
  created_at   timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Single tenant, same "any signed-in user reads all rows" shape as
-- contributing_factors (0003) — User Management needs to list everyone to
-- show pending accounts awaiting approval.
create policy profiles_read on public.profiles
  for select using (auth.uid() is not null);

-- Self-service sign-up: a user may create only their own row. status/role
-- both default (pending/oa) regardless of what a client tries to send —
-- there is deliberately no with-check allowing a caller to insert their own
-- row as already-approved or as admin; that path only exists via
-- profiles_update_admin below, gated on an existing admin's session.
create policy profiles_insert_self on public.profiles
  for insert with check (user_id = auth.uid());

-- Approval gate: only a caller whose OWN profile row is already
-- role='admin' AND status='approved' may update ANY row's status/role.
-- This is what makes "pending until an admin approves" real rather than a
-- UI-only label — see 0001_init.sql's note that role badges are display
-- state re-checked here, never trusted from the client.
create policy profiles_update_admin on public.profiles
  for update using (
    exists (
      select 1 from public.profiles p
      where p.user_id = auth.uid() and p.role = 'admin' and p.status = 'approved'
    )
  );

-- No anon or plain-authenticated read policy beyond profiles_read above, and
-- no policy at all lets a non-admin read another user's row differently —
-- profiles_read is intentionally coarse (single tenant, same as events/
-- imports in 0001_init.sql), not per-row scoped.

-- ── username -> email resolution ────────────────────────────────────────────
-- Must be callable by 'anon' (there is no session yet at sign-in time) as
-- well as 'authenticated' — a deliberate deviation from dds_ingest's
-- authenticated-only grant in 0002_metrics.sql, called out here because it's
-- the one function in this schema intentionally open to anon.
--
-- Returns null for an unknown username AND for a pending/rejected account —
-- both cases must produce the identical generic "sign-in failed" message
-- client-side (see Auth.doSignIn() in index.html), or a pending account's
-- existence becomes distinguishable from a wrong username (enumeration).
create or replace function public.username_to_email(p_username text)
returns text
language sql security definer
set search_path = public
as $$
  select u.email from auth.users u
  join public.profiles p on p.user_id = u.id
  where p.username = lower(p_username) and p.status = 'approved';
$$;

revoke all on function public.username_to_email from public;
grant execute on function public.username_to_email to anon, authenticated;
