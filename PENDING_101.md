# Pending 101 — Summary page is substantially mock content

Found during a live-data audit (signed in, real database, 2026-09-04) that
no prior code-only audit surfaced, because the markup renders and looks
plausible in isolation — the tell only shows up comparing it against real
values (fabricated driver names that don't match any real employee, a
`42` that doesn't match the real KPI it sits next to).

## What's actually live vs. mock on the Summary page (`#page-summary`)

**Live, confirmed correct:**
- "Top Flagged Drivers & Assets" table — reads `window.__daState` /
  `__daComputeRisk` from Driver & Asset Monitoring's own IIFE
  (`index.html:4229-4288`), verified rendering real driver/asset rows.
- "Actions Logged This Week" — same live-state pattern, confirmed empty-
  but-correctly-wired (no actions logged yet in the real account tested).

**100% static mock markup — zero JS ever writes to these elements:**
- Top KPI row: Total Alerts (`7`), Sleep Alerts (`4`), Drowsiness Alerts
  (`3`), Drivers Involved (`6`), Assets Reporting (`6`) —
  `index.html:2269-2289` (`.su-kpi-value`). Grepped the whole file for any
  `.su-kpi-value` writer: none exists.
- "Total Alerts — 7-Day Trend" chart, including its Wed–Tue axis labels,
  the `12`-peak data points, and the "↓ 22% vs prior day" badge —
  `index.html:2294+` (`.su-trend-*`). No writer.
- "Top Increases & Key Insights" card — all 4 rows are literal hardcoded
  text (`index.html:2348-2379`), including **fabricated driver names**
  ("M. Rabe", "R. Jade", "Medalla" — none of whom exist in the real
  masterlist/topOperators data) and fabricated percentages (18%/21%) that
  don't match the real Analytics numbers for the same account (41%/41%
  on the date this was tested). No writer targets `.su-insight-list`.
- "Open Items" card — Events in view (`1,842`), Critical severity (`126`),
  Pending review (`18`), Actioned (`94%`) — `index.html:2412-2429`
  (`.su-open-value`). No writer. `1,842` is the same number the original
  mock hardcoded everywhere before the Application A/B migration (see
  `MIGRATION_MAP.md` §7) — this card was apparently never touched during
  that migration's pass over this page.

## Why this wasn't caught earlier

Every prior audit in this project (the original UX audit, the two
code-correctness passes) was either a static code read or testing against
the app in a **signed-out** state, where every live section legitimately
shows "Sign in to load real data" placeholder text — which looks
identical in kind to a hardcoded mock value from a quick glance, so
nothing stood out as suspicious. Only signing in with a real account and
cross-checking specific numbers against their source (e.g. "does '42
assets' match the real distinctAssets KPI shown one page over on
Analytics?") surfaced it.

## What a real fix needs (design decisions, not just wiring)

- **KPI row + trend**: mechanically straightforward — these map cleanly
  onto `dds_metrics()` fields already fetched elsewhere (`kpis.totalAlerts`,
  a Sleep/Drowsiness split via `eventCodeDistribution`, `distinctOperators`,
  `distinctAssets`, `trend[]`). The open question is *which* 7-day window:
  same definition as Overview's KPI row (trailing 7 real calendar days), or
  something anchored to whatever "Wed–Tue" in the current mock implies.
- **Open Items**: needs either a new lightweight RPC or reusing
  `dds_alert_logs()` with `p_limit: 1` (reading just its `total` +
  aggregate fields) scoped to the Summary page's 7-day window — Alert
  Logs' own KPI tiles are current-*page*-scoped (20 rows), not window-
  scoped, so they can't be reused directly as-is.
- **"Top Increases & Key Insights"**: the real feature-design question.
  Needs an actual insight-generation approach (e.g. "biggest week-over-week
  mover among assets/drivers/factors, ranked by magnitude") decided and
  built, not a mechanical field-mapping — there's no existing RPC that
  produces this shape of output today.

Not fixed in this pass per direct instruction — tracked here for a future
session to pick up.
