# Apply Phase 1 to Supabase — copy/paste guide

I can't reach `rispydfovrnvnwvfwrnw` directly from this session (no Supabase
MCP tool, no `psql`, no working `python3` — confirmed on this machine). This
is the fastest path to get `0033_entity_monitoring.sql` live: two short
copy/paste steps in the Supabase SQL editor, in order.

## Step 1 — Apply the migration (~30 seconds)

1. Open the [Supabase dashboard](https://supabase.com/dashboard) → project
   `rispydfovrnvnwvfwrnw` → **SQL Editor** → **New query**.
2. Open `supabase/migrations/0033_entity_monitoring.sql` in this repo, copy
   its entire contents, paste into the SQL editor.
3. Click **Run**. Expect no output rows — it's all `CREATE TABLE`/
   `CREATE FUNCTION`/`CREATE TRIGGER` statements, silent on success.
4. If it errors, stop and paste the exact error back to me — don't retry
   blind. (I've checked it for dollar-quote/paren balance and cross-checked
   every column reference against the real schema, but a live run is the
   only real confirmation.)

**What this creates:** two tables (`entity_action_log`, `entity_status`),
one trigger on `events` (`trg_entity_status_reopen`), three functions
(`dds_log_entity_action`, `dds_driver_asset_weekly`,
`dds_entity_action_history`). Full rationale is in the file's own header
comment. It does **not** touch or modify anything that already exists.

## Step 2 — Verify it worked (~1 minute)

Paste and run this in a **new** SQL editor query:

```sql
select table_name from information_schema.tables
  where table_schema='public' and table_name in ('entity_action_log','entity_status')
order by table_name;

select routine_name from information_schema.routines
  where routine_schema='public'
    and routine_name in ('dds_log_entity_action','dds_driver_asset_weekly','dds_entity_action_history')
order by routine_name;

select trigger_name from information_schema.triggers
  where event_object_table = 'events' and trigger_name = 'trg_entity_status_reopen';
```

Expect: 2 rows from the first query, 3 from the second, 1 from the third.
If any are missing, Step 1 didn't fully apply — paste back what you got.

## Step 3 — Run the Alert Count Test (~30 seconds)

This is a **separate, independent check** — it doesn't depend on Step 1 at
all, it verifies the existing `dds_ingest()`/`dds_metrics()`/
`dds_alert_logs()`/`dds_alert_summary()` chain, which has never been
exercised end-to-end before. Good to run in the same sitting.

1. New query in the SQL editor.
2. Copy the entire contents of `test/alert-count-test.sql`, paste, **Run**.
3. Expect the **Messages** panel (not the results grid — this script only
   raises notices, it returns no rows) to show 6 lines starting with
   `PASS:`, ending in `=== ALL 6 ASSERTIONS PASSED ===`. It creates and then
   deletes its own test data (`imports`/`events` rows tagged
   `TEST-ALERT-COUNT-9001`) — nothing is left behind.
4. If anything says `FAIL:` instead, that's a real finding, not a script
   bug — it means the live database's dedup or counting behavior doesn't
   match what all 32 migration files say it should. Paste the exact
   `FAIL:` message back to me.

## After both steps

Tell me the result (pass/fail, and any error text) and I'll:
- Update `docs/DATA_MIGRATION_STATUS.md`'s two "NOT YET APPLIED"/
  "NOT YET RUN" sections with the real outcome.
- Mark Phase 1 fully complete in `MIGRATION_STATUS.md`, or fix whatever the
  failure reveals if something didn't hold.

This file can be deleted once both steps are done and recorded — it exists
only to make this one hand-off frictionless, not as permanent project
documentation (unlike `MIGRATION_MAP.md`/`MIGRATION_STATUS.md`/
`docs/DATA_MIGRATION_STATUS.md`, which do stay).
