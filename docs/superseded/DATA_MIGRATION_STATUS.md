> **Superseded 2026-09-03.** Written against the pre-`ab07107` frontend
> (references the client-side `derive()`/`dayOfWeek` gap, since fixed, and
> predates migrations past `0025`). The database facts below (which
> migrations existed as of 2026-08-28) are historical; the current schema is
> ahead of this by 27+ migrations. Kept for historical reference only.

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
