# DDS — Drowsiness Detection System

## What's in this zip

```
index.html                  ← THE APP. This is what deploys to GitHub Pages.
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
                               Everything below is source, tests, and docs —
                               nothing else needs to go live.

.gitignore                  Blocks .env / keys / node_modules from ever
                             being committed.

supabase/migrations/
  0001_init.sql              Schema: events, imports, user_settings, RLS.
  0002_metrics.sql           dds_metrics() + dds_ingest() — the functions
                              index.html calls when you're signed in.
                              Already applied to your live Supabase project
                              (rispydfovrnvnwvfwrnw). These files are the
                              record of what's deployed, in case you need to
                              rebuild the project from scratch.

test/
  parity.sh                  Proves the JS shift/actionable logic and the SQL
                              version agree byte-for-byte. Run this after ANY
                              change to src/dds-state.js or the migrations —
                              it's the only thing that catches the two engines
                              silently drifting apart.
  fixture.json                39 edge-case rows parity.sh tests against
                              (boundary seconds, night-shift tails, clock
                              skew, formula-injection strings).

src/                         The six modules, un-inlined. index.html already
                             contains all of this pasted together — these
                             files exist so you can edit one concern (say,
                             just the charts) without scrolling through a
                             200KB file. If you edit here, you must also
                             paste the change into index.html, or your live
                             site won't match your source.
  dds-state.js                Data model: parsing, shift/actionable logic,
                              the `derive()` aggregation. This is the file
                              parity.sh checks against SQL.
  dds-charts.js                One renderer for all 13 charts (replaces
                              v2.2's two diverged chart engines).
  dds-a11y.js                 Roles, accessible names, live region,
                              screen-reader data tables for every chart.
  dds-controls.js              Filter dropdowns, CSV export, empty states.
  dds-insights.js              The Analytics summary panel — narrative
                              headline, hero metric, sparkline.
  dds-tokens.css                Design tokens: spacing, type, color (WCAG AA
                              verified), states, responsive breakpoints.

docs/
  DDS_API_CONTRACT.md          What dds_metrics() returns and why, including
                              the two decisions you have to get right before
                              touching the SQL: UTC-naive timestamps, and the
                              shift-boundary rule.
  DDS_SCALING_PLAN.md          Benchmarked results for 1M+ rows (measured,
                              not estimated) — where the current bottlenecks
                              are and what closes them.
  superseded/                  Earlier build artifacts, kept for reference:
    DDS_v3_no-auth.html          The version before Supabase auth was wired
                                in. Only relevant if you need to see what
                                changed.
    summary-preview.html         Static preview of the insight-panel design,
                                from before it was wired to real data.
```

## Deploying

```bash
git clone https://github.com/mtsodepartment-hue/DDS-Monitoring-and-Analytics-Flatform.git
cd DDS-Monitoring-and-Analytics-Flatform
# copy everything from this zip's root into the repo root
git add .
git commit -m "DDS v3.1 — hosted build with Supabase auth"
git push origin main
```

Then: **Settings → Pages → Source: Deploy from a branch → `main` / `/(root)`.**//

Live in about a minute at:
`https://mtsodepartment-hue.github.io/DDS-Monitoring-and-Analytics-Flatform/`

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
   - **Site URL**: set to your real Pages URL, e.g.
     `https://mtsodepartment-hue.github.io/DDS-Monitoring-and-Analytics-Flatform/`
   - **Redirect URLs**: add
     `https://mtsodepartment-hue.github.io/DDS-Monitoring-and-Analytics-Flatform/reset-password.html`
     — `resetPasswordForEmail()`'s `redirectTo` is computed at runtime from
     the current origin, but Supabase silently ignores any `redirectTo` not
     on this allow-list and falls back to Site URL instead, so the reset
     email link ends up nowhere useful until this is added.
2. **Authentication → Providers → Email**: turn off public sign-ups, unless
   you want anyone on the internet to self-register into your fleet data
   (see "Create a real user" below — this is the same setting).

## Before you call it live — three things, in order

**1. Create a real user.**
Supabase Dashboard → Authentication → Users → Add user. Without this, the
Sign In button will fail on every attempt and you'll spend time debugging a
connection that isn't actually broken. While you're there: Authentication →
Providers → Email → turn off public sign-ups, unless you want anyone on the
internet to self-register into your fleet data.

**2. The database is empty.**
Signing in will work and show all zeros until data exists. The import
pipeline currently writes to browser-local state only — connecting the
dropzone to actually upload via `dds_ingest()` is the next real piece of
work, not yet done.

**3. Run a parity check before your next SQL or shift-logic change.**

There are two, and they answer the same question with different setup costs.

`test/parity.sh` is the full end-to-end test — it builds a scratch database,
replays every migration, ingests the fixture through `dds_ingest()`, and diffs
the result against `derive()`. It is the stronger test, and the one to run in
CI.
```bash
./test/parity.sh
```
It needs `psql` **and** a real `python3`. On a stock Windows machine it cannot
run at all: `psql` is absent unless you install Postgres, and the `python3` on
PATH is the Microsoft Store stub, which prints an install advert and exits
non-zero.

`test/compare-derived.mjs` needs only Node, which you already have. It does not
build a database; you give it the SQL side's output as a file (from the
Supabase SQL editor, `psql`, or any REST/MCP call) and it diffs that against
the JS side using the same normalisation rules `parity.sh` applies.
```bash
node test/compare-derived.mjs sql.json     # diff against a saved SQL result
node test/compare-derived.mjs --emit-js    # just print the JS side
```
Exit code is 0 on match and 1 on any difference, so either works in CI.

Whichever you run, this is the only thing standing between "JS and SQL agree"
and "JS and SQL silently disagree in a way that shows up as wrong numbers, not
an error."

## Known open items

- Settings and User Management pages are still prototypes — the Save buttons
  show a success toast without persisting anything. Nobody has decided what
  a user record or a settings row actually contains yet, so this is
  deliberately not modeled in the schema until those screens are built for
  real.
- The `activeDays` calculation in the insight panel's rate metric uses a
  slightly different definition for server data (days-with-data-in-range)
  than for local-import data (distinct shift dates). They usually agree but
  can diverge on sparse date ranges — worth aligning before treating the
  "alerts per asset per active day" figure as precise on a thin server query.
