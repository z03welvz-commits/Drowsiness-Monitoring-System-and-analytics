-- ============================================================================
-- DDS — 0159_alert_recipients_and_digest_state
-- ----------------------------------------------------------------------------
-- Part of adding email alerts for new critical events. Nothing today tells
-- anyone about a new critical drowsiness event unless they have the
-- dashboard open — confirmed this session: no Realtime subscriptions, no
-- SMTP, no webhooks anywhere in this app. This migration adds the two small
-- tables a scheduled digest needs; the digest logic itself lives in the new
-- dds_critical_events_since() RPC (0160) and the critical-alert-digest Edge
-- Function, not here.
--
-- alert_recipients: who gets the digest. Plain admin-managed list, same
-- shape and same RLS pattern as every other admin-only table in this app
-- (profiles_update_admin, 0004_auth_profiles.sql) — reused directly rather
-- than inventing a new access rule.
--
-- alert_digest_state: a single-row low-water mark (`last_sent_at`) so the
-- digest function knows "new since last run" without trusting wall-clock
-- cron scheduling drift, which is not guaranteed to be exact between GitHub
-- Actions runs. Seeded with one row at creation time so the very first
-- digest run only looks back from the moment this migration was applied,
-- not from the start of all recorded history.
-- ============================================================================

create table if not exists public.alert_recipients (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  active     boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create unique index if not exists uq_alert_recipients_email
  on public.alert_recipients (lower(email));

alter table public.alert_recipients enable row level security;

create policy alert_recipients_admin_all on public.alert_recipients
  for all using (
    exists (
      select 1 from public.profiles p
      where p.user_id = auth.uid() and p.role = 'admin' and p.status = 'approved'
    )
  ) with check (
    exists (
      select 1 from public.profiles p
      where p.user_id = auth.uid() and p.role = 'admin' and p.status = 'approved'
    )
  );

create table if not exists public.alert_digest_state (
  id           boolean primary key default true,
  last_sent_at timestamptz not null default now(),
  constraint alert_digest_state_singleton check (id)
);

insert into public.alert_digest_state (id, last_sent_at)
  values (true, now())
  on conflict (id) do nothing;

alter table public.alert_digest_state enable row level security;

-- No client policy at all: this table is read/written only by the Edge
-- Function's service-role client, which bypasses RLS — the same trust
-- boundary invite-user's privileged operations already rely on
-- (supabase/functions/invite-user/index.ts). Nothing here should ever be
-- read or written from the browser.
