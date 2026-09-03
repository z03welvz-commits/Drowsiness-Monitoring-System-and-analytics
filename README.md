# DDS — Drowsiness Detection System

## What's in this repo

```
index.html                  ← THE APP. This is what deploys to GitHub Pages.
                               A single self-contained file: markup, styles,
                               and one inline <script> at the bottom. It talks
                               directly to Supabase (RPCs + table reads) —
                               there is no separate client-side data model or
                               build step. See "Architecture" below.
login.html                  ← Standalone sign-in page (username/password,
                               "Remember me", "Forgot password"). Signing in
                               here redirects to index.html — both must be
                               served from the same origin (see "Deploying")
                               or the session won't carry over between them.
reset-password.html         ← Where a password-reset email link lands.
                               Reads the recovery token, lets the user set a
                               new password, then redirects to login.html.
                               Referenced by resetPasswordForEmail()'s
                               redirectTo in both index.html and login.html.

.gitignore                  Blocks .env / keys / node_modules from ever
                             being committed.

supabase/migrations/        Schema, RPCs, and RLS policies, in the order they
                             were applied. 0001_init.sql through
                             0052_dds_reset_fleet_data_admin_gate.sql (some
                             numbers are intentionally skipped — batches that
                             were renumbered before merge). These are the
                             record of what's deployed on the live project
                             (rispydfovrnvnwvfwrnw) — apply them in order to
                             rebuild it from scratch.

supabase/functions/
  invite-user/                Admin-only Edge Function: invites a new user
                              by email via the Supabase Auth service-role
                              client, after re-checking the caller's own
                              admin status server-side from their JWT.

test/
  ingest-resolution.test.sql   psql test asserting dds_ingest()'s driver-name
                              resolution never silently drops a row.
  masterlist-resolver.test.sql psql test asserting dds_norm_name()/
                              dds_resolve_name()'s tier ladder and the roster
                              upsert's deactivate-don't-delete guarantee.
  Run either with:
                                psql -v ON_ERROR_STOP=1 -f supabase/migrations/000N_....sql \
                                     -v ON_ERROR_STOP=1 -f test/that-file.test.sql
                              against a scratch database with the migrations
                              already applied. Both run inside a transaction
                              that rolls back.

docs/
  superseded/                  Earlier build's docs and mockups, kept for
                              historical reference only — see "Architecture"
                              for why they no longer describe this app.
```

## Architecture

`index.html` is one file: a fixed set of pages (Overview, Analytics, Alert
Logs, Driver & Asset Monitoring, Data Management, Summary, Settings), each
wired directly to Supabase. There is no separate client-side data/aggregation
layer — every metric, table, and chart is computed server-side by a
Postgres RPC (`dds_metrics()`, `dds_alert_logs()`, `dds_driver_asset_weekly()`,
etc., all in `supabase/migrations/`) and rendered as-is. File uploads (DDS
alert exports, MineStat, the driver masterlist, contributing factors) parse
in the browser (CSV/XLSX) and write straight through `dds_ingest()` /
`dds_minestat_ingest()` / `dds_upsert_drivers()`; **there is no signed-out or
local-only import mode** — every upload path requires a session
(`requireSession()` gates each one) and writes to the real database.

This replaced an earlier, more complex build (client-side `derive()`/
`annotate()` in `src/dds-state.js`, computing the same metrics locally for a
signed-out/offline mode, with a parity test proving the JS and SQL sides
agreed). That build was fully replaced on 2026-09-01 by a separately-developed
prototype that had never been deployed — see git history around
`ab07107` if you need the old code. The `src/` directory, `test/parity.sh`,
`test/compare-derived.mjs`, and `test/fixture.json` were deleted because they
described/tested that old client-side path, which nothing in the live app
calls anymore; keeping them would have meant a "parity check passes" signal
that verified nothing about what actually ships. `docs/superseded/` holds the
docs written about that earlier build, each with a note at the top saying so.

If a local/offline import mode or a client-side parity check is wanted again,
it needs to be designed against the *current* `dds_metrics()` response shape
(introspect it directly — `select public.dds_metrics();` — rather than
trusting the old contract doc), not resurrected from the deleted files.

## Deploying

```bash
git clone <this repo>
cd <this repo>
# edit files as needed
git add .
git commit -m "..."
git push origin main
```

Then: **Settings → Pages → Source: Deploy from a branch → `main` / `/(root)`.**

The repo itself can stay **public** — the Supabase key constant in
index.html/login.html/reset-password.html (`sb_publishable_...`) is
Supabase's *publishable* key, meant to ship in every browser app. It grants
nothing on its own; Row Level Security on the database tables (and function
grants — see below) are the actual access boundary. There is no
`service_role` key or `.env` file in this repo — if one is ever generated for
server-side tooling later, it must never be committed (`.gitignore` already
blocks `.env*` and `*.key`).

## Supabase dashboard setup (one-time, zero cost)

Do this once, in the Supabase dashboard (not code), before relying on sign-in
or password reset on the deployed site:

1. **Authentication → URL Configuration**
   - **Site URL**: set to your real Pages URL.
   - **Redirect URLs**: add `<your Pages URL>/reset-password.html` —
     `resetPasswordForEmail()`'s `redirectTo` is computed at runtime from the
     current origin, but Supabase silently ignores any `redirectTo` not on
     this allow-list and falls back to Site URL instead, so the reset email
     link ends up nowhere useful until this is added.
2. **Authentication → Providers → Email**: turn off public sign-ups, unless
   you want anyone on the internet to self-register into your fleet data.
   New accounts land as `status='pending'` either way (can't sign in until an
   admin approves them in Settings → Access Management), but a still-open
   public-signup toggle lets anyone create a pending row and appear in that
   queue, which is a nuisance vector even though not a data-access one.

## Before you call it live

**1. Create a real user.**
Supabase Dashboard → Authentication → Users → Add user, then give that
account's `profiles` row `role='admin', status='approved'` directly in the
SQL editor (there is no self-service path to become the first admin — every
other admin action requires one to already exist). Without this, sign-in
will fail on every attempt and every upload will error with "Sign in
required."

**2. The database is empty until you import something while signed in.**
There is no local/offline fallback (see "Architecture") — importing while
signed out is not possible; every upload path requires a session.

**3. Two real regression tests exist for the driver-name resolution logic**
(`test/ingest-resolution.test.sql`, `test/masterlist-resolver.test.sql`) —
run them against a scratch database after any change to `dds_ingest()`,
`dds_norm_name()`, `dds_resolve_name()`, or the roster upsert. There is
currently no automated check for `dds_metrics()`'s own shift/actionable-window
arithmetic (the old `test/parity.sh` covered exactly that, but only for the
now-deleted client-side twin) — worth building one directly against
`dds_metrics()` if that logic changes again.

## Known open items

- **No automated regression test for `dds_metrics()`'s own aggregation
  logic** (shift attribution, actionable-window boundaries, sync-time
  buckets) — see point 3 above.
- `imports_delete`/`alert_cases_delete` RLS policies allow any signed-in user
  to delete any import/case (consistent with the single-tenant model — see
  `0001_init.sql`'s "any signed-in user reads all data, no site scoping" —
  not a bug), but there is no UI action that triggers either today; dormant,
  not urgent.
- Settings → System Management (Backup / Sync / Delete all data) is
  intentionally disabled in the UI rather than wired to anything real — see
  the comment at its markup in `index.html`. A real "delete all fleet data"
  action does exist server-side (`dds_reset_fleet_data()`, admin-gated as of
  `0052`) but is deliberately not exposed in the UI yet; wire it up with a
  real confirmation flow before enabling that button.
