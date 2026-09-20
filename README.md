# DDS — Drowsiness Detection System

A single-page fleet drowsiness-monitoring dashboard. Drivers/assets that
trigger "Sleep Alert"/"Drowsiness Alert" events get tracked, reviewed, and
actioned by supervisors across 7 pages, backed by a Postgres database
(Supabase) with row-level security as the real access boundary — there is
no separate application server.

## What's in this repo

```
index.html                  ← THE APP. Everything — markup, styles, and one
                               large inlined <script> — lives in this one
                               file, by deliberate choice (see "Known open
                               items" below for the trade-off this makes).
                               This is what deploys to GitHub Pages.
login.html                  ← Standalone sign-in page. Signing in here
                               redirects to index.html — both must be
                               served from the same origin (see "Deploying")
                               or the session won't carry over.
reset-password.html         ← Where a password-reset email link lands.

old_index.html               An earlier build, kept for reference only —
                               not served, not linked from anywhere live.

.gitignore                  Blocks .env / keys / node_modules from ever
                             being committed.

supabase/
  migrations/                162 SQL files (0001 → 0158, plus a handful of
                              unnumbered legacy ones), the full history of
                              every schema/function change ever applied to
                              the live Supabase project (rispydfovrnvnwvfwrnw).
                              Applied in order, they rebuild the schema from
                              scratch.
  functions/
    invite-user/              The one Edge Function in this repo — sends a
                              real invite email when an admin approves a
                              new user in Settings → Access Management.

test/
  parity.sh                  Proves the browser-side event math and the
                              database's own math agree byte-for-byte.
                              Needs `psql` + `python3` + `node`; builds a
                              scratch database and replays every migration.
  compare-derived.mjs         Node-only alternative — needs the SQL side's
                              output handed to it as a file, doesn't stand
                              up a database itself.
  fixture.json                 The edge-case rows both of the above test
                              against.

src/                         Six modules holding an earlier, un-inlined
                             copy of the core client logic (dds-state.js,
                             dds-charts.js, dds-a11y.js, dds-controls.js,
                             dds-insights.js, dds-tokens.css). **These are
                             historical, not live** — index.html's current
                             logic has moved well past what's captured
                             here, and nothing keeps the two in sync. Don't
                             edit these expecting it to affect the deployed
                             app.

docs/
  DDS_API_CONTRACT.md          The original metrics-endpoint contract this
                              project was designed against (time semantics,
                              shift-boundary rules) — still the reference
                              for how UTC/shift attribution works.
  DDS_SCALING_PLAN.md          Benchmarked results for large row counts.
  superseded/                  Earlier build artifacts and audit documents
                              that no longer reflect the live app, kept for
                              history rather than deleted.
```

## The app's pages

Sidebar nav, top to bottom: **Overview**, **Analytics**, **Alert Logs**,
**Driver & Asset Monitoring**, **Summary** (Monitoring section), then
**Data Management** and **Settings** (Management section). Driver & Asset
Monitoring covers both entity types with a Drivers/Assets tab and a This
Week/All-Time window toggle; it's the page where corrective actions
(Counseled, Suspended, Monitor, etc.) actually get logged. Only one person
can be in edit mode at a time app-wide (the badge in each page's header) —
this is enforced server-side, not just a UI hint.

## Deploying

```bash
git clone https://github.com/z03welvz-commits/Drowsiness-Monitoring-System-and-analytics.git
cd Drowsiness-Monitoring-System-and-analytics
git push origin main
```

Then: **Settings → Pages → Source: Deploy from a branch → `main` / `/(root)`.**

Live at whatever `https://<owner>.github.io/<repo>/` resolves to for this
repo once Pages is enabled — check repo Settings → Pages for the exact URL
and whether the last deployment succeeded (also visible under the repo's
Actions tab as an automatic "pages build and deployment" run, even though
there's no custom workflow file for it).

The repo itself can stay **public** — the `SUPABASE_KEY` constant in
index.html/login.html/reset-password.html (`sb_publishable_...`) is
Supabase's *publishable* key, meant to ship in every browser app. It grants
nothing on its own; Row Level Security on the database tables is the actual
access boundary. There is no `service_role` key or `.env` file in this repo
— if one is ever generated for server-side tooling later, it must never be
committed (`.gitignore` already blocks `.env*` and `*.key`).

## Supabase dashboard setup (one-time, zero cost)

Do this once, in the Supabase dashboard (not code), before relying on sign-in
or password reset on the deployed site:

1. **Authentication → URL Configuration**
   - **Site URL**: set to your real Pages URL.
   - **Redirect URLs**: add `<your Pages URL>/reset-password.html` —
     `resetPasswordForEmail()`'s `redirectTo` is computed at runtime from
     the current origin, but Supabase silently ignores any `redirectTo` not
     on this allow-list and falls back to Site URL instead, so the reset
     email link ends up nowhere useful until this is added.
2. **Authentication → Providers → Email**: turn off public sign-ups, unless
   you want anyone on the internet to self-register into your fleet data.

## Before you call it live — three things, in order

**1. Create a real user.**
Supabase Dashboard → Authentication → Users → Add user. Without this, the
Sign In button will fail on every attempt. While you're there: Authentication
→ Providers → Email → turn off public sign-ups.

**2. The database is empty until you import something while signed in.**
Signing in will work and show all zeros until data exists. Import while
signed in and it reaches the real database within seconds via `dds_ingest()`
(or `dds_minestat_ingest()` for the separate MineStat upload card).

**3. Run a parity check before your next SQL or shift-logic change.**

```bash
./test/parity.sh
```
It needs `psql` **and** a real `python3`; builds a scratch database and
replays every migration in `supabase/migrations/` to prove the browser-side
math and the database's own math still agree. `test/compare-derived.mjs`
is the lighter, Node-only alternative when you already have the SQL side's
output saved to a file.

## Known open items

- **No automated check runs on push or PR yet.** `test/parity.sh` and a
  `node --check` syntax pass on index.html's inlined script are both real,
  useful tests that currently only run when someone remembers to run them
  by hand.
- **Nobody is notified about a new critical event unless they have the
  dashboard open.** There's a "Sound" toggle in Settings, but it's a
  per-device preference with no alert pipeline wired to it yet.
- **Everything lives in one large `index.html`, on purpose.** This lets
  GitHub Pages serve the app with zero build step, at the cost of every
  page's logic living in one shared script. An earlier attempt to keep
  `src/*.js` as the real source of truth (see `src/` above) was abandoned
  because nothing enforced staying in sync with index.html — treat that
  directory as historical, not as something to edit.
- **Single production user account as of this writing.** The multi-user
  approval/role system (Settings → Access Management) and the app-wide
  single-editor lock both have real, working code behind them, but neither
  has been exercised with more than one real concurrent user yet.
