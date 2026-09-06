# MIGRATION_MAP.md

**Phase:** 0 — Inventory and Reconciliation
**Status:** Complete. This supersedes an earlier `MIGRATION_MAP (1).md` (kept
as a reference artifact in `../New update/`, not in this repo) that was
written against an **incomplete copy** of this codebase missing
`supabase/migrations/`, `src/`, `test/`, and `docs/` entirely — every "not
determined," "needs the missing files," "live-schema-only" claim in that
document is corrected below now that the real files are available.
**Sources inspected:** all 32 files in `supabase/migrations/` (0001–0032, read
in full), `src/dds-state.js`, `src/dds-charts.js`, `src/dds-controls.js`,
`src/dds-a11y.js`, `src/dds-tokens.css`, `docs/DDS_API_CONTRACT.md`,
`docs/DATA_MIGRATION_STATUS.md`, `docs/OVERNIGHT_AUDIT_SUMMARY.md`,
`docs/DDS_SCALING_PLAN.md`, `README.md`, `index.html` (Application A, ~1.06MB,
live in production against Supabase project `rispydfovrnvnwvfwrnw`), and
`../New update/dds_overview_1_.html` (Application B, the mock, 3,422 lines,
confirmed byte-identical in scope to what the earlier map catalogued — its UI
Inventory, §4 below, is carried forward unchanged since nothing there needed
re-verification).
**Also inspected:** `../New update/MASTER PROMPT — FUNCTIONAL MIGRATION +
DATA RECONCILIATION + PHASED IMPLEMENTATION.md` (governs this whole project)
and `../New update/MIGRATION_MAP (1).md` (the superseded prior pass).

**Corrected direction note:** commits `5a720e4` and `745e9b6` (both titled
around "redesign/rebuild Overview page... to match the reference") edited
`index.html`'s real Overview UI to visually resemble the mock. This is the
exact mistake the master prompt names as the most common failure mode —
*"make the old application look like the mock"* — and is now understood to be
wrong direction, confirmed by direct instruction 2026-08-31. Going forward:
**Application B's markup/CSS is the UI destination as-is; `index.html`'s UI is
not to be further reshaped toward it.** The correct motion is moving
`index.html`'s real Supabase-backed logic *into* the mock's page structure,
not moving the mock's look *into* `index.html`. See `MIGRATION_STATUS.md` for
how this affects those two commits going forward (they are not reverted —
see Known Issues — but no further UI-resemblance work continues on
`index.html`).

---

## 1. Existing Architecture (Application A)

Single-file deploy: `index.html` (~1.06MB) is the entire app — HTML, CSS, and
one large inlined `<script>` block, preceded by a literal copy of the same
core logic used to build a Web Worker. The live copies used by the app are
the later ones in the file; `annotate()`/`derive()` each appear twice for
this reason.

Two parallel data paths feed one shared shape:
- **LOCAL** — drop a CSV/XLSX, parsed and computed entirely client-side via
  `annotate()` → `derive()`. Works signed out, offline.
- **SERVER** — signed in, metrics come from Postgres via `dds_metrics()`
  (RPC), called through `Cloud.metrics()`/`App.loadFromServer()`.

Both paths are contracted to produce the same `derived` object shape,
verified by `test/parity.sh` (full DB-backed parity test, needs `psql` +
`python3`, does not run on a stock Windows machine per the README) and
`test/compare-derived.mjs` (Node-only, diffs against a manually-supplied SQL
result — this one runs anywhere Node runs).

Auth: Supabase Auth via standalone `login.html` (redirects to `index.html` on
success) and `reset-password.html` (recovery-token flow). All three files use
only the Supabase **publishable** key — confirmed via grep, zero
`service_role`/`.env` hits anywhere in the repo or git history.

**This is a live production app**, not a prototype: real Supabase project
`rispydfovrnvnwvfwrnw`, real imported data, two documented overnight
audit/bugfix sessions already in `docs/OVERNIGHT_AUDIT_SUMMARY.md` (accessibility
contrast fixes, palette re-validation, DoS-sized-upload caps, error-state
visibility bugs, RLS/grant hardening — all already applied).

Compute worker: a Web Worker offloads `derive()`/`compare()` off the main
thread for large local imports — already-built infrastructure relevant to
Phase 1's performance requirements (see `docs/DDS_SCALING_PLAN.md`).

---

## 2. Mock Architecture (Application B)

One file, `dds_overview_1_.html` (lives in `../New update/`, sibling to this
repo, not tracked in git here), containing all 7 pages as sibling
`<div id="page-*" class="page">` elements toggled by a `data-page` sidebar.

- **Monitoring:** Overview, Analytics, Alert Logs, Driver & Asset Monitoring, Summary
- **Management:** Data Management, Settings

Two patterns coexist:
- **Static-literal pages** (Overview, Analytics, Alert Logs, most of Data
  Management): numbers/rows typed directly into HTML as text. No JS touches
  them.
- **Dynamically-rendered pages** (Driver & Asset Monitoring, and the parts of
  Summary reading from it): genuinely populated by JS at runtime, but from a
  **self-contained mock business-logic implementation reading `localStorage`**
  (key `da_monitoring_state_v1`), not a stub waiting for real data.

No login page exists in the mock file at all — opens straight to
`#page-overview` as already authenticated. Real structural gap against
Application A's separate `login.html`/`reset-password.html` — resolved as
Decision 5 below (reuse A's real pages, restyle only).

No backend connection anywhere in the mock file. `localStorage` is its only
persistence.

---

## 3. Database Inventory — CORRECTED from full migration read

*(Sourced from a dedicated full read of all 32 migration files this session
— see `MIGRATION_STATUS.md` for the research agent's full citation-backed
report if deeper detail is ever needed than what's summarized below.)*

### `public.events` — the alert/event ledger

Defined `0001_init.sql:94-129`, extended `0019_events_emp_no.sql:42`.

| Column | Type | Notes |
|---|---|---|
| `id` | `bigint identity` | PK |
| `import_id` | `uuid` | FK → `imports(id) on delete cascade` |
| `update_time` / `start_time` | `timestamp not null` | |
| `end_time` | `timestamp` | nullable |
| `asset_id` | `text not null` | trimmed at ingest as of 0032 |
| `event_code` | `text not null` | |
| `event_count` | `integer not null default 0 check (>= 0)` | this is what's *summed* for alert-volume KPIs |
| `operator` | `text` | nullable, raw imported text |
| `shift` | generated, `dds_shift(start_time)` | stored |
| `shift_date` | generated, `dds_shift_date(start_time)` | stored |
| `actionable` | generated, `dds_actionable(start_time, update_time)` | stored |
| `sync_seconds` | generated | null if negative (clock skew discarded) |
| `emp_no` | `text` | nullable, no FK (deliberate — see §7) |

**Unique/dedup key (answers the old map's central open question):**
```sql
create unique index uq_events_natural on public.events (asset_id, start_time, event_code);
```
This is a real, enforced constraint. `dds_ingest()` has used
`on conflict (asset_id, start_time, event_code) do nothing` in **every**
version since 0001 through the current 0032 — confirmed unchanged across 4
redefinitions. **A retried/resent import chunk cannot inflate counts**: rows
already present insert 0 new rows, and `imports.row_count` only grows by
genuinely-new rows.

### `public.alert_cases` — one row per reviewed event

**Correction: this table has a real migration file.** The old map's claim of
"live-schema-only, no migration file" was wrong — it's fully defined in
`0005_alert_cases.sql:56-94`, extended by `0026_alert_cases_emp_no.sql:42`.

| Column | Notes |
|---|---|
| `event_id` | FK → `events(id)`, **unique** (one case per event, overwrite-on-edit) |
| `driver_name` | free text, deliberately **not** FK'd to any driver table (roster gets wiped/replaced on upload; an FK would block or cascade-delete destructively) |
| `action_type` + `action_is_other` | free text + boolean flag, **no CHECK constraint, no enum** |
| `status_value` + `status_is_other` | free text + boolean flag, **no CHECK constraint** |
| `emp_no` | added 0026, no FK |

**Action/status vocabulary lives entirely client-side**, not SQL-enforced:
- Action options (index.html:3197-3198 + 0007's comment): `Replace driver`,
  `Disciplinary action`, `Noted`, plus free text via `action_is_other=true`.
- Status options (index.html:18887): the select literally offers only
  `['', 'Ongoing', 'Completed']` — **not** a 3-value `Ongoing/Completed/Other`
  as the old map guessed; `Other` is `status_is_other=true` + free text, not
  a stored literal.
- **`'Completed'` is the one load-bearing exact string**: `0005:70-71`'s own
  comment states changing it changes what `dds_alert_summary()` means, and
  `0012_alert_summary_total.sql:80` confirms:
  `coalesce(bool_and(status_value = 'Completed'), false) as closed`.

Client writes `alert_cases` directly via PostgREST — no RPC — RLS is the only
write boundary (see §6).

### `dds_ingest()` — dedup confirmed safe under retry

4 versions (0001 → 0015 → 0019 → 0032), all using the same
`on conflict (asset_id, start_time, event_code) do nothing`. 0015 fixed a
real bug (chunked uploads were marked `status='complete'` after chunk 1, not
the last chunk) but never touched the dedup mechanism itself. 0032 only
trims `ASSET_ID` before the conflict check, to catch whitespace-based
mismatches.

### Driver/asset severity — real thresholds, and a real client/SQL split

- `driver_asset_actions` (0007) — **append-only** history, `entity_type
  check (in ('driver','asset'))`, `entity_id`, `action_type` free text, no
  update/delete policy at all (immutable by RLS design).
- `driver_asset_severity` (0020) — **current-state**, one row per
  `(entity_type, entity_id)`, no date-range scoping (`primary key
  (entity_type, entity_id)`). Client writes directly via `.upsert()`.
- **Confirmed exact thresholds, index.html vs. SQL:**
  `HIGH_DAY_THRESHOLD = 10` (a day is "high" if that day's summed
  `event_count` > 10) is identical in both — `v_high_day_threshold constant
  integer := 10` appears in every SQL version from 0006 onward, matching
  index.html:5400 exactly.
- **The 4-band severity system (`critical`/`warning`/`caution`/`normal` at
  `highDayRatio` ≥ 75/50/25/0) is client-only** (index.html:5401-5406,
  `applySeverity()`). Pre-0020 SQL only ever computed a binary `flagged`
  (`highDays/activeDays > 50%`). As of 0020, SQL returns only the raw numbers
  (`highDayRatio`, `activeDays`, `highDays`) and the client computes the
  4-band severity — this was a **deliberate** collapse of two
  independently-computed severities into one, specifically to prevent drift
  (0020's own stated purpose). There is no SQL-side 4-band equivalent to
  reconcile against; it was intentionally never duplicated.
- `dds_entity_day_breakdown()` (0017) independently re-derives the binary
  `>50%` rule (not the 4-band one) for its own drill-down modal, with the
  threshold passed in explicitly (`p_threshold default 10`) so it can't
  silently diverge.

### Latest authoritative RPCs (later migrations supersede earlier ones — these are current)

- **`dds_metrics()`** — latest is **0028**. Confirms Alert Count finding #1
  below: `SUM(event_count)` for all volume/"total" figures, never
  `COUNT(*)`. As of 0028, driver-facing grouping (`topOperators`,
  `operatorConsistency`, `distinctOperators`) keys on `emp_no` (with an
  `'UNSPECIFIED'` sentinel), not raw operator text — display name resolves
  via `drivers` with graceful fallback. `recentAlerts.operator` is
  deliberately **not** emp_no-resolved (still raw text) — an intentional,
  narrower exception, not an oversight.
- **`dds_alert_logs()`** — first defined in **0016** (0005 explicitly
  deferred it), latest is **0026**. Row-count based (`COUNT(*)` semantics via
  paging), driver display name resolved with precedence: human-confirmed
  case name > system-resolved name > raw operator text
  (`coalesce(nullif(c.driver_name,''), dc.full_name, d.full_name,
  nullif(e.operator,''))`).
- **`dds_alert_summary()`** — defined 0009, latest is **0012**. Group-count
  based, one row per `(shift_date, shift, asset_id, event_code)`,
  `total = SUM(event_count)` per group. `closed` uses the `bool_and(...,
  'Completed')` coalesce discussed above.
- **`dds_metrics_multi()`** (0021) — thin wrapper looping `dds_metrics()`;
  automatically inherits whatever the latest `dds_metrics()` does, zero
  separate logic.

### Driver identity — two real, deliberately-coexisting tables

**Correction:** the old map cited `driver_master` from an index.html comment
and treated it as *the* masterlist. It's real, but it's the **older, still-
live** table — not the one newer identity work is built on:

1. **`public.driver_master`** (0005) — `name`, `employee_id`, wiped and
   fully replaced on every roster upload via `dds_replace_drivers()`. Still
   backs the Alert Case driver-name picker's fuzzy autocomplete.
2. **`public.drivers`** (0018) — the real masterlist. `emp_no text primary
   key` (natural key — badge numbers can have leading zeros/letter prefixes
   an integer PK would destroy), `full_name`, `status
   check (in ('active','inactive'))`, **upserted, never wiped** via
   `dds_upsert_drivers()`.

0018's own header explains the split is deliberate (promoting
`driver_master` in place was rejected — `dds_replace_drivers()`'s full-table
delete would either block on or cascade-destroy any FK hung off it) and
explicitly slates `driver_master` for retirement "in a later phase once the
picker reads `drivers` instead" — **that retirement has not happened as of
migration 0032.** Both tables are still live.

`driver_aliases` (0018) is real and correctly named — `emp_no`-keyed, backed
by an append-only `driver_alias_log` audit trail. Name resolution
(`dds_resolve_name()`) is a 6-tier cascade (alias → exact → suffix-stripped →
surname+first-given-name → consonant-skeleton → bounded Levenshtein),
hardened twice more since 0018 (0029 added full diacritic folding and fixed
a real `\s` vs. literal-`s` regex bug that was silently producing
double-spaced normalized keys — symmetric, so it never broke matching).

### MineStat — a third data source, entirely unknown to the old map

`0024_minestat.sql` (+ `0027`, touched again by `0028`/`0032`) adds daily
per-unit/per-shift operator + utilization-hours records
(`minestat_shifts`, PK `(asset_id, shift_date, shift)`, **upsert** semantics
— the opposite of `dds_ingest()`'s dedup-by-ignore, since a re-uploaded
MineStat file is treated as a correction, not a duplicate). Used to attribute
a driver identity to DDS alerts when the DDS file itself carries no operator
(the common real-world case). `dds_backfill_emp_no_from_minestat()` fills
`events.emp_no` **only where currently null**; MineStat is never joined live
inside `dds_metrics()` — it's a batch backfill, "one place a calculation
happens." `emp_no_attribution_conflicts` (0032) records but does not act on
disagreements between text-resolved and MineStat-joined identity.

### RLS — full inventory (was partial in the old map; see full table in the research report)

Every table with data has RLS enabled with an explicit policy set;
`auth.uid() is not null` (single-tenant: any signed-in user reads all data,
documented explicitly in 0001 as intentional) is the real boundary
everywhere, not per-row ownership. Two tables are notable:
- `username_lookup_attempts` — RLS enabled with **zero** policies (deliberate
  deny-all; only the `SECURITY DEFINER` `username_to_email()` touches it,
  closing an email-enumeration hole).
- `driver_asset_actions` — insert-only, no update/delete policy at all
  (append-only by RLS design, matching its "never overwrite history"
  business requirement).

**One real bootstrapping bug found and already fixed:** `0019`'s
`dds_refresh_unresolved_counts()` (and 3 sibling functions, plus the
`import_name_review` RLS/policy block) used malformed dollar-quoting (`as $`
instead of `as $$`) — a hard syntax error that, on a from-scratch replay,
prevents everything after that point in the file from being created at all.
`0023_review_actions_fix.sql` re-issues all of it correctly. **A database
built from these files in sequence only gets working `import_name_review`
RLS starting at 0023, despite the SQL text existing in 0019's file.**

**Anon-grant hardening (0030):** found via live security-advisor audit (not
re-derivable from migration text alone) that 8 functions still held live
`anon` EXECUTE grants their originating migrations intended to revoke —
`revoke ... from public` does not remove a grant held directly by `anon`.
0030 fixes this. One follow-up (`rls_auto_enable()`, found anon-executable,
no definition in any migration file — a residual live-only object) remains
explicitly unresolved.

---

## 4. UI Inventory (Application B, by page)

*(Unchanged from the prior pass — the mock file's line count and content
were re-confirmed this session to match exactly; no re-cataloguing needed.)*

| Page | Static-literal | Dynamically rendered | Notes |
|---|---|---|---|
| Overview | KPI values, sparklines, hero text | — | 5 KPI cards, 2-column grid |
| Analytics | All KPIs, all 6 charts, all rankings | — | severity donut and sync-interval chart are static SVG with literal baked-in numbers |
| Alert Logs | Summary tiles, 8-row table, pagination footer text | — | `Showing 8 of 1,842` / `Rows 1–8 of 1,842` — hardcoded, the master prompt's own named example |
| Data Management | DDS/Minestat/Masterlist/Factors tabs, upload history, records table | — | same `1,842` figure recurs, internally consistent within the mock only |
| Driver & Asset Monitoring | — | Summary counts, driver table, asset table | Fully dynamic against a self-contained mock risk model + `localStorage` |
| Summary | 7-day KPIs, trend chart, insight list | Risk table, actions list — explicitly "from live DA state" | Correctly wired to Driver & Asset Monitoring's state within the mock — proves cross-page propagation already works, against fake data |
| Settings | Personal Info, Personalization | Access Management user table (hardcoded array, not localStorage) | 4 tabs |

---

## 5. Field & Feature Reconciliation

### CASE 1 — Exists in both, same concept
- Top Assets/Drivers ranking ↔ `dds_metrics()`'s `topAssets`/`topOperators`.
- "Alert Count by Sync Interval" ↔ `syncBuckets` (labels/actionable/nonActionable arrays) — direct match, confirmed present in the current `dds_metrics()`.
- Settings → Personal Info / Sound ↔ `public.user_settings` via `Cloud.saveSettings()` — already real.
- Settings → Access Management (approve/reject) ↔ `public.profiles` + `profiles_update_admin` RLS — concept match, vocabulary differs (Case 4).

### CASE 2 — Exists only in Application A
- `meta.reconciles`/`meta.unclassifiedRows`/`meta.unclassifiedUnits` —
  **KEEP and surface.** This is exactly the "if counts intentionally differ,
  explain why" mechanism the master prompt's Alert Count Cross-Check
  requires, and it already exists in `dds_metrics()`'s `meta` object.
  Application B currently has nowhere to show it — needs a small UI home,
  likely near the Overview/Analytics KPI row or Alert Logs' summary tiles.
- `dds_alert_summary()` (group-grain: one row per shift_date × shift × asset
  × event_code) — no mock page represents this grain. Real, tested, keep in
  backend; revisit only if a future page needs it.
- `import_name_review` / `minestat_name_review` queues — real operational
  feature, no mock page surfaces either. **KEEP**, flag for a Data
  Management UI home (Phase 3) — not currently represented in the mock.
- Web Worker offload — not a UI concern, keep as-is (Performance/Phase 1).
- MineStat entirely — real, substantial, working backend capability
  (`minestat_shifts`, ingest/review RPCs, backfill) with **zero mock UI
  representation**. The mock's Data Management page has a "Minestat Data"
  tab already (static-literal) — this is the clearest Case 2 item requiring
  real wiring in Phase 3.

### CASE 3 — Exists only in Application B
- Alert Logs pagination as shown in the mock (`Rows 1–8 of 1,842`) —
  **partially real**: `dds_alert_logs()` already provides real server-side
  pagination (`p_limit`/`p_offset`, `{total, rows}`), through a different,
  richer real implementation (`#alTable`, bulk-select, server-side sort,
  75-row pages, case-edit modal) than the mock's simpler markup. Reconciling
  the mock's simpler UI against the richer real one is real design work for
  Phase 3, not "invent from nothing."
- Driver & Asset Monitoring's risk formula + `ACTION_TYPES` vocabulary —
  **RESOLVED by Decision 1** (§6 below): ship the mock's model, build it for
  real, do not compete with `applySeverity()`/`driver_asset_severity`/
  `driver_asset_actions`.
- Settings → Access Management's `Reviewer`/`Supervisor`/`disabled` values —
  **RESOLVED by Decision 4**: dropped, adopt Application A's real roles.
- Analytics' severity donut / "Critical severity" tile — **RESOLVED by
  Decision 3**: dropped/replaced, matches Application A's own prior,
  already-documented conclusion that this can't be honestly shown at the
  row-level grain available (see Alert Count finding #10).

### CASE 4 — Same concept, different structure
- **Severity vocabulary** — **RESOLVED by Decision 2** (§6): real 5-value
  `severityForCode()` scale is authoritative; mock's 3-label UI is a display
  layer over it, exact mapping given below.
- **Driver/Asset risk vocabulary** — **RESOLVED by Decision 1**: the mock's
  formula ships as the one authoritative implementation; `applySeverity()`'s
  4-band system and `driver_asset_severity`/`driver_asset_actions` are not
  used for this feature (no second competing implementation).
- **Operator/Driver identity** — already reconciled by coincidence: real
  precedence rule (case name > resolved name > raw operator text) merges
  into one `Driver` column, matching the mock's single-column tables. Worth
  confirming intent match in Phase 3, not re-architecting.
- **User roles** — **RESOLVED by Decision 4**: adopt `admin`/`oa`/`b2b` +
  `pending`/`approved`/`rejected`, drop the mock's 4-role/2-status set.
- **Corrective action taxonomy** — **RESOLVED by Decision 1**: the mock's
  8-value `ACTION_TYPES`, logged per driver/asset, ships as-is; Application
  A's `alert_cases`-scoped `action_type`/`status_value` fields (per-alert,
  not per-entity) remain in use for the Alert Case modal specifically (a
  different, still-needed feature — Alert Logs' case review — not replaced
  by Decision 1, which only concerns Driver & Asset Monitoring).

---

## 6. OPEN DECISIONS — carried forward as settled (from the prior Phase 0 pass, 2026-08-31)

All 5 were resolved by direct instruction before this session; restated here
verbatim as fixed constraints since they still hold and this document
supersedes the one that recorded them originally.

**Decision 1 — Driver & Asset Monitoring risk formula and action vocabulary.**
Keep the mock's model, make it real. `computeRisk()`'s formula
(`daysOver10 >= 2 OR total > 20` → High; any alerts → Medium; zero → Low) and
`ACTION_TYPES` (`Counseled`/`Suspended`/`Reassigned`/`Cleared`/`Spare 3
Days`/`Monitor`/`Continue`/`Other`) ship as the real, persisted model.
Application A's `applySeverity()`/`driver_asset_severity`/
`driver_asset_actions` are **not** used for this feature — no second,
competing implementation. New tables/RPCs will be needed in Phase 1 to
persist this (the existing `driver_asset_*` tables are reserved for a
different, still-real use if one exists, or become unused by this feature
specifically — Phase 1 should confirm nothing else in Application A depends
on them before deciding whether to retire them entirely).

**Decision 2 — Alert severity vocabulary mapping.** Application A's real
5-value `severityForCode()` scale is authoritative; the mock's 3-label UI is
a display/grouping layer over it:

| Real (`severityForCode()`) | Mock UI label |
|---|---|
| `critical` | `critical` |
| `elevated` | `high` |
| `caution` | `moderate` |
| `notice` | `moderate` (folded in) |
| `unknown` | excluded from severity tier counts; shown separately |

**Decision 3 — "Critical severity" tile / Analytics severity donut.**
Dropped/replaced. No new fleet-wide per-alert severity aggregate is built —
matches Application A's own prior conclusion (Alert Count finding #10) that
this can't be honestly shown at the row-level grain available. Replace with
what's actually backed (e.g. `dds_alert_summary()`'s group-level
closed/pending counts).

**Decision 4 — User roles & Access Management.** Adopt Application A's real
`admin`/`oa`/`b2b` roles with `pending`/`approved`/`rejected` status and the
existing admin approve/reject workflow (`profiles`, `profiles_update_admin`).
Mock's `Reviewer`/`Supervisor`/`active`/`disabled` are dropped. Settings →
Access Management gains a pending-approval view (currently absent from the
mock).

**Decision 5 — Login page.** Reuse Application A's real `login.html`/
`reset-password.html` as-is, functionally unchanged. Restyle visually to
match Application B's visual language; do not rearchitect into an in-page
flow. Both must stay same-origin with the main app per the README's own
warning.

---

## 7. Alert Count Discrepancy Analysis — CONFIRMED, now with exact SQL citations

*(The master prompt's mandatory investigation. Findings from the prior pass
are now directly confirmed against the actual, current SQL — not inferred
from comments.)*

**1. What exactly constitutes an alert?** Confirmed: depends which RPC is
asked, by design. `dds_metrics()` (0028): `SUM(event_count)`. `dds_alert_logs()`
(0026): row count (one row per `events` record, left-joined `alert_cases`).
`dds_alert_summary()` (0012): group count, distinct `(shift_date, shift,
asset_id, event_code)` tuples. Three legitimately different units, confirmed
in the currently-live versions of all three functions.

**2. Source table.** `public.events`, DDL fully confirmed (§3 above) — no
longer an open question.

**3-4. What does the system count / does Alert Logs show all records?**
Confirmed unchanged from the prior pass's conclusion: three different
things by page, and the real `dds_alert_logs()` (0026) is fully paginated
server-side with a real `total` — the mock's hardcoded `1,842`/`8 of 1,842`
has no query behind it at all.

**5. Are duplicate records possible?** **Now fully answered** (was
undetermined in the prior pass): no, structurally prevented.
`uq_events_natural (asset_id, start_time, event_code)` is a real unique
index, and every version of `dds_ingest()` from 0001 through 0032 has used
`on conflict (...) do nothing` against it. A retry cannot duplicate data.

**6-7. Row vs. `event_count` semantics.** Confirmed: one `events` row = one
record for row-count purposes; `event_count` independently sums to more than
the row count for volume-KPI purposes. Both real, simultaneous, by design.

**8. Rejected/duplicate rows.** Unparseable-timestamp rows are excluded
before `derive()`/`dds_metrics()` ever aggregates them. Rows with a
parseable timestamp but no derivable `shift` are counted in `totalAlerts`
but excluded from trend/shift/hourly breakdowns — the `meta.reconciles`
mechanism exists specifically to make this visible (see Case 2, §5).

**9. Does filtering change the count?** Yes, by design, confirmed in both
`applyFilters()` (JS) and every `dds_metrics()` version's `where` clause.

**10. Dashboard count vs. Alert Logs count — the central finding, unchanged
and now fully SQL-confirmed.** They're different units by design
(`SUM(event_count)` vs. row count) and can legitimately show different
numbers for the same data/range. Not a bug — needs to be an explained,
visible fact in the UI (via `meta.reconciles`, Case 2). The mock's "Critical
severity: 126" tile and Analytics severity donut assume a fleet-wide
per-alert severity aggregate Application A's own real Alert Logs
implementation has already, deliberately declined to build at this grain —
resolved as Decision 3 (drop/replace, don't build).

### Alert Count Documentation (filled, now fully sourced from SQL — no remaining gaps)

```
ALERT DEFINITION:
  Ambiguous by page, by design. dds_metrics() (0028): SUM(event_count).
  dds_alert_logs() (0026): COUNT of events⋈alert_cases rows.
  dds_alert_summary() (0012): COUNT of distinct (shift_date, shift,
  asset_id, event_code) groups.

COUNTING METHOD:
  SUM for KPIs; row-count for logs; group-count for summary. All three
  confirmed in the current, live SQL definitions (not inferred).

SOURCE TABLE:
  public.events (full DDL confirmed, supabase/migrations/0001_init.sql:94-129
  + 0019_events_emp_no.sql:42), left-joined to public.alert_cases
  (full DDL confirmed, 0005_alert_cases.sql:56-94) for case/status data.

UNIQUE IDENTITY:
  (asset_id, start_time, event_code) — enforced unique index
  uq_events_natural, 0001_init.sql:128-129.

DUPLICATE RULE:
  dds_ingest()'s on conflict (asset_id, start_time, event_code) do nothing,
  unchanged across all 4 redefinitions (0001, 0015, 0019, 0032). Confirmed:
  retries cannot inflate counts.

FILTER SCOPE:
  shift, actionableOnly, date range (from/to, on shift_date), assetIds,
  eventCodes. Rows with no derivable shift_date bypass date-range filtering
  specifically (deliberate, documented in applyFilters()'s own comment)
  while remaining subject to the other filters.
```

### Alert Count Test — still not run, now unblocked

Not run this session (needs either `psql` + real `python3`, absent on this
Windows machine per the README, or a Supabase MCP/live-query connection,
also not available in this session) — but **no longer blocked on missing
files**: the schema, the fixture (`test/fixture.json`, 39 edge-case rows),
and the comparison tooling (`test/compare-derived.mjs`, Node-only, runs
anywhere) all exist in this repo right now. Recommend this as literally the
first concrete task of Phase 1: run `node test/compare-derived.mjs
--emit-js` (confirmed by the overnight audit to already run clean, exit 0)
against a real SQL-side result pulled via Supabase MCP or dashboard SQL
editor, using the master prompt's own 10-valid/2-duplicate/1-rejected
template extended to also exercise `dds_alert_logs()` and
`dds_alert_summary()`, not just `dds_metrics()`.

---

## 8. Existing Business Logic Inventory

- **Shift classification & shift date**: `classifyShift()`/`shiftWindow()` in
  JS, `dds_shift()`/`dds_shift_date()` as generated-column functions in SQL.
  Per `docs/DDS_API_CONTRACT.md`: DAY 05:21–17:20 UTC, NIGHT 17:21–05:20
  (+1 day), with a genuinely-unresolved boundary gap (17:20:00–17:20:59 falls
  in neither window, forced NON_ACTIONABLE) and a night-tail rule
  (`START_TIME` before 05:21 attributes to the previous day's night shift).
  **Two open decisions the API contract doc itself flags as unresolved** —
  carry into Phase 1, do not silently pick one.
- **Actionable determination**: `updateTime` within its own shift's window.
- **Sync lag**: seconds between `endTime` and `updateTime`, null if negative.
- **Per-event severity**: `severityForCode()`, 5-value (`critical`/
  `elevated`/`caution`/`notice`/`unknown`), text-matched against
  `EVENT_CODE`. Now has an authoritative mapping to the mock's 3-value UI
  (Decision 2).
- **Per-driver/asset consistency severity**: `applySeverity()`, 4-band,
  client-only since 0020 (see §3) — **not used** for Driver & Asset
  Monitoring per Decision 1; still real and may back other features (e.g.
  the drill-down `dds_entity_day_breakdown()` uses its own binary
  `>50%` variant independently).
- **Period comparison baseline**: `resolvePeriods()`'s 30→7→1 day fallback
  cascade, both windows shrunk to equal length.
- **Top-N tie-breaking**: secondary sort on id/asset_id, mirrored between JS
  (`localeCompare`) and SQL (`order by total desc, asset_id`), deliberately
  kept identical so pagination boundaries agree.

---

## 9. Security Inventory — VERIFIED LIVE, Phase 2 complete (2026-08-31)

- Auth: Supabase Auth, real, separate `login.html`/`reset-password.html` —
  Decision 5 (reuse as-is, restyle only).
- Keys: publishable key only, confirmed via grep across all three HTML
  files and full git history.
- RLS: **full policy inventory available** (§3 above / research report) —
  every table has explicit policies.
- **Two gaps already fixed before Phase 2** (carried forward from
  `docs/OVERNIGHT_AUDIT_SUMMARY.md` and the migration history, not new this
  session): the `0019`→`0023` `import_name_review` bootstrapping bug, and
  the `0030` anon-grant leak across 8 functions.

### `rls_auto_enable()` — RESOLVED, confirmed harmless (2026-08-31)

Fully investigated with live database + real HTTP-request access (Phase 1's
browser-driven Supabase SQL editor path). It is a genuine, intentional
safety mechanism: an `event_trigger` (registered as `ensure_rls`, fires on
`ddl_command_end`) that auto-enables RLS on any new `public`-schema table —
defense-in-depth against a future migration forgetting
`ENABLE ROW LEVEL SECURITY`. Supabase's own Security Advisor linter flags it
as "Public Can Execute SECURITY DEFINER Function... via
`/rest/v1/rpc/rls_auto_enable`" — **this is technically true but not
exploitable**, confirmed with a real unauthenticated `POST` to that exact
endpoint using the project's own publishable key: Postgres returns `400
0A000: "cannot display a value of type event_trigger"` before the
function's logic can execute. PostgREST attempts the call; Postgres itself
refuses to marshal an `event_trigger` return value over the wire. No
exploit path exists. Left as-is (the `anon`/`PUBLIC` grant is cosmetic
noise against the linter, not a fix-worthy gap) — revoking it would add
zero security benefit and risks nothing, but isn't necessary.

The same investigation also checked `dds_entity_status_reopen()` (0033's
new trigger function, flagged by the same linter rule) — a plain
`TRIGGER`-returning function this time. Confirmed even more clearly
harmless: PostgREST returns `404 PGRST202` — it doesn't expose
`TRIGGER`-returning functions as callable RPCs at the schema-introspection
level at all, so the endpoint doesn't even exist for a caller to reach.

`username_to_email()` (also flagged by the same linter rule) — confirmed
**intentionally** anon-callable (required for pre-authentication login, per
0013's own design) and its rate-limiting **actively verified working**: 7
consecutive real HTTP calls against a nonexistent username all recorded in
`username_lookup_attempts` (confirmed via direct table query) while the
function's response stayed `null` throughout every one of the 7 — exactly
the "throttled and unknown-username produce an identical, silent response"
design 0013 documents, verified rather than assumed.

The remaining ~28 warnings on the Security Advisor's Warnings tab are all
the lower-severity "Signed-In Users Can Execute" tier (`authenticated`-only,
not `anon`) — e.g. `dds_backfill_emp_no`, `dds_complete_import`,
`dds_confirm_alias`, `dds_driver_alias_audit`, `dds_fail_import`,
`dds_ignore_review`. These match the intended design (signed-in users are
supposed to call these RPCs) and were not individually re-audited beyond
confirming none of them show `anon_can_exec = true` in a direct
`information_schema.role_routine_grants` query — none do.

### Public sign-ups — WAS OPEN, now CLOSED (fixed 2026-08-31)

**Confirmed and fixed a real, live gap.** The Supabase Dashboard →
Authentication → Sign In / Providers → "Allow new users to sign up" toggle
was **ON** — verified two ways: reading the toggle's checked state, and
sending a real `POST /auth/v1/signup` request (using only the project's own
publishable key, no different from what any internet visitor could send)
that the server accepted and processed rather than rejecting as closed.
This was the exact manual step flagged as outstanding since
`docs/OVERNIGHT_AUDIT_SUMMARY.md`'s original audit and never confirmed
closed until now. **Toggled off and saved in the dashboard, then
independently re-verified**: a fresh page load shows the toggle unchecked,
and a second real signup POST now returns `422 signup_disabled: "Signups
not allowed for this instance"`. The app's own defense (new accounts land
`status='pending'`, blocked from sign-in until admin approval) had already
limited the practical damage of this being open, but open self-registration
créating pending-review noise is now closed regardless.

- Admin gating: client-side `isAdmin` explicitly documented as "mirrors" the
  real RLS check, not a replacement — correct pattern, preserve as-is.
- Known asymmetry: `driver_asset_severity` writes are fire-and-forget, no
  retry, by design — moot under Decision 1 unless something else still reads
  this table.

---

## 10. Known Issues

- `src/dds-insights.js` — confirmed **orphaned**, nothing imports it
  (grepped repo-wide). Its `renderAnalyticsKpis()` defines an older,
  different 5-KPI set than what's actually live. Not deleted, flagged for
  cleanup — does not block Phase 1.
- `src/dds-charts.js`'s `trend()` is an older, simpler version than
  index.html's inlined one (missing `showPrev`, per-series scaling) — a
  real, pre-existing `src/`/`index.html` drift, not touched this session.
- Overview's real "Alert Volume Over Time" chart is a genuine dual-axis
  chart (Total Alerts / Distinct Assets on independently-scaled axes) — the
  in-code comment claiming otherwise was corrected 2026-08-28, but the chart
  itself was deliberately not restructured (real design decision, not a
  quick fix). Relevant when Phase 4 (Overview) reconciles this chart against
  the mock's trend chart.
- **Commits `5a720e4` and `745e9b6`** reshaped `index.html`'s real Overview
  UI toward a "reference" design — see the Corrected Direction Note at the
  top of this document. Not reverted (their underlying data-plumbing changes,
  e.g. carrying `_updateTime`/`_endTime` through to `recentAlerts`, may still
  be useful groundwork for Phase 4), but no further work in this direction
  continues. Phase 4 should audit exactly what in those two commits is
  salvageable logic vs. UI-only churn to discard.
- `driver_master` (0005) vs. `drivers` (0018) — both still live, retirement
  of the former never happened. Phase 1 should confirm current index.html
  usage of each before deciding whether either needs touching.
- `docs/DDS_API_CONTRACT.md` describes a **not-yet-built** REST API layer
  (`GET /api/metrics`, `POST /api/imports`) as a future migration target —
  index.html today talks to Supabase directly via RPC/PostgREST, not through
  this contract. Useful as a shape reference (its JSON response shape
  matches `derive()`/`dds_metrics()` closely) but not a description of
  current reality. Don't treat its existence as evidence the API layer
  exists.
- MineStat's `SHIFT_DATE` convention vs. DDS's is explicitly unverified —
  `dds_check_minestat_date_convention()` (0032) is a read-only diagnostic
  that exists but whose result was never recorded anywhere in the
  migrations. Run it early in Phase 3 if MineStat's shift-date fields are
  used for anything date-range-filtered.
- Sample data available for testing in `../New folder (2)/`: `DDS Data.xlsx`,
  `Employee_Masterlist.xlsx`, `Minestat_Sample.xlsx` — useful for the Alert
  Count Test and Phase 3 Data Management wiring.

---

## 11. Recommended Migration Order

1. **Phase 1 is now unblocked.** Full schema access exists locally — no
   external dependency remains. First concrete task: run the Alert Count
   Test (§7) using the existing `test/` tooling.
2. Phase 1 should also resolve the two still-open items flagged above before
   writing anything new: the 17:20 boundary-gap shift-logic decision (API
   contract doc's own flag) and confirming `driver_master`/`drivers` current
   usage.
3. Phases 2–4 (Auth, Data Management, Overview) remain comparatively
   low-risk — real implementations are close in shape to the mock, modulo
   the hardcoded-count replacements in §7 and MineStat's total absence from
   the mock's Data Management tab (§5, Case 2).
4. Phase 4 (Overview) specifically needs to reconcile against commits
   `5a720e4`/`745e9b6` per the Known Issues note above — audit before
   building, don't assume either a clean slate or a total loss.
5. Phase 5 (Driver & Asset Monitoring) and Phase 6 (Corrective Actions) are
   now **fully unblocked by Decision 1** — build the mock's model for real,
   no remaining ambiguity.
6. Phase 7 (Analytics) is unblocked by Decision 2/3 — severity mapping and
   the dropped severity-donut are both settled.
