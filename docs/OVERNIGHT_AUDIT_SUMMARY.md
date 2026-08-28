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
