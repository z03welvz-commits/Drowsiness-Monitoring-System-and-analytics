# Overnight audit summary — 2026-08-28

Branch: `driver-masterlist` (3 new commits, not pushed — review and push
yourself). No destructive operations were run; no live Supabase data was
touched. No Supabase MCP/API access was available in this session, so the
security review is based on careful reading of the migration files rather
than live queries — noted explicitly wherever that matters.

## Go / no-go read

**Go, with one manual step you need to do yourself before relying on
sign-in security:** open the Supabase dashboard and confirm
**Authentication → Providers → Email → public sign-ups is OFF**. This
could not be verified or fixed from code — see "Security" below for why it
matters more than it looks like it should.

Everything else checked out clean or was fixed. No syntax errors, no
exposed secrets, no found-but-unfixed data-integrity bug, no broken nav.

---

## 1. Analytics page vs. the mockup — already correct, no fix needed

Read the live `#page-analytics` section (index.html ~2588-2883) end to end
against the description: 5 KPIs (Total Alerts, Sleep Alerts, Drowsiness
Alerts, Drivers Involved, Assets Reporting) via `renderAnalyticsKpis()`
(index.html:10301) / `kpiTile()` (index.html:10247), the live factor banner
via `renderAnalyticsFactorBanner()` (index.html:10347) with copy that
matches verbatim — `"<factor> still logged as active — it may be
contributing to current alert volume."` — and the exact 3-row/6-card chart
layout (Alert Volume by Distinct Asset / Hourly Trend by Month / Alert
Count by Sync Interval / Alert Count by Driver / Contributing Factors /
Event Severity Distribution / Alert Volume by Day of Week / Alert Volume by
Top Asset). It all matches. `esc()` is used consistently on every
interpolated label. This part of the earlier mockup-correction work was
accurate — no rework needed.

One real bug *was* found nearby and fixed — see fix #1 below.

## Fixes made (3 commits)

### Fix 1 — Hardcoded gridline colors broke dark mode on 4 Analytics charts
**Commit `92fbabf`.** The Overview page's trend chart had this exact bug
before (a hardcoded `#F1F2F5` stroke stays light-gray under the dark
palette and reads as a harsh bright line) — already fixed there, with a
comment explaining it. The Analytics page's four equivalent chart shells
(Alert Volume by Distinct Asset, Hourly Trend by Month, Alert Count by Sync
Interval, Alert Volume by Day of Week) shipped with the identical
`#F1F2F5`/`#E6E8EC` hardcoded strokes and were never given the same fix —
8 occurrences total, all in index.html lines 2748-2876.
**Fix:** replaced all 8 with `var(--divider)`, matching the Overview
precedent exactly.
**Verified:** grepped for the hex values afterward — zero remain anywhere
in the file. `--divider` is defined for both light (`#F0F4FB`) and dark
(`#262931`). `node --check` on the extracted inline `<script>` still
passes (markup-only change, no JS touched). No `src/` file contains this
markup (the six `src/` modules are pure JS/CSS, not page shells), so no
`src/` sync was owed.

### Fix 2 — Settings "Saved" toast lied to signed-out users
**Commit `0d9c4cc`.** Settings > Personal Information and Notification
Sound both call `flashSaved()` on save. Traced the actual behavior: when
signed in, this is a real `Cloud.saveSettings()` write to
`public.user_settings` (RLS-scoped to `auth.uid()`) — genuinely persisted,
confirmed by reading `Cloud.saveSettings()` at index.html:12403. When
signed out (Local mode), the save is deliberately in-memory only, by an
explicit design comment already in the file ("Signed-out (Local mode)
falls back to today's in-memory-only behavior") — that in-memory fallback
is not itself a bug. But the toast showed the identical "Saved" text in
both cases, telling a signed-out user their change was durably saved when
it would vanish on refresh. That's a real correctness/honesty bug, exactly
the kind called out in the task brief.
**Fix:** `flashSaved()` now takes a `local` flag, threaded from both call
sites' existing `if (!Cloud.session)` branch (which was already
distinguishing the two cases — it just wasn't saying so in the UI).
Signed-out saves now show **"Saved to this device only"** in an amber pill
(2.6s) instead of the plain green **"Saved"** (1.8s) a real server write
gets.
**Verified:** `node --check` on the extracted script passes.
`--amber-text`/`--amber-50` tokens already existed for both light/dark
(this file's own tokens comment documents `--amber-text` as "use on
tint"). Computed WCAG contrast by hand (Node, relative-luminance formula)
since `python3` isn't usable on this machine per the README's own warning:
`--amber-text` on `--amber-50` is 4.73:1 light / 6.56:1 dark — passes the
4.5:1 AA text threshold. (Note: I initially used `--amber` instead of
`--amber-text` and caught it myself before committing — `--amber` alone is
only 3.2-3.7:1 against `--amber-50`, which is fine for the icon-only uses
already elsewhere in the file under WCAG 1.4.11's 3:1 non-text threshold,
but would have been an AA failure for actual text.) Confirmed no `src/`
file contains Settings page logic, so no sync owed.

### Fix 3 — Two stale claims in README's deploy notes
**Commit `39b89ff`.** Both were true when written, overtaken by later
commits:
- *"Import pipeline writes to browser-local state only... connecting the
  dropzone to actually upload via `dds_ingest()` is the next real piece of
  work, not yet done."* **False now.** `addRecord()` (index.html:~13300s)
  writes to local/IndexedDB first, then — if a Cloud session exists — calls
  `syncToCloud()`, which RPCs `dds_ingest()` in chunks with retry/backoff
  via `Cloud.ingest()`. MineStat upload does the same via
  `Cloud.ingestMinestat()`/`dds_minestat_ingest()`. Verified by reading the
  actual call chain, not by assuming the SQL functions existing meant they
  were wired up.
- *"Settings and User Management pages are still prototypes — the Save
  buttons show a success toast without persisting anything."* **Also
  false.** Both persist for real when signed in (see Fix 2's investigation).
  The genuine gap this claim was gesturing at — the toast not
  distinguishing real saves from discarded ones — was real but narrower
  (signed-out Local mode only) and is fixed in commit `0d9c4cc`.

README now documents both corrections in place, with what was verified and
when, rather than silently deleting the old claims.

---

## 2. Data pipeline — verified, one dormant gap found and left alone

- **`test/compare-derived.mjs --emit-js` runs clean**, exit code 0, full
  JSON dump produced. No live DB/psql access existed in this session to
  diff it against the SQL side — a tooling limitation, not a finding.
- **The two README-flagged known-stale items** were both confirmed stale
  and corrected (see Fix 3).
- **New parity gap found, confirmed dormant/unused, left as-is:**
  `trend[].sleep`, `trend[].drowsy`, and `trend[].operators` exist in JS's
  `derive()` (`src/dds-state.js:585`) but are absent from SQL's `trend`
  `jsonb_build_object` (`0025_dds_metrics_dow.sql:266-271`, which only
  emits `date, units, events, assets, avgSyncSeconds`). Checked whether
  anything in index.html actually reads `trend.sleep`/`trend.drowsy` —
  **nothing does** (grepped both index.html and `src/dds-charts.js`, zero
  hits). This is the same class of bug as the day-of-week issue fixed in
  migration `0025`, but it's currently inert: no chart or KPI is wired to
  read it, so there's no live symptom. Not fixed tonight because there's
  nothing to verify a fix against (no consumer, no visible wrong number) —
  but if `trend.sleep`/`trend.drowsy` ever gets wired into a chart later,
  it will silently return `undefined` for every signed-in user exactly
  like day-of-week did. Worth a proactive SQL addition the next time
  `dds_metrics()` gets touched, even though nothing is broken today.
- **`activeDays` divergence (README's second flagged item):** the
  *per-entity* (per-asset/per-operator) definition is already aligned —
  both `src/dds-state.js` and `dds_metrics()` use "distinct `shift_date`
  count" at that level, consistently across every migration checked (0006,
  0010, 0011, 0014, 0017, 0020, 0025). The fleet-wide rate-metric version
  the README specifically describes lives in `src/dds-insights.js` — which
  turned out, on inspection, to be a **stale/orphaned module**: grepped the
  entire repo and nothing (`index.html` included) imports it. Its
  `renderAnalyticsKpis()` defines a completely different, older 5-KPI set
  (Equipment/Drivers Involved/Avg Sync Delay/Actionable Alerts) than what's
  actually live in index.html today (Total Alerts/Sleep/Drowsiness/Drivers
  Involved/Assets Reporting) — index.html's own code comment
  (line ~10316-10322) explicitly says this older layout "read as a bug once
  compared side by side" and was superseded. **Practical effect: the
  `activeDays` divergence the README worried about may no longer be a live
  code path at all**, since the module that would exhibit it isn't loaded
  by the deployed app. Not deleted tonight (out of scope for a bug-fix
  pass, and deleting a file is a bigger call than fixing one), but flagged
  in the README for you to confirm and clean up.

## 3. Design / typography — spot-checked, one real gap found and fixed

Fix #1 above was the concrete finding here. Beyond that: spot-checked the
`--warning-bg`/`--warning-text` token pair used by the (new, this session)
factor-live-banner CSS — properly token-based, contrast-verified comment
already in the file (4.73:1 on `--amber-50`, matching what I independently
recomputed). No other hardcoded hex colors found anywhere else in the file
outside the 8 already fixed (grepped for `stroke="#......"` project-wide
after the fix — zero remain).

## 4. Security — the most thorough part of this audit, and the cleanest

No Supabase MCP/live-query access was available this session, so this is
based on careful reading of all 25 migration files plus index.html's auth
code, not a live database query.

**What's genuinely solid (verified, not just assumed):**
- Every table across all 25 migrations has RLS enabled with explicit
  policies — grepped for `create table` vs. `enable row level security`
  across the whole `supabase/migrations/` directory and every table has
  both.
- The app is a deliberate **single-tenant** design (documented explicitly
  in `0001_init.sql`: "Single tenant: any signed-in user reads all data.
  There is no site scoping.") — `auth.uid() is not null` is the real
  authorization boundary everywhere, not per-row ownership. This is a
  legitimate, intentional architecture for a fleet-wide dashboard, not a
  gap — confirmed via `dds_metrics()`'s own `SECURITY INVOKER` + explicit
  `if auth.uid() is null then raise exception` defense-in-depth check.
- All write/ingest functions (`dds_ingest`, `dds_minestat_ingest`, the
  review-queue RPCs, `dds_backfill_emp_no_from_minestat`) are consistently
  `SECURITY DEFINER`, revoked from `public`/`anon`, granted only to
  `authenticated`.
- `username_to_email()` (the username→email resolver login.html calls) is
  genuinely rate-limited (5 attempts/minute, keyed by lowercased username),
  returns an identical `null` for "unknown user," "pending approval," and
  "rate-limited" — so the throttle itself can't be used as an account-
  enumeration oracle. `search_path` is pinned on every `SECURITY DEFINER`
  function (prevents search-path hijacking). Admin self-promotion is
  structurally impossible (`profiles_update_admin` requires the caller's
  *own* profile to already be `role='admin' AND status='approved'`); the
  bootstrap first-admin promotion is a documented one-time manual SQL step,
  not something the app does itself. This is unusually careful prior work.
- **XSS**: dispatched a dedicated read-only audit of every `innerHTML`/
  `insertAdjacentHTML` site that touches driver names, asset IDs, operator
  names, remarks, contributing-factor text, and imported CSV/XLSX data.
  Result: **zero exploitable gaps found.** `esc()` (index.html:7060) is
  applied consistently everywhere attacker-controlled data reaches
  `innerHTML`. No `document.write`, `outerHTML`, or `eval`/`new Function`
  usage exists anywhere in the file.
- **CSV formula-injection protection is real code**, not just a test
  fixture: `csvCell()` (index.html:9531) and `csvCellLocal()`
  (index.html:15377) both prefix cells starting with `=+-@\t\r` with a
  single quote and both are actually called by every export path
  (`exportDerived()`, Alert Logs export). `test/fixture.json`'s formula-
  injection string only exercises the *parsing* pipeline via
  `parity.sh`/`compare-derived.mjs`, not export sanitization — the export
  side is verified by source reading only, not by an automated test (see
  gap below).
- Supabase URL/key are byte-identical across index.html, login.html, and
  reset-password.html (all `rispydfovrnvnwvfwrnw` / same
  `sb_publishable_...` key). Grepped for `service_role` in tracked files
  and full git history — every hit is a cautionary code comment, never an
  actual leaked key. `.gitignore` blocks `.env*`/`*.key`; nothing matching
  is tracked.

**What could not be verified from code — needs your dashboard check:**
- **Public sign-ups.** `Cloud.signUp()` (index.html:11536) calls
  `this.client.auth.signUp()` directly — Supabase Auth's own client SDK
  call. There's no visible "Sign Up" button on login.html (the only
  in-app callers are the admin-gated `adminCreateUser()` path), but that
  doesn't matter: because the publishable key is intentionally public
  (by design, per the README), *anyone* with browser devtools can call
  `supabase.auth.signUp()` directly against your project using that same
  key, regardless of what buttons the UI exposes. If public sign-ups are
  still enabled on the Supabase dashboard, this is a real open door — new
  accounts would land as `status='pending'` (can't sign in until approved,
  per `profiles_insert_self`/`username_to_email`'s approval gate) but they
  *would* exist and appear in the admin's User Management "pending"
  queue, which is a nuisance/spam vector even if not a data-access one.
  **Check Authentication → Providers → Email → "Allow new users to sign
  up" is OFF.** This is a one-click dashboard setting outside this
  session's reach entirely.
- Everything else in the README's "Supabase dashboard setup" section
  (Site URL, Redirect URLs allow-list) — same story, dashboard-only,
  unverifiable from here.

**Found but not fixed — low-risk, flagged for you:**
- No automated test exercises `esc()`, `csvCell()`, or any `innerHTML`
  render path — the escaping correctness above was verified by manual
  code reading, not CI. A future regression here wouldn't be caught
  automatically. Out of scope to build a test harness tonight; worth
  planning for.
- `imports_delete`/`alert_cases_delete` RLS policies allow any signed-in
  user to delete any import/case (consistent with the single-tenant
  model, not a bug) — but checked whether index.html actually exposes a
  delete-import UI action today and **it doesn't** (grepped for any
  client call site; none found). Dormant policy, no live exposure.

## 5. Other deploy-readiness checks — all clean

- `node --check` passes on all three HTML files' extracted inline
  `<script>` blocks (index.html, login.html, reset-password.html) and all
  five `src/*.js` modules individually.
- `.gitignore` correctly blocks `.env*`/`*.key`; nothing matching is
  tracked (`git ls-files | grep -iE '.env|.key'` → empty).
- Supabase URL/key match byte-for-byte across all three HTML entry points
  (checked above, security section).
- No `TODO`/`FIXME`/`XXX`/`HACK` markers anywhere in index.html.
- `src/AALYTICS.PNG` (1.2MB, untracked) looks like a stray reference
  screenshot someone dropped into `src/` by accident (misspelled
  "Analytics," not referenced anywhere in code). Left alone — deleting an
  untracked file you didn't ask about felt like the wrong call to make
  unsupervised, but you'll probably want to remove it or move it out of
  `src/`.
- No headless-browser/Playwright check was run — not available in this
  environment. The syntax/static checks above are the verification that
  was possible tonight.

---

## What to do with your first coffee

1. Flip the Supabase dashboard's public-sign-ups toggle off if it isn't
   already (2 minutes, the only real must-do before this is safe to call
   fully locked-down).
2. Skim the 3 new commits (`92fbabf`, `0d9c4cc`, `39b89ff`) — none of them
   touch data or schema, all are additive/corrective and easy to read.
3. Decide what to do with `src/dds-insights.js` (confirmed orphaned —
   nothing loads it) and `src/AALYTICS.PNG` (stray file) at your leisure;
   neither is blocking.
4. Push `driver-masterlist` when you're happy with it — nothing was pushed
   by this session.

---

## Follow-up pass — data handling & design polish — 2026-08-28

Second session same day, same branch, building on the audit above without
redoing it. Scope: (A) data/error-handling audit across every trust
boundary (ingestion, network/RPC calls, empty/loading/error states, input
validation, concurrency/races), and (B) design polish (chart palette
validation, forms/states visual consistency, spacing/type/card drift). No
Supabase MCP/API access this session either — same limitation as last
night, noted again wherever it matters. No destructive operations; no
`.gitignore`d files touched. Everything below is local/unpushed.

### Go / no-go read

**Still go**, same one manual step as last night (Supabase dashboard
public-sign-ups toggle — unchanged, unverifiable from code). Nothing found
this session downgrades that read; if anything it improves slightly — a
real "fetch failed" case now tells the user instead of going blank.

---

### Part A — Data handling & error handling

**Confirmed already solid (verified, not assumed) — no fix needed:**

- **`Cloud.ingest()`/`Cloud.ingestMinestat()`** (index.html ~11787-12040):
  genuinely well-built. Chunked at 2,000 rows, idempotent server-side
  (`on conflict do nothing`), retries only retryable HTTP statuses
  (401/403/408/429/5xx/network), proactively refreshes an about-to-expire
  JWT before each chunk (diagnosed from real edge-log evidence in the
  code's own comment), marks the import row failed server-side on
  exhausted retries, and reports exactly how many rows landed before a
  failure so a retry is resumable, not a restart. This is above the bar
  the task asked me to verify, not just meeting it.
- **`Cloud.metrics()`/`Cloud.metricsMulti()`** (index.html ~11683-11742):
  20s `withTimeout()` (proper implementation, `Promise.race` + guaranteed
  `clearTimeout`) on every RPC; `metricsMulti()` falls back to N sequential
  calls if `dds_metrics_multi` isn't deployed yet (42883/undefined_function
  detection), so a client ahead of its migration still works.
- **`App.loadFromServer()`'s primary-vs-supplementary error split**
  (index.html ~12790-12910): only the primary `dds_metrics()` failing sets
  a real error state; comparison/7d/MoM fetch failures degrade to "no
  deltas" (already null-safe downstream) rather than blanking the page.
  Thoughtful, correct design — left as-is.
- **`renderEmptyState()`** (index.html ~9808): KPIs go to em-dash (not
  "0", avoiding the exact "zero presented as real" trap Part A named),
  chart placeholder art is hidden via `visibility` (not removed, so real
  data can redraw into the same layout), a real "No data yet" message
  renders. Applied consistently via one function, one call site pattern —
  not reinvented per page.
- **Wrong file type / malformed file handling** (`processFile()`,
  index.html ~13548-13596): CSV BOM/encoding sniffed before parse
  (UTF-16 exports were silently mangled before this existed), XLSX parse
  wrapped in try/catch → "Could not parse workbook", unrecognized
  extension → "Unsupported file type", all via the same `addRecord()`
  error path the rest of the import list already renders. No crash path
  found for any file type tried.
- **Filter-change / stale-response races** — the worker-based local-import
  path (`createStore()`, index.html ~6892-7053) already has a real
  `reqId`/`latestReqId` guard: a superseded worker response is discarded
  even if it resolves after a newer request started, with a synchronous
  fallback for browsers without `Worker` support so the UI never sticks on
  'loading'. The 250ms filter-input debounce (index.html ~18230) correctly
  coalesces a from+to pair typed in quick succession into one request.
- **login.html sign-in error handling**: generic "Sign-in failed" message
  regardless of cause (unknown user / pending approval / wrong password) —
  correctly matches index.html's own account-enumeration protection rather
  than leaking which case it was.
- **Inverted date range (end before start) on the Overview/Analytics/DAM
  filter pickers**: no explicit validation exists, but traced both engines
  (`applyFilters()` in `src/dds-state.js:352` and every `dds_metrics()`
  migration's `where (p_from is null or ... >= p_from) and (p_to is null
  or ... <= p_to)`) and confirmed an inverted range naturally yields zero
  matching rows in both — no crash, no NaN, no negative-duration bug. It
  renders as the existing (already-fixed, see below) empty state, which is
  an accurate answer to an impossible range. Not fixed further — adding
  "your dates are backwards" copy for what's already a correct, non-crashing
  outcome would be scope creep for this pass.

**Fixes made:**

#### A1 — No byte-size/row-count ceiling on the main DDS alert-export dropzone
The conso (masterlist), roster, and MineStat upload flows already had
`MAX_ROWS`/`ROSTER_MAX_ROWS`/`MINESTAT_MAX_ROWS` (200,000 / 20,000 /
200,000) post-parse row-count ceilings. The main DDS alert-export dropzone
— the highest-volume import in the app — had **none**: no pre-parse
byte-size check, no post-parse row-count check. `DDS_API_CONTRACT.md`
explicitly flags this ("Cap file size and row count... An unbounded
spreadsheet parse is a trivial DoS") and it was the one path not doing it.
**Fix:** added `MAX_FILE_BYTES` (100MB, checked before any
`FileReader`/`Papa.parse`/`XLSX.read` call — protects against the tab
freezing regardless of row count) and `ALERT_IMPORT_MAX_ROWS` (200,000,
matching the existing convention, checked post-parse in
`handleParsedRows()`). Both reuse the exact same `addRecord()` error-flag
pattern every other rejection in this flow already uses.
**Verified:** `node --check` on the extracted script passes. No `src/`
counterpart exists for this dropzone logic (page-shell only, confirmed by
grep), so no sync owed.

#### A2 — `loadFromServer()` had no protection against overlapping requests
`createStore()`'s worker path already had a `reqId`/`latestReqId` guard
(see above) — `App.loadFromServer()`, the signed-in server path, did not,
despite having **five independent call sites** that can fire close
together in normal use: sign-in, the 250ms filter debounce, the manual
Refresh button, and auto-refreshes after an import or a name-review
resolution. Two overlapping calls (e.g. a Refresh click landing while a
debounced filter change is still awaiting its RPCs) would both eventually
reach `store._setRows([], cur)`, and whichever network round-trip happened
to resolve *last* would win — even if it was the older, now-stale request.
That is a real "wrong data flashes in" bug, not a hypothetical one: this
is the slowest network call in the app (20s timeout budget) and every
trigger listed above is a normal user action, not an edge case.
**Fix:** added `App._loadReqId`, the same reqId-bump-and-compare pattern
as the worker path, checked at all three points a superseded request could
still write to the store (the primary-fetch catch, after the primary
fetch succeeds, and after the comparison/delta multi-fetch).
**Verified:** `node --check` passes. No `src/` counterpart (this function
lives entirely in index.html's APP BRIDGE section).

#### A3 — Fetch-failure error state was invisible to sighted users
Real gap, not previously found: `store._setError()` (fired when the
primary `dds_metrics()` call fails) set `state.status = 'error'`, which
set `body[data-status="error"]`, and the **only** effect anywhere in the
app was a CSS rule (`'.chart-body { display: none }'`) plus a
screen-reader-only `announce()` call. `.state-error` — a real
`--danger`-toned box, defined in `dds-tokens.css`'s STATE LAYER right next
to the `.state-empty` box `renderEmptyState()` actually uses — was dead
CSS: grepped the whole file and it was never once inserted into the DOM.
A sighted, signed-in user whose fetch failed saw every chart card go
**blank with nothing in its place** — not "genuinely zero" (would still
show axes), not "no data yet" (has real copy) — just gone. This is exactly
the failure mode Part A's brief named: an error state indistinguishable
from anything, in this case indistinguishable from a rendering glitch.

The same bug existed independently in **Alert Logs** (`loadPage()`/
`render()`, index.html ~14748-14822): its own `.catch()` set
`state.rows = []` and re-rendered through the identical branch a
genuinely-empty-filter-result uses, so a failed fetch showed "No alerts
match the current filters" (false) with no distinguishing signal beyond
the same screen-reader announce.

**Fix (three parts, one commit each is impractical to separate cleanly, so
grouped as one coherent fix):**
1. Added `renderErrorState()`/`clearErrorState()` (index.html, right after
   `renderEmptyState()`/`clearEmptyState()`, same file section), mirroring
   them exactly: same insertion points (`.chart-body`, `.ev-list`), same
   placeholder-art-hiding mechanism (reused `CHART_SHAPE_SELECTOR`/
   `data-empty-hidden`, not duplicated). Wired into the single store
   subscriber that already drives every page repaint.
2. Extended the same function to also flip `#dmEmpty` (Driver & Asset
   Monitoring's table) into an error variant — that table is store-driven
   (`dmRenderTable()` reads `store.get()`'s derived rows, unlike every
   *other* `.imp-empty`-styled empty state in the file, which each own an
   independent fetch/reload() and were deliberately left alone: wiring
   them to the store's status would be a false positive on the wrong
   page).
3. Alert Logs' independent fetch got its own equivalent fix: added
   `state.error` to its local state object, set/cleared in
   `loadPage()`'s `.then()`/`.catch()`, and `render()` now shows
   "Couldn't load Alert Logs. Please retry." in a `--danger`-toned
   `data-variant="error"` (new, reuses the existing `.imp-empty` class
   family) instead of silently falling through to the generic
   empty-filter copy.
4. Removed the now-conflicting `body[data-status="error"] .chart-body {
   display: none }` CSS rule (both `src/dds-tokens.css` and index.html's
   inlined copy) — `display:none` would have hidden the very box just
   added and collapsed the card's height. Replaced with the same
   absolute-overlay treatment `.state-empty` already uses, so the card
   frame/axes stay in layout and only the plotted content is covered.
**Verified:** `node --check` on the extracted script passes after each
edit. Confirmed byte-identical between `src/dds-tokens.css` and
index.html's inlined STATE LAYER for the changed CSS block. Grepped for
the old `display: none` rule afterward — zero live occurrences remain
(only historical comment references documenting what it used to be).
**Not independently tested against a live failure** (no headless browser,
no way to force a real `dds_metrics()` failure this session) — the logic
mirrors the already-shipped, presumably-tested empty-state code path
closely enough that this is a reasonable confidence level, but flagged
explicitly per the verification standard's "say so" instruction.

---

### Part B1 — Chart/data-viz consistency

#### The palette re-step (the task's headline finding)

Ran `node scripts/validate_palette.js` from the dataviz skill's base
directory against the shipped hue ramp and reproduced every failure the
task brief described exactly:
- **Light mode:** navy (`#1B3A6B`) and purple (`#3C3489`) below the OKLCH
  lightness band; navy and teal (`#0F6E56`) below the chroma floor (read
  as gray); **blue vs. navy cleared only ΔE 13.5 for normal color vision —
  below the skill's 15 floor**, meaning full-color-vision users struggle
  to tell them apart, not just CVD users.
- **Dark mode** (against the real dark surface `#14161B`, since dark mode
  does NOT redefine the base hues — confirmed by reading index.html's own
  dark-theme comment: only `-50`/`-200`/`-text` tints change, so one
  passing palette has to satisfy both modes at once): same
  lightness/chroma failures, plus **`--red` (`#A32D2D`) at only 2.56:1
  contrast against the dark surface** — a real WCAG mark-contrast failure
  for a bare severity dot with no label.

Built a small local OKLCH/OKLab search (temporary script, not committed)
using the validator's own conversion math to snap each hue's
lightness/chroma into the passing band while nudging hue by only a few
degrees where needed (navy and blue were only 7° apart in hue — the real
root cause of the ΔE-13.5 failure — so lightness alone couldn't separate
them without an unacceptably large move; a small hue nudge did). Ran 60
randomized local-search restarts, kept only zero-FAIL solutions, and
picked the one with the lowest total distance from the original hues.

**Result — every hue moved only in L/C, plus 2-5° of H on navy/blue/teal/
purple (orange needed no change at all):**

| Color | Old | New | ΔH |
|---|---|---|---|
| `--navy` | `#1B3A6B` | `#1464B7` | 5° |
| `--blue` | `#185FA5` | `#4297E3` | 3° |
| `--teal` | `#0F6E56` | `#08785C` | 1° |
| `--red` | `#A32D2D` | `#C1332E` | 2° |
| `--amber` | `#BA7517` | `#BC7C30` | 0° |
| `--purple` | `#3C3489` | `#5C5AAE` | 0° |
| `--orange` | `#C4531D` | `#C4531D` | unchanged |

Re-ran the validator against the new values in both modes:
**ALL CHECKS PASS** — lightness band, chroma floor, CVD separation
(worst adjacent ΔE 9.5), normal-vision floor (worst adjacent ΔE 15.3, just
clearing the 15 floor), contrast vs. surface (all ≥ 3:1, including red
now at 3.26:1 against the dark surface vs. 2.56:1 before). Also checked
`--pairs all` out of extra caution (stricter than what this app's charts
actually need — no scatter/bubble/choropleth/small-multiples chart exists
anywhere in index.html, confirmed by grep, so adjacent-pairs is the
correct bar per the skill's own scoping rule): fails on a couple of
non-adjacent pairs (navy/purple, red/orange), which the skill's own docs
say is expected — "no ordering of the full eight can pass" all-pairs, and
this app never puts more than 2-3 series adjacent on one chart.

Visual sanity check (by eye, OKLCH values, not a rendered screenshot — no
headless browser this session): severity families stay clearly distinct —
red (critical) is now a slightly brighter, more saturated red; orange
(elevated) unchanged; amber (caution) very slightly warmer; purple
(notice) now noticeably more legible (was almost black-purple, now a real
violet). Navy is the biggest visual shift — from a very dark, low-chroma
navy to a richer, more saturated medium blue — because it was the color
furthest from passing (both lightness AND chroma AND hue-proximity-to-blue
were violations). It stays in the same hue family and the sidebar
gradient (`--navy` → `--navy-dark`, unchanged) still reads light-to-dark
top-to-bottom; `--navy-dark` was deliberately left untouched.

**Applied to:** `src/dds-tokens.css` and index.html's inlined `<style>`
copy (both the live `:root {}` block ~1358 AND an earlier, still-live
v2.2-era `:root{}` block at index.html:31 that the later block shadows in
the cascade but which was carrying stale values — updated for
future-editor clarity, not because it was visibly wrong). Also updated
`login.html` and `reset-password.html`'s own copies of these tokens for
brand consistency (only `--blue-200`, unchanged, is actually consumed via
`var()` on those two pages today — confirmed by grep — but the tokens
were kept in sync rather than left stale). Left `docs/superseded/*.html`
untouched (explicitly archived reference material, not live).
**Verified:** validator PASS in both modes (shown above); grepped the
whole repo for the old hex values afterward — zero remain outside
`docs/superseded/`; confirmed the two `:root{}` color blocks in
`src/dds-tokens.css` and index.html are byte-identical; `node --check` on
all three HTML files' extracted scripts passes.

#### Dual-axis chart — found, documented rather than restructured

The task asked me to check for dual-axis charts (a hard anti-pattern per
the skill). Found one: Overview's "Alert Volume Over Time" plots Total
Alerts and Distinct Assets **each on its own independent min/max scale**,
with two separately-tinted y-axes (`#ovTrendYAxis` / `#ovTrendYAxisRight`)
— a real, deliberate dual-axis chart, not a false alarm. The kicker: the
renderer's own code comment claimed the opposite — *"every entry shares
one scale — see the module header on why this codebase never does
dual-axis charts"* — which is simply false; the module header it points to
contains no such explanation, and the per-series-scaling code three lines
below the comment contradicts it directly. This is real comment/code
drift, the kind that misleads the next editor into thinking a violation
is a non-issue.
**Fix:** corrected the comment (both `src/dds-charts.js` and index.html's
inlined `trend()`) to accurately describe what the chart does and why —
per-series scaling avoids the smaller series flattening to the baseline,
axis tinting disambiguates which scale is which, and the hover tooltip
always shows real un-rescaled values so nothing is visually
misrepresented. **Did not restructure the chart itself** (split into two
charts / small multiples / indexed-to-100) — that is a real design change
with layout implications, not a comment fix, and is out of scope for a
"do not restructure working layouts" audit pass. Flagged here for a
deliberate decision later, not silently left mislabeled.
Also noted in passing: `src/dds-charts.js`'s `trend()` is an older,
simpler version than index.html's inlined one (missing `showPrev`,
per-series scaling, and using a different `SERIES_COLOR`/`paths` set) —
pre-existing `src/`/index.html drift from before this session, flagged in
the corrected comment but not re-synced (a full re-sync of two diverged
implementations is a bigger job than this pass's mandate).

#### Everything else in B1 — checked, already clean

- **Hardcoded hex colors bypassing tokens**: grepped for
  `stroke="#......"`/`fill="#......"` — zero remain (last night's 8-fix
  from `92fbabf` held; no new instances found).
- **Legends on 2+-series charts**: every multi-series chart has one
  (`.legend-block`/`.legend-item`, checked every chart-body in Overview
  and Analytics) — none missing.
- **Color-only status encoding**: checked every `severityForCode()`
  render site (Alert Logs table pills, Driver & Asset Monitoring status
  pills, Analytics event-code legend) — every one renders the actual code/
  status text alongside the color via `.pill`, never a bare colored dot.
  Already correct; no fix needed.

---

### Part B2 — Forms, empty/error/loading states (visual treatment)

- **Dead duplicate `.field-input` CSS found and removed.** Two
  definitions existed: a v2.2-era one at index.html:1265-1266 (hardcoded
  `var(--blue)`/`var(--blue-50)` focus ring, no hover/disabled/invalid
  states) and the real, later STATE LAYER one (~1867, uses `--accent`/
  `--shadow-focus`/`--danger` tokens, has hover + `[aria-invalid]`
  states). Because the later block is later in the same stylesheet with
  equal specificity, it already won the cascade on every property both
  set — so this was **not a live visual bug** (every `.field-input`,
  including Settings' Personal Information fields, already renders with
  the correct, consistent focus/invalid treatment) — but the early block
  was confusing dead CSS that would mislead a future editor into thinking
  it was live. Removed, with a comment pointing to the real rules.
  **Verified:** confirmed every property the early block set was fully
  shadowed by the later block before removing anything; `node --check`
  passes; grepped for a `src/` counterpart of the dead block (none found —
  `src/dds-tokens.css` only ever had the live version).
- Error-state visual treatment (the new `.state-error`/`.imp-empty[data-
  variant="error"]` boxes added in Part A3) uses `--danger`/`--danger-bg`
  consistently, matching every other danger-toned element already in the
  file (`.field-input[aria-invalid]`, `.btn-danger`, `.pill[data-
  variant="danger"]`) — no ad-hoc color introduced.

---

### Part B3 — Overall visual consistency

- **Fixed:** `.settings-body{padding:16px; ...; gap:16px}` →
  `var(--sp-6)` on both properties — an exact, zero-risk token match (16px
  IS `--sp-6`, confirmed against the tokens file's own migration-map
  comment).
- **Found, deliberately NOT fixed:** a broader, pre-existing pattern of
  hardcoded pixel spacing that exactly matches spacing tokens — roughly
  90 instances across the file (`gap:8px`×19, `gap:6px`×17, `gap:4px`×12,
  `gap:12px`×10, `padding:8px`×8, etc.). This is systemic drift that
  predates this session, not something introduced recently, and a full
  find-and-replace across ~90 call sites the night before deploy is
  exactly the "restructuring for a marginal consistency gain" the task
  brief said to avoid — the visual result is already correct (these ARE
  the token values, just spelled as literals), so the only value fixing
  them would add is search/replace-ability, not a user-visible
  improvement. Left as a known item for the next dedicated pass rather
  than swept in bulk here.
  Also spot-checked `.donut-wrap{gap:16px;padding:10px 16px 14px}`
  (index.html:839) as a candidate — its 10px/14px values do NOT map
  cleanly onto any token (10px sits between `--sp-4`=8px and `--sp-5`=
  12px; 14px between `--sp-5`=12px and `--sp-6`=16px), so a token swap
  would be a real ~2px visible shift, not a no-op. Left untouched.
- **Card/KPI class reuse**: spot-checked `.card`/`.kpi`/`.akpi` usage
  across Overview, Analytics, Driver & Asset Monitoring, and Settings —
  no page found reinventing its own card shell where the shared class
  would have worked; drift was confined to raw spacing values (above), not
  structural pattern duplication.

---

### Verification summary for this session

- `node --check` passes on index.html, login.html, and reset-password.html
  (extracted inline `<script>` blocks) and on `src/dds-charts.js`,
  individually, after every edit in this session.
- `src/dds-tokens.css` brace-balance checked (104 open / 104 close) since
  it has no `node --check` equivalent.
- `node scripts/validate_palette.js` (dataviz skill) re-run against the
  final 7-color palette in both light and dark mode: **ALL CHECKS PASS**,
  shown in full above.
- Grep-based zero-remaining checks run for: old palette hex values
  (repo-wide, excluding `docs/superseded/`), the removed `display: none`
  error-state CSS rule, and the dead `.field-input` CSS block's `src/`
  footprint (none).
- **Not verified** (no Supabase MCP/live-query access, no headless
  browser this session — same gaps as last night): the new error-state UI
  against a real forced `dds_metrics()` failure; any visual/screenshot
  confirmation of the new palette or the error-state boxes actually
  rendering as intended in a browser. Both are logic-level-only
  verification (code reading + `node --check` + the palette validator);
  said explicitly here per the task's verification standard rather than
  claimed as fully confirmed.

### Updated go/no-go read

Unchanged from "go" — nothing found this session is a blocker, several
things (the palette failing the skill's own colorblind-safety/contrast
checks, a genuinely invisible fetch-error state, an unbounded main-import
dropzone) were real gaps worth fixing before a wider rollout, and all are
now fixed and verified to the extent this session's tooling allows.
