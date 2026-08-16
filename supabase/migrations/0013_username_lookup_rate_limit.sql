-- ============================================================================
-- DDS — 0013_username_lookup_rate_limit
-- ----------------------------------------------------------------------------
-- Closes an email-disclosure hole in username_to_email() (0004_auth_profiles).
--
-- THE PROBLEM. That function is SECURITY DEFINER, granted to `anon`, and has
-- no auth.uid() guard — all three deliberate, because sign-in has no session
-- yet and must resolve a typed username to the email signInWithPassword()
-- needs. But it RETURNS THE ADDRESS TO THE CALLER. Verified against the live
-- project: an unauthenticated POST to /rest/v1/rpc/username_to_email with a
-- valid username returns that user's real email. The publishable key needed
-- to make that call ships in login.html, so this is reachable by anyone.
--
-- That is username enumeration plus email disclosure: a script can walk a
-- wordlist and harvest every address behind an approved account, which is
-- exactly the input a phishing or credential-stuffing run wants.
--
-- 0004's own comment reasoned carefully about ONE enumeration channel — that
-- unknown and pending/rejected accounts must be indistinguishable, which it
-- correctly handles by collapsing both to null. The channel it did not
-- consider is that the SUCCESS case hands back a real address. RLS does not
-- help here: SECURITY DEFINER runs as the owner and bypasses it by design, so
-- the "RLS is the actual access boundary" note in README.md is true of tables
-- but was never true of this function.
--
-- WHAT THIS DOES, and what it deliberately does not.
--
-- Rate-limiting is MITIGATION, NOT ELIMINATION. Someone who knows a specific
-- username can still learn that one address. Eliminating it entirely means
-- not returning the email to the client at all (resolve inside the sign-in
-- step), which changes the login flow in both login.html and index.html —
-- deliberately out of scope here, since the app is in use and this migration
-- must not be able to break sign-in. What it does do is turn "harvest every
-- address in one script" into "guess one username at a time, slowly, with no
-- oracle" — which is the difference that matters for a bulk harvest.
--
-- Three changes, in order of how much they matter:
--
--   1. Per-caller rate limit. More than LOOKUP_MAX_ATTEMPTS lookups inside
--      LOOKUP_WINDOW returns null — the SAME value an unknown username
--      returns. A throttled attacker cannot tell "rate limited" from "no such
--      user", so the throttle itself leaks nothing.
--
--   2. Attempts are counted BEFORE the lookup, and counted for every call
--      including failures. Counting only successes would let an attacker
--      sweep unlimited wrong guesses for free, which is precisely the
--      enumeration sweep this is meant to stop.
--
--   3. The existing null-collapse for unknown/pending/rejected is preserved
--      exactly as 0004 wrote it. Nothing about the success path's shape
--      changes, so login.html and index.html need no edit: they already treat
--      null as the generic "sign-in failed" case.
--
-- WHAT IDENTIFIES A CALLER. PostgREST does not expose the client IP to SQL in
-- a way that can be trusted (it can be spoofed via forwarded headers), so
-- this keys on the LOWERCASED USERNAME BEING PROBED rather than on the
-- caller. That is the right key for this specific threat: a harvest sweep
-- necessarily probes many DIFFERENT usernames, and each one gets its own
-- budget consumed on the first few guesses. It also fails safe for real
-- users — a person mistyping their own password repeatedly is one username,
-- and login.html only calls this once per submit.
--
-- Note this means a determined attacker with one target username still gets
-- LOOKUP_MAX_ATTEMPTS tries per window. Accepted: the goal is stopping bulk
-- harvest, and per-IP limiting belongs at the edge (Supabase Auth rate limits
-- / a WAF), not in a SQL function that cannot see a trustworthy IP.
-- ============================================================================

-- ── Attempt log ────────────────────────────────────────────────────────────
-- One row per lookup attempt. Deliberately NOT keyed to profiles: attempts
-- are recorded for usernames that do not exist (that is the whole point), so
-- a foreign key would defeat it.
--
-- No RLS policies are created below, but RLS is ENABLED. That combination is
-- intentional and is the strictest possible setting: with RLS on and zero
-- policies, no client role can read or write this table through PostgREST at
-- all. Only the SECURITY DEFINER function touches it, running as owner. An
-- attempt log that attackers could read (to see which usernames others have
-- probed) or write (to lock a real user out by exhausting their budget)
-- would be worse than no log.

create table if not exists public.username_lookup_attempts (
  id            bigint generated always as identity primary key,
  -- Stored lowercased to match username_to_email()'s own lower(p_username)
  -- comparison, so 'Admin' and 'admin' share one budget rather than doubling
  -- the attacker's allowance through casing alone.
  username      text        not null,
  attempted_at  timestamptz not null default now()
);

alter table public.username_lookup_attempts enable row level security;

-- Lookup index for the windowed count below. attempted_at descending because
-- every query asks for the most recent window, never the oldest.
create index if not exists idx_username_lookup_attempts
  on public.username_lookup_attempts (username, attempted_at desc);

-- ── Rate-limited resolution ────────────────────────────────────────────────
-- Replaces 0004's definition. The SELECT at the bottom is character-for-
-- character 0004's original query; everything around it is new.

create or replace function public.username_to_email(p_username text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Tuned for a human typing their own username, not for a script. login.html
  -- calls this exactly once per sign-in submit and once per password-reset
  -- submit, so a real user hits 1-2 per attempt; 5 leaves room for genuine
  -- retries (mistyped password, then a correction) without being useful for
  -- a sweep.
  LOOKUP_MAX_ATTEMPTS constant integer  := 5;
  LOOKUP_WINDOW       constant interval := interval '1 minute';

  v_username text := lower(trim(coalesce(p_username, '')));
  v_attempts integer;
  v_email    text;
begin
  -- An empty/whitespace username can never match a profiles row (the
  -- username check constraint requires 3-20 chars), so return early rather
  -- than spending a rate-limit slot on it. Same null as every other
  -- non-resolving case.
  if v_username = '' then
    return null;
  end if;

  -- Count BEFORE the lookup and BEFORE inserting this attempt, so the Nth
  -- call in a window is the last one that can succeed.
  select count(*) into v_attempts
  from public.username_lookup_attempts
  where username = v_username
    and attempted_at > now() - LOOKUP_WINDOW;

  -- Record this attempt whether or not it is about to be refused: a refused
  -- attempt still extends the window, so hammering the endpoint keeps it
  -- locked rather than letting the budget bleed back mid-sweep.
  insert into public.username_lookup_attempts (username)
  values (v_username);

  if v_attempts >= LOOKUP_MAX_ATTEMPTS then
    -- Same null as an unknown username. The caller cannot distinguish
    -- "throttled" from "no such user", so the throttle is not itself an
    -- oracle telling an attacker they found a real account.
    return null;
  end if;

  -- 0004's original query, unchanged: resolves only approved accounts, and
  -- collapses unknown / pending / rejected to the same null.
  select u.email into v_email
  from auth.users u
  join public.profiles p on p.user_id = u.id
  where p.username = v_username and p.status = 'approved';

  return v_email;
end;
$$;

-- Grants restated exactly as 0004 had them. `anon` is still required: there
-- is no session at sign-in time. CREATE OR REPLACE preserves existing grants,
-- but restating them keeps this file readable as the current truth.
revoke all on function public.username_to_email from public;
grant execute on function public.username_to_email to anon, authenticated;

-- ── Housekeeping ───────────────────────────────────────────────────────────
-- The attempt log only ever needs the most recent window; rows older than
-- that are dead weight. There is no pg_cron on this project, so instead of
-- adding a scheduled job, each call prunes opportunistically: cheap, bounded,
-- and keeps the table from growing without limit under a sustained sweep.
--
-- Kept as a separate callable function rather than inlined into the hot path
-- so it can also be run manually, and so the delete predicate lives in one
-- place if the retention window is ever changed.

create or replace function public.prune_username_lookup_attempts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_deleted integer;
begin
  delete from public.username_lookup_attempts
  where attempted_at < now() - interval '1 hour';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

-- Not callable by anon or authenticated: nothing in the client needs it, and
-- an anon-callable delete over the rate-limit log would let an attacker reset
-- their own budget at will, which would undo this entire migration.
--
-- BOTH revokes are required, and the second is the one that actually does the
-- work. `revoke ... from public` only drops the PUBLIC pseudo-role's default
-- EXECUTE; it does NOT touch grants held directly by anon/authenticated,
-- which Supabase issues by default. Verified on the live project: after the
-- `from public` revoke alone, has_function_privilege('anon', ...) was still
-- true. Dropping either line re-opens the function.
revoke all on function public.prune_username_lookup_attempts() from public;
revoke all on function public.prune_username_lookup_attempts() from anon, authenticated;

-- ── Attempt-log grants ─────────────────────────────────────────────────────
-- RLS with zero policies already blocks every client read and write — checked
-- directly as the anon role against a table holding 10 rows: SELECT returned
-- 0 rows and DELETE removed 0. So this revoke is defence in depth, not the
-- primary control.
--
-- It earns its place anyway: with the table-level grants left in place, RLS is
-- the ONLY thing standing between anon and this table, and a later migration
-- that adds one permissive policy (or a `for all using (true)` written in
-- haste) would silently expose the whole log. Removing the grants means such a
-- policy still could not be exercised through PostgREST. An attacker able to
-- read this log learns which usernames have been probed; one able to delete
-- from it can reset their own rate-limit budget at will.
revoke all on table public.username_lookup_attempts from anon, authenticated;
