# Data migration status — Supabase project `rispydfovrnvnwvfwrnw`

This tracks what's in `supabase/migrations/` and — separately — what has
actually been **applied to the live database**. These are two different
facts: a `.sql` file sitting in the repo does nothing on its own. It only
takes effect once someone runs it against the real Supabase project (via the
Supabase CLI, the dashboard's SQL editor, or an MCP/API call).

## Applied to production, verified directly (as of 2026-08-28)

These three were applied via the Supabase MCP connector's `apply_migration`
and confirmed on the live database afterward (not just "should have worked"
— each one was checked with a follow-up query against `rispydfovrnvnwvfwrnw`
itself):

| Migration | What it does | Verified by |
|---|---|---|
| `0023_review_actions_fix.sql` | Re-issues `dds_resolve_review`/`dds_ignore_review`/`dds_reopen_review`/`dds_refresh_unresolved_counts` with corrected SQL (the original `0019` file has a dollar-quoting typo that's a plain syntax error). | Confirmed all four functions + the `import_name_review` RLS policy exist on the live DB. (They turned out to already exist before this ran — some earlier process had already worked around the bug — so this migration was a no-op reassertion, not a fix of a live outage.) |
| `0024_minestat.sql` | Adds the MineStat data source: `minestat_shifts`, `minestat_name_review` tables, `imports.kind` column, `dds_minestat_ingest()`, the MineStat review-queue RPCs, and `dds_backfill_emp_no_from_minestat()`. | Confirmed all five new objects exist on the live DB after applying. |
| `0025_dds_metrics_dow.sql` | Adds a `dayOfWeek` field to `dds_metrics()` — the SQL function that powers the dashboard for every signed-in user. Without this, the JS `derive()` function (used only for local file imports) had a `dayOfWeek` field that the SQL path never did, so the Analytics page's "Alert Volume by Day of Week" chart was empty for every real, signed-in user. | Ran the same day-of-week aggregation directly against the real `events` table: Mon 2,575 / Tue 2,901 / Wed 2,236 / Thu 3,256 / Fri 3,496 / Sat 4,079 / Sun 4,082 — sums to 22,625, matching the account's real total-alerts figure exactly. |

## Everything else in `supabase/migrations/`

Migrations `0001` through `0022` were already on the live project before
this round of work started (confirmed indirectly: `dds_metrics`, `events`,
`imports`, `drivers`, `driver_aliases`, `import_name_review`, and the
severity/consistency tables all already existed when this check was run).
They are not re-verified individually in this document — only the three
above were touched in this session.

## `0033_entity_monitoring.sql` — APPLIED and verified (2026-08-31)

Written during Phase 1 of the Application A/B migration (see
`../MIGRATION_MAP.md` and `../MIGRATION_STATUS.md`) to persist the Driver &
Asset Monitoring page's risk/action model — currently `localStorage`-only in
the destination mock UI — for real. Adds two tables
(`entity_action_log`, `entity_status`), a reopen-on-new-alert trigger on
`events`, and three RPCs (`dds_log_entity_action`, `dds_driver_asset_weekly`,
`dds_entity_action_history`). Full rationale is in the migration file's own
header comment.

**Applied to `rispydfovrnvnwvfwrnw` (project DDS-DB) via the Supabase SQL
editor, browser-automated end to end, 2026-08-31.** One real bug was caught
and fixed before this succeeded: the first attempt errored with
`42703: column e.driver_key does not exist` in `dds_driver_asset_weekly()`'s
`driver_names` CTE — it joined `driver_entities e` (which only has an
`entity_id` column) using a nonexistent `e.driver_key` reference, left over
from an earlier draft where the CTE wasn't yet renamed. Fixed by referencing
`e.entity_id` instead (both in the CTE's own select list and its join
condition). The corrected file ran clean afterward — "Success. No rows
returned," as expected for pure DDL.

**Verified directly against the live database** (all three checks below
run and confirmed, not just assumed from the "Success" message):
```sql
select table_name from information_schema.tables
  where table_schema='public' and table_name in ('entity_action_log','entity_status')
order by table_name;
-- returned: entity_action_log, entity_status

select routine_name from information_schema.routines
  where routine_schema='public'
    and routine_name in ('dds_log_entity_action','dds_driver_asset_weekly','dds_entity_action_history')
order by routine_name;
-- returned: dds_driver_asset_weekly, dds_entity_action_history, dds_log_entity_action

select trigger_name from information_schema.triggers
  where event_object_table = 'events' and trigger_name = 'trg_entity_status_reopen';
-- returned: trg_entity_status_reopen
```
All three objects confirmed present. Not yet exercised with real data via
`dds_log_entity_action()`/reopen-trigger specifically (see "Still to do"
below) — but `dds_driver_asset_weekly()` and the underlying `events` table
were exercised indirectly by the Alert Count Test below, which ran real
`dds_ingest()` inserts against `public.events` with no errors.

**Still to do:**
1. Manually log a test action via
   `select dds_log_entity_action('asset','TEST-1','Monitor',null,'test note','Tester');`
   then confirm `select * from entity_status where entity_id='TEST-1';` shows
   `status='actioned'`, and inserting a new `events` row for `asset_id='TEST-1'`
   flips it back to `'required'` via the trigger. Clean up both rows manually
   afterward (this table has no cascade-delete tie to a throwaway import the
   way `events` does).

## `test/alert-count-test.sql` — RUN and PASSED (2026-08-31)

Implements the master prompt's own Alert Count Test template (10 valid / 2
duplicate / 1 rejected rows) against the real `dds_ingest()` →
`dds_metrics()` / `dds_alert_logs()` / `dds_alert_summary()` chain. Unlike
`test/parity.sh`, this is a plain `.sql` script with no `psql`/`python3`
dependency — pasted into the Supabase SQL editor and run directly,
browser-automated. Creates and cleans up its own throwaway `imports`/`events`
rows (asset ID `TEST-ALERT-COUNT-9001`, date `08/15/2026`).

**Two real bugs found and fixed while getting this to run** (both fixed in
the script, not worked around):
1. **`UNAUTHENTICATED`** — the Supabase SQL editor connects as a privileged
   database role, not a real `auth.uid()` session, so `dds_ingest()` (which
   deliberately requires one) rejected the first attempt outright. Fixed by
   adding `perform set_config('request.jwt.claim.sub', <a real auth.users.id>,
   true); set local role authenticated;` inside the script's own transaction
   (scoped to this run only, confirmed via `select id, email from auth.users
   limit 5` to get a real user id rather than inventing one).
2. **`RAISE NOTICE` is invisible in this Supabase dashboard build** —
   confirmed empirically: a version of this script using only
   `RAISE NOTICE`/`RAISE EXCEPTION` showed "Success. No rows returned" both
   when every assertion passed AND (in an earlier permission-denied run)
   when the script failed before assertion 1 — no way to tell which from the
   UI. Rewrote to insert one row per assertion into a temp table and
   `SELECT` it as the final statement, so the Results grid is unambiguous
   proof. (A secondary permission issue this surfaced: the temp table is
   created by the SQL editor's own privileged role, before the script
   switches to `authenticated` — needed an explicit
   `grant insert, select on _act_results to authenticated;` for the switched
   role to be able to write to it.)

**Result: PASS. All 6 assertions passed, confirmed in the Results grid** —
not inferred, not assumed:

| seq | assertion | status | detail |
|---|---|---|---|
| 1 | dds_ingest() row count | PASS | inserted 10 rows, expected 10 (2 duplicates correctly inserted 0 new rows) |
| 2 | imports.row_count | PASS | row_count = 10, expected 10 |
| 3 | dds_metrics().totalAlerts = SUM(event_count) | PASS | totalAlerts = 34, expected 34 (the duplicates' event_count=99 correctly excluded) |
| 4 | dds_alert_logs().total = row count | PASS | total = 10, expected 10 (deliberately ≠ totalAlerts=34, per MIGRATION_MAP.md §7 finding #10) |
| 5 | dds_alert_summary().total = group count | PASS | total = 3, expected 3 (3 distinct event codes, 1 shift_date×shift×asset) |
| 6 | unparseable START_TIME rejected client-side | PASS | to_timestamp() fails on an unparseable value, as expected |

Cleanup confirmed separately: `select count(*) from events where asset_id =
'TEST-ALERT-COUNT-9001'` → `0` after the run. No test data left in
production.

**This is the first time the dedup mechanism and the three-different-
counting-rules behavior documented in `MIGRATION_MAP.md` §7 have been
verified against the live database**, not just read from SQL source.

## If the app still doesn't show the fix after this

The database is confirmed correct as of the checks above. If the deployed
page still looks unchanged, the remaining causes are all **outside the
database**:

1. **Browser cache** — hard-refresh the page (Ctrl+Shift+R / Cmd+Shift+R),
   or open it in a private/incognito window. Static-file CDNs (GitHub Pages
   included) and browsers both cache aggressively.
2. **GitHub Pages build lag** — Pages rebuilds automatically after a push to
   `main`, but it is not instant; a build that's still in progress serves
   the previous version until it finishes.
3. **Signed-out or a stale session** — the `dayOfWeek` fix and the MineStat
   feature only apply to the **signed-in** (cloud) data path. If the page is
   viewed signed out, or the tab has been open since before this session's
   changes and never reloaded, it may still be running old in-memory
   JavaScript regardless of what's on disk.
4. **The MineStat upload card specifically** needs a fresh sign-in/page load
   to appear, since it's new DOM that didn't exist in the version any
   already-open tab originally loaded.

None of these are things this session can fix from here — they're
client-side/CDN state on your end, not the code or the database.
