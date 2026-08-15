/* ============================================================================
   DDS — Analytics KPI Strip (period-comparison layout)
   ----------------------------------------------------------------------------
   DESIGN RATIONALE

   Earlier version: one wide "Summary" insight card (prose headline + a
   single hero metric + a quiet stat strip) living beside two donut charts.
   Superseded to match a reference layout that puts every one of the six
   compare() metrics into its own KPI tile at the top of the page — no
   separate Summary card, no prose headline.

   Each tile still says the same three things the old hero did (current
   value, direction/magnitude of change, what it's being compared to) — just
   once per metric instead of once for a single "most important" metric. No
   sparkline anywhere anymore (an earlier pass had one on alertRate; removed
   along with the rest of the KPI tiles' chart chrome — see kpiTile()'s own
   header comment for the current avg-per-asset/current-vs-previous design).

   The partial-baseline caveat (baselineComplete/baselineCoverage) can't be
   true for one metric and false for another — it's a property of the
   comparison window itself — so it renders once, attached to totalAlerts
   (the first, highest-traffic tile) rather than repeating six times. */

import { fmt } from './dds-charts.js';

const esc = s => String(s ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ── Icons ──────────────────────────────────────────────────────────────── */

const ICON = {
  alert: '<path d="M12 9v4m0 4h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z"/>',
  rate:  '<path d="M3 3v18h18"/><path d="m19 9-5 5-4-4-3 3"/>',
  truck: '<path d="M10 17h4V5H2v12h3"/><path d="M20 17h2v-3.3a4 4 0 0 0-.9-2.5l-1.9-2.3a2 2 0 0 0-1.5-.7H14v8.8h2"/><circle cx="7.5" cy="17.5" r="2.5"/><circle cx="17.5" cy="17.5" r="2.5"/>',
  user:  '<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>',
  sync:  '<path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 3v6h-6"/>',
  check: '<path d="M22 11.1V12a10 10 0 1 1-5.9-9.1"/><path d="m9 11 3 3L22 4"/>',
  up:    '<path d="m6 15 6-6 6 6"/>',
  down:  '<path d="m6 9 6 6 6-6"/>',
  flat:  '<path d="M5 12h14"/>',
  info:  '<path d="M12 16v-4m0-4h.01"/><circle cx="12" cy="12" r="10"/>'
};

const svg = (name, cls = 'ic') =>
  `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor"
        stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"
        aria-hidden="true" focusable="false">${ICON[name] ?? ''}</svg>`;

const METRIC_ICON = {
  totalAlerts: 'alert', alertRate: 'rate', distinctAssets: 'truck',
  distinctOperators: 'user', avgSyncSeconds: 'sync', actionableRatio: 'check'
};

/* Each tile keeps the icon tint distinct so the row scans by colour before
   it scans by label, same convention as the rest of the app's KPI/donut
   colouring (amber=alerts, purple/teal=assets & sync depending on page).
   Values are CSS var() pairs, matching how every other .kpi-icon in this
   app sets its background/color inline rather than via a class. */
const METRIC_TINT = {
  totalAlerts:       ['--amber-50',  '--amber'],
  alertRate:         ['--blue-50',   '--blue'],
  distinctAssets:    ['--teal-50',   '--teal'],
  distinctOperators: ['--blue-50',   '--blue'],
  avgSyncSeconds:    ['--amber-50',  '--amber'],
  actionableRatio:   ['--purple-50', '--purple']
};

/* alertRate ('Alerts Per Asset Per Active Day') dropped from the KPI row —
   normalizing by both asset count AND active days read as misleading rather
   than clarifying (a jump driven by more assets reporting looked identical
   to one driven by drivers getting drowsier). distinctAssets, already a
   plain vs-previous comparison metric, takes its slot instead. */
const METRIC_LABEL = {
  totalAlerts: 'Total Alerts', alertRate: 'Alerts Per Asset Per Active Day',
  distinctAssets: 'Equipment', distinctOperators: 'Drivers Involved',
  avgSyncSeconds: 'Avg Sync Delay', actionableRatio: 'Actionable Alerts'
};

/* ── Formatting ─────────────────────────────────────────────────────────── */

function formatValue(v, unit) {
  if (v == null) return '—';
  switch (unit) {
    case 'duration': return fmt.sync(v);
    case 'percent':  return fmt.pct(v, 1);
    case 'rate':     return v.toFixed(2);
    default:         return fmt.int(v);
  }
}

/* One tile per metric. No delta chip/arrow, no sparkline, no computed
   PERCENTAGE on the raw alert count — a percent change on hundreds of
   alerts has no ceiling (current/previous can legitimately swing past
   1000% once previous is small relative to current), and no amount of
   window-matching or caveat text stopped a big number from reading as
   broken/fabricated on sight.

   For alert-COUNT metrics (m.perAsset set — see dds-state.js's compare()
   perAsset()), the card instead shows the avg-alerts-per-asset rate for
   BOTH periods side by side, labeled with the REAL window length
   ("Current 7d avg" / "Current 30d avg" / etc, from c.periods.baselineDays
   — never a hardcoded "7d" that could mislabel a longer comparison):
   current (colored red if it rose, teal/green if it fell — a deliberate,
   scoped exception to this app's usual no-colored-delta rule, since for an
   alert-count rate specifically up is unambiguously worse and down is
   unambiguously better) and previous (always neutral gray, a fixed
   historical fact rather than a colored "event"). No percent, no +/- sign
   — the two plain rate values are the whole comparison; fleet-size growth
   is already canceled out by the per-asset division. Every other metric
   (asset count, driver count, sync delay, actionable ratio) has no
   meaningful per-asset form — "assets per asset" is nonsense — so those
   stay one line, just the previous period's plain value (the headline
   above it is already "current", so this isn't a repeat). */
function kpiTile(m, c, { note = false } = {}) {
  const [bg, fg] = METRIC_TINT[m.key] ?? ['--blue-50', '--blue'];
  const label = METRIC_LABEL[m.key] ?? m.label;

  let compare;
  if (note && c.baselineComplete === false) {
    // Partial-baseline is a property of the whole comparison window, not
    // any one metric — shown on a single tile (`note: true`, the caller's
    // choice) rather than repeating the same caveat on all five.
    compare = `<div class="akpi-note">${svg('info', 'ic-xs')}<span>Partial baseline: only ${Math.round((c.baselineCoverage ?? 0) * 100)}% of ${esc(c.periods.previous)} covered</span></div>`;
  } else if (m.perAsset && m.perAsset.current != null && m.perAsset.previous != null) {
    const { current: curRate, previous: prevRate } = m.perAsset;
    const tone = curRate > prevRate ? 'bad' : curRate < prevRate ? 'good' : 'neutral';
    const windowLabel = `${c.periods.baselineDays ?? c.periods.spanDays}d avg`;
    compare = `<div class="akpi-avg7d">
         <div class="akpi-avg7d-col"><span class="akpi-avg7d-val" data-tone="${tone}">${esc(curRate.toFixed(1))}</span><span class="akpi-avg7d-label">Current ${esc(windowLabel)}</span></div>
         <div class="akpi-avg7d-col"><span class="akpi-avg7d-val" data-tone="prev">${esc(prevRate.toFixed(1))}</span><span class="akpi-avg7d-label">Previous ${esc(windowLabel)}</span></div>
       </div>`;
  } else if (m.key === 'distinctAssets') {
    // Assets Reporting: current vs previous DISTINCT asset_id count, side
    // by side like the alert-rate cards — but never colored. Unlike an
    // alert count, more (or fewer) assets reporting isn't inherently good
    // or bad on its own, so this stays neutral gray on both sides.
    compare = `<div class="akpi-avg7d">
         <div class="akpi-avg7d-col"><span class="akpi-avg7d-val">${esc(formatValue(m.current, m.unit))}</span><span class="akpi-avg7d-label">Current</span></div>
         <div class="akpi-avg7d-col"><span class="akpi-avg7d-val" data-tone="prev">${esc(formatValue(m.previous, m.unit))}</span><span class="akpi-avg7d-label">Previous</span></div>
       </div>`;
  } else {
    compare = `<div class="akpi-rate"><span class="akpi-rate-val">${esc(formatValue(m.previous, m.unit))}</span><span class="akpi-rate-label">previous period</span></div>`;
  }

  return `
  <div class="kpi akpi" style="--kpi-accent:var(${fg})">
    <div class="akpi-head">
      <div class="kpi-icon" style="background:var(${bg});color:var(${fg})">${svg(METRIC_ICON[m.key], 'ic')}</div>
      <div class="kpi-label">${esc(label)}</div>
    </div>
    <span class="kpi-val">${formatValue(m.current, m.unit)}</span>
    ${compare}
    <span class="sr-only">${esc(label)}: ${formatValue(m.current, m.unit)} in the current period,
      ${formatValue(m.previous, m.unit)} in ${esc(c.periods.previous)}.</span>
  </div>`;
}

/* ── Entry point ────────────────────────────────────────────────────────── */

/* Tile order: volume, equipment, people, sync, then the actionable-ratio
   close. alertRate intentionally omitted — see METRIC_LABEL comment. */
const ORDER = ['totalAlerts', 'distinctAssets',
                'distinctOperators', 'avgSyncSeconds', 'actionableRatio'];

export function renderAnalyticsKpis(el, derived) {
  if (!el) return;
  const c = derived?.comparison;

  if (!c || c.available === false) {
    el.innerHTML = `
      <div class="state-empty">
        <div class="state-empty-title">No comparison available</div>
        <div>${esc(c?.reason ?? 'Import at least two periods to see how things are trending.')}
          ${c?.periods ? `Looked for ${esc(c.periods.previous)}.` : ''}</div>
      </div>`;
    return;
  }

  const byKey = Object.fromEntries(c.metrics.map(m => [m.key, m]));
  el.innerHTML = ORDER
    .map(key => byKey[key] && kpiTile(byKey[key], c, {
      note:  key === 'totalAlerts'
    }))
    .filter(Boolean)
    .join('');
}
