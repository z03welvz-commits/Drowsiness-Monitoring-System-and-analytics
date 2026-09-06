# Pending 102 — Full pipeline audit + fix plan (code↔DB, live-verified)

Requested as a senior-developer-level audit: trace upload→ingest→matching→
severity→query end to end against the real database (98,877 events, 2,425
masterlist employees), validate before building, sequence the big pieces
before implementing. This document is the audit output plus the proposed
plan — **nothing below has been implemented yet**, pending your go-ahead
per item.

---

## Part A — What's actually broken, with evidence

### A1. Why "Unspecified" dominates (88.5% of alerts, confirmed live)

Two independent, confirmed mechanisms, both real:

1. **Blank OPERATOR fields are silently untracked.** In `dds_ingest()`
   (`supabase/migrations/0032_attribution_audit_fixes.sql:31-115`), a row
   whose source OPERATOR is blank never enters the `_resolved` CTE at all
   (`where c.norm_name is not null`, line 72) — it doesn't even get logged
   to the review queue. A *populated but unmatched* name at least gets
   logged there (for whatever that's worth today — see A3).

2. **The Minestat→DDS backfill RPC is never called.** `dds_backfill_emp_no_
   from_minestat()` (latest `0047_audit_fixes_batch1.sql:57-155`) is the
   only code path that would join a resolved Minestat operator name onto
   the corresponding `events.emp_no`. It has **zero call sites** in
   `index.html`. Migration 0047's own comment claims it "runs after every
   DDS/Minestat upload" — that claim is false against the current client
   code. So even when a Minestat file resolves a driver correctly, that
   resolution never reaches the DDS alert rows Alert Logs/Analytics/
   Driver & Asset actually display.

### A2. The masterlist `status='inactive'` mystery — genuinely unresolved

Read every code path that could write `drivers.status`:
- `dds_upsert_drivers()` (`0018_driver_masterlist.sql:547,570`) defaults to
  `'active'` in **two** places, never defaults to `'inactive'`.
- The client's XLSX parser (`workbookRowToMasterlistRow()`,
  `index.html:5650-5663`) also defaults to `'active'` unless a cell
  literally reads "Inactive".
- The mass-deactivate path (`p_deactivate=true`) is never invoked — both
  client call sites hardcode `p_deactivate: false`.

**No code path in this repo can produce 2,425 `status='inactive'` rows.**
Separately (and this compounds the mystery rather than explaining it): the
real masterlist file checked into the repo, `assets/Emp_Masterlist.xlsx`,
has columns **"ID Number"** and **"Employee Name"** — headers that match
*none* of the app's alias list (`['Employee ID','EMP_NO','Employee No',
'EmpID']` / `['Name','Full Name']`). Uploading that exact file today would
import **zero rows**, not 2,425 inactive ones.

Working hypothesis, not confirmed: the 2,425 rows were loaded by a path
outside this app entirely (direct SQL/API insert, consistent with how
other tables in this project were seeded per `docs/DATA_MIGRATION_STATUS.md`).
**This needs your input** — do you know how the masterlist was actually
populated? That answer determines whether this is a data problem (re-import
correctly) or a code problem (a write path I haven't found).

### A3. The name-review queue is entirely dead — this is the real matching gap

Not a matching-*algorithm* problem — `dds_resolve_name()`'s 6-tier cascade
(alias → exact → suffix-stripped → surname+first → skeleton → fuzzy) is
reasonably sophisticated. The problem is **what happens after a tier
misses**: `dds_resolve_review`, `dds_ignore_review`, `dds_reopen_review`,
`dds_confirm_alias`, `dds_remove_alias`, and the entire Minestat-side
equivalents (`dds_minestat_resolve_review` etc.) are all real, working,
`authenticated`-granted RPCs with **zero UI to call any of them**.
`import_name_review` / `minestat_name_review` are written to but never
read by `index.html` (confirmed: zero matches for either table name, or
for `unresolved_count`, anywhere in the file).

**Net effect: when a name fails to resolve, no one can ever find out or
fix it inside the app.** The only recovery today is re-uploading a
corrected file and hoping a higher tier now matches.

### A4. Severity is a display-only value, computed twice, never persisted

- `severityBadge()` (`index.html:2998-3010`) is the single, correctly
  shared client-side classifier — confirmed consistent across Overview,
  Analytics, Alert Logs, Data Management. It classifies by **regex match
  on event_code text** (sleep/drowsy/inattentive/posture), not by
  `event_count` — this is a different axis than what you asked for.
- A **second, independent copy** of similar logic exists in SQL
  (`dds_driver_alert_instances()`, `0035_alert_case_instances.sql:86-90`)
  — same rules, different language, no shared source of truth. Real drift
  risk if either is edited alone.
- `alert_cases` has **no severity column at all**. Severity is never
  persisted — nothing today distinguishes "this case exists because the
  event was critical" from any other logged action.

### A5. No true consecutive-day streak exists anywhere

`computeRisk()` (`index.html:7482-7501`) and its SQL mirror
(`dds_entity_status_reopen()`, `0048_weekly_risk_real_week_bound.sql:150-212`)
both count **how many days-of-week labels** (not calendar dates) had a
qualifying event within a trailing 7-day window — "2+ days, need not be
consecutive," by the code's own comment. Calendar date is discarded before
it reaches the client (`dds_driver_asset_weekly()` returns
`{Mon: [...], Tue: [...]}`, not per-date data) — so a true streak counter
needs new data plumbing, not just new logic on top of what exists.

### A6. Other confirmed bugs/stale content (smaller, independently fixable)

- **Data Management's DDS table shows the wrong driver-name field.**
  `dds_alert_logs()` returns both a correctly-precedenced
  `driverDisplayName` and a raw `driverName`. Alert Logs uses the correct
  one (`index.html:6825`); Data Management's DDS tab
  (`index.html:4946`) uses only the raw one, skipping the resolved name
  entirely — same bug species as the `driverLabel()` fix from earlier in
  this session, in a different widget.
- **Settings → System Management is entirely fake**, reachable by any
  signed-in user (`index.html:2662-2692`): "Records stored: 1,842" (real
  count is 98,877+), "Overall score: High · 96%", "Flagged for review: 3",
  a Sync button that fakes a spinner then hardcodes "Just now" with no
  network call, a Backup button that does nothing, and a "Delete All Data"
  button that's honestly commented in-code as `// Visual-only mock` but
  presented to the user as if it's real and destructive.
- **`dds_reset_fleet_data()` (the "fresh start" RPC) is stale** — it
  predates `entity_status`, `entity_action_log`, `minestat_shifts`, and
  `emp_no_attribution_conflicts` and would leave all four populated with
  orphaned data after a "reset." Also never called from the UI.
- 20 other RPCs confirmed orphaned (full list in the audit agent's report;
  most consequential ones are the review-queue API in A3 above).

---

## Part B — Proposed plan (sequenced, nothing built yet)

### P0 — Fix confirmed bugs, low risk, no design decisions needed — ALL DONE
1. ✅ Fixed Data Management's DDS table to use `driverDisplayName`
   (`index.html:4946-4953`). Verified: clean browser load, no console errors.
2. ✅ Fixed `dds_reset_fleet_data()` to cover all 4 missing tables
   (`supabase/migrations/0053_reset_fleet_data_full_coverage.sql`, not yet
   applied to the live DB — see "Not started" below, still gated on your
   go-ahead to actually run it).
3. ✅ Wired `dds_backfill_emp_no_from_minestat()` into both the Minestat and
   DDS upload success paths (`index.html`, new `runBackfillEmpNoFromMinestat()`
   helper, loops up to 25×2000 rows, best-effort/non-fatal). Not yet
   verifiable against live data pending 0053 (and this) migration application.
4. ✅ **Root cause confirmed independently**, not just by the audit agent:
   read the real `assets/Emp_Masterlist.xlsx` file's raw XML myself, then
   parsed it live in-browser with the app's own SheetJS/XLSX library —
   confirmed headers are literally "ID Number" / "Employee Name", and the
   original alias list matched neither. Widened the alias list
   (`index.html:5650-5657`) and **re-verified against the real 3,186-row
   file in-browser**: 0 of 3,186 rows parsed before the fix, 3,186 of 3,186
   parse now. You described the real file as containing "Emp_No, Name" —
   worth double-checking this is the same file you meant, since what's
   checked into the repo says otherwise; the fix is safe either way since
   it only adds aliases, never removes any.

### P1 — Build the name-resolution feedback loop (closes A3)
A real "Needs Review" screen (or a panel on the Masterlist tab) surfacing
`import_name_review`/`minestat_name_review` rows, letting a user confirm/
reject/reassign — wiring the 5+ already-built, already-correct RPCs that
have no UI today. This is the actual fix for "improve matching," since the
algorithm already exists; only the human-in-the-loop step is missing.

### P2 — Severity + case model (your new requirement)
- Add a `severity` value derived from `event_count` (≤5 low, ≤15 moderate,
  >15 critical) — computed alongside the existing `severityBadge()`
  event-code-based tier, not replacing it (they answer different
  questions: "what kind of alert" vs. "how many"). Needs a decision: is
  this a new column on `events` (computed at ingest, like `shift`/
  `actionable` already are) or a view/RPC-computed value?
- Persist a real severity-to-case link on `alert_cases` (or a new table)
  so "why was this case opened" is answerable directly, per your
  management-reporting requirement.

### P3 — Consecutive-day streak + required action at day 5
Needs `dds_driver_asset_weekly()` to return real per-date data (not
day-of-week labels), then a genuine streak calculation client- and
server-side (gaps-and-islands SQL pattern), replacing/extending the
current "2-of-7-days" model. This is the largest single piece — touches
the RPC, the trigger, and the client risk model together (same "fix both
sides" lesson from the earlier "this week" bug in this same session).

### P4 — Settings → System Management: wire or remove
Given it's 100% fake and includes a destructive-looking button that does
nothing, recommend removing the fake stats/Sync/Backup and either building
real ones or dropping the card until there's real infrastructure behind it.

### Not started — DB reset execution
Per your instruction, this stays plan-only. Scope confirmed:
**wipes**: events, alert_cases, imports, import_name_review, contributing_
factors, driver_asset_actions, driver_asset_severity, driver_master,
drivers, driver_aliases, driver_alias_log, minestat_shifts,
minestat_name_review, entity_status, entity_action_log,
emp_no_attribution_conflicts.
**preserves**: auth.users, profiles, user_settings, username_lookup_attempts.
Will not run until you separately say so, and not until P0.2 (fixing the
reset function itself) is done — running the current version would already
be an incomplete reset.

---

## What I need from you to proceed past P0

1. Confirm the real masterlist file's actual column headers (A2/P0.4) —
   I can't guess what your HR export looks like.
2. Confirm the P0 fixes are the right first slice, or reorder.
3. For P2/P3: confirm the design decisions flagged above (new column vs.
   computed value; what exactly "required action" should do when a streak
   hits 5 — auto-open a case? just flip status like the current model?).
