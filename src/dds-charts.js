/* ============================================================================
   DDS — Unified Chart Renderer
   ----------------------------------------------------------------------------
   Replaces OverviewCharts (11.2KB) + AnalyticsCharts (12.1KB) with one
   registry of pure render functions driven by `derived` from dds-state.js.

   Every renderer has the same signature:
       render(el: Element, derived: Derived, opts: object) -> void

   Pages declare WHICH charts they show and WITH WHAT OPTIONS. They never
   contain painting logic. Adding a page = adding a config block.

   ⚠ MEASURE — read this before wiring.
   v2.2's two pages silently disagreed on what two charts meant:

     Chart                     Overview            Analytics
     ------------------------  ------------------  ------------------
     Shift Distribution        sum(EVENT_COUNT)    count(rows)
     Event Code Distribution   sum(EVENT_COUNT)    count(rows)

   Same title, same data, different numbers. Users comparing the two pages
   would see different percentages and reasonably conclude one is broken.
   `measure` is now an explicit, required option so the choice is visible in
   config instead of buried in two diverged functions. Pick one and mean it.
   ========================================================================= */

import { SYNC_BUCKETS, ALERT_BUCKETS } from './dds-state.js';

/* ── Safety ─────────────────────────────────────────────────────────────── */

/* ASSET_ID, OPERATOR and EVENT_CODE come from an uploaded spreadsheet. In
   v2.2 they were concatenated straight into innerHTML in four places
   (paintTopAssets, paintTopUnits, paintTopOperators, paintEventCodes), so a
   cell containing `<img src=x onerror=...>` executes for every user who views
   the dashboard — stored XSS with a file upload as the delivery mechanism.
   Everything user-derived goes through esc() or textContent below. */
const esc = s => String(s ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ── Shared formatting ──────────────────────────────────────────────────── */

const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

export const fmt = {
  int: n => Math.round(n).toLocaleString(),
  pct: (n, d = 0) => `${n.toFixed(d)}%`,
  /** 'MM/DD/YYYY' -> 'Mar 4' */
  shortDate(mmddyyyy) {
    const [mm, dd] = String(mmddyyyy).split('/').map(Number);
    return `${MONTHS[mm - 1]} ${dd}`;
  },
  /** ISO datetime -> 'Jul 31, 2026 09:15' (UTC, matching the app's UTC-only
      time semantics — see dds-state.js TIME SEMANTICS). */
  dateTime(iso) {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return '—';
    const hh = String(d.getUTCHours()).padStart(2, '0');
    const mi = String(d.getUTCMinutes()).padStart(2, '0');
    return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}, ${d.getUTCFullYear()} ${hh}:${mi}`;
  },
  sync(seconds) {
    if (seconds == null) return '—';
    if (seconds < 60)   return `${seconds.toFixed(1)} sec`;
    if (seconds < 3600) return `${(seconds / 60).toFixed(1)} min`;
    return `${(seconds / 3600).toFixed(1)} hr`;
  },
  /** Compact axis-tick form: 1,284 -> "1.3K", 950 -> "950". Never used for
      exact values (tooltips/tables keep fmt.int) — ticks only. */
  compact(n) {
    const v = Math.round(n);
    if (Math.abs(v) < 1000) return String(v);
    return `${(v / 1000).toFixed(v % 1000 === 0 ? 0 : 1)}K`;
  }
};

export const EVENT_COLORS = [
  'var(--blue)', 'var(--teal)', 'var(--amber)',
  'var(--purple)', 'var(--red)', 'var(--navy)'
];

/* Event-code color must be stable across imports, or an operator's learned
   "purple = Drowsiness Alert" association silently breaks the next time a
   file happens to sort differently. Colors were previously assigned by
   array position (i % EVENT_COLORS.length) — whichever code sorted first
   got blue. Hashing the code STRING itself means the same code always maps
   to the same color, independent of how many other codes are present or
   what order they arrived in. Not cryptographic; just needs to be stable
   and spread reasonably across the palette. */
export function colorForCode(code) {
  const s = String(code ?? '');
  let hash = 0;
  for (let i = 0; i < s.length; i++) hash = (hash * 31 + s.charCodeAt(i)) | 0;
  return EVENT_COLORS[Math.abs(hash) % EVENT_COLORS.length];
}

/* ── Event severity ─────────────────────────────────────────────────────── */

/* EVENT_CODE is free text from an uploaded CSV — there is no fixed enum, so
   this is a lookup with a graceful fallback, not a hard-coded switch over
   "the" event types. Confirmed real values seen in production data: "Sleep
   Alert", "Drowsiness Alert". "Inattentive" and "Poor Driver Posture" are
   anticipated (per the design brief) but not yet confirmed to appear —
   matched defensively (case-insensitive substring) so they resolve
   correctly if/when they do, without assuming they're the only other codes
   that will ever show up. Anything unmatched falls back to colorForCode()'s
   stable hash so distinct unknown codes still look distinct from each
   other, just without a specific severity meaning attached. */
const SEVERITY_RULES = [
  { test: /sleep/i,                          key: 'critical', label: 'Critical' },
  { test: /drowsi/i,                         key: 'elevated', label: 'Elevated' },
  { test: /inattent/i,                       key: 'caution',  label: 'Caution'  },
  { test: /posture|poor driver/i,            key: 'notice',   label: 'Notice'   }
];

const SEVERITY_TOKENS = {
  critical: { fg: 'var(--sev-critical)', bg: 'var(--sev-critical-bg)' },
  elevated: { fg: 'var(--sev-elevated)', bg: 'var(--sev-elevated-bg)' },
  caution:  { fg: 'var(--sev-caution)',  bg: 'var(--sev-caution-bg)'  },
  notice:   { fg: 'var(--sev-notice)',   bg: 'var(--sev-notice-bg)'   }
};

/** Returns { key, label, color, bg } for an EVENT_CODE. Unknown codes get a
    stable hash-based color (via colorForCode) and a neutral badge tint, so
    they're still visually distinguishable from each other without
    impersonating a known severity level. */
export function severityForCode(code) {
  const s = String(code ?? '');
  const rule = SEVERITY_RULES.find(r => r.test.test(s));
  if (rule) return { key: rule.key, label: rule.label, ...SEVERITY_TOKENS[rule.key] };
  return { key: 'unknown', label: 'Other', color: colorForCode(s),
           fg: colorForCode(s), bg: 'var(--border-light)' };
}

const CIRCUMFERENCE = 2 * Math.PI * 58;   // r=58, matches existing markup
const NEUTRAL = '#B4B2A9';

/* ── Primitives ─────────────────────────────────────────────────────────── */

/** Horizontal labelled bar list. Used by event codes, top assets, top operators. */
function barList(el, items, { max, showPct = true, emptyText = 'No data' } = {}) {
  if (!items.length) { el.innerHTML = `<div class="ev-empty">${esc(emptyText)}</div>`; return; }
  const peak = max ?? Math.max(...items.map(i => i.value), 1);
  el.innerHTML = items.map(({ label, value }) => {
    const pct = Math.round((value / peak) * 100);
    return `<div class="ev-row">
      <div class="ev-label" title="${esc(label)}">${esc(label)}</div>
      <div class="ev-track"><div class="ev-fill" style="width:${pct}%"></div></div>
      <div class="ev-val">${fmt.int(value)}${showPct ? ` (${pct}%)` : ''}</div>
    </div>`;
  }).join('');
}

/** Single-segment donut (two-way split). */
function donutSplit(arcEl, totalEl, primaryValue, total) {
  const len = total > 0 ? (primaryValue / total) * CIRCUMFERENCE : 0;
  arcEl.setAttribute('stroke-dasharray', `${len.toFixed(1)} ${CIRCUMFERENCE.toFixed(1)}`);
  if (totalEl) totalEl.textContent = fmt.int(total);
}

/** Multi-segment donut (n-way split). Each segment carries its own `color`
    (see colorForCode) rather than being colored by array position. */
function donutSegments(arcsEl, segments) {
  const total = segments.reduce((s, x) => s + x.value, 0);
  let offset = 0;
  arcsEl.innerHTML = segments.map((seg) => {
    const len = total > 0 ? (seg.value / total) * CIRCUMFERENCE : 0;
    const arc = `<circle cx="80" cy="80" r="58" fill="none"
      stroke="${seg.color}" stroke-width="22"
      stroke-dasharray="${len.toFixed(1)} ${CIRCUMFERENCE.toFixed(1)}"
      stroke-dashoffset="-${offset.toFixed(1)}" transform="rotate(-90 80 80)"/>`;
    offset += len;
    return arc;
  }).join('');
  return total;
}

/* Catmull-Rom -> cubic Bézier conversion (standard 1/6-tangent form). Curves
   through every point exactly — nothing is smoothed away or approximated,
   only the segments BETWEEN real points are eased instead of drawn as
   straight jogs. Endpoints reuse their single neighbor as both control
   references (clamped), so the curve doesn't overshoot past the first/last
   point. */
function smoothPath(points) {
  if (points.length < 3) {
    return points.map((p, i) => `${i === 0 ? 'M' : 'L'}${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(' ');
  }
  let d = `M${points[0].x.toFixed(1)},${points[0].y.toFixed(1)}`;
  for (let i = 0; i < points.length - 1; i++) {
    const p0 = points[i === 0 ? 0 : i - 1];
    const p1 = points[i];
    const p2 = points[i + 1];
    const p3 = points[i + 2 < points.length ? i + 2 : i + 1];
    const c1x = p1.x + (p2.x - p0.x) / 6;
    const c1y = p1.y + (p2.y - p0.y) / 6;
    const c2x = p2.x - (p3.x - p1.x) / 6;
    const c2y = p2.y - (p3.y - p1.y) / 6;
    d += ` C${c1x.toFixed(1)},${c1y.toFixed(1)} ${c2x.toFixed(1)},${c2y.toFixed(1)} ${p2.x.toFixed(1)},${p2.y.toFixed(1)}`;
  }
  return d;
}

/** Map values to a smooth SVG path within a plot box. */
function linePath(values, { top, bottom, width, min = null, max = null }) {
  const n = values.length;
  if (!n) return { d: '', points: [] };
  const lo = min ?? Math.min(...values);
  const hi = max ?? Math.max(...values);
  const range = (hi - lo) || 1;
  const points = values.map((v, i) => ({
    x: n === 1 ? width / 2 : (i / (n - 1)) * width,
    y: bottom - ((v - lo) / range) * (bottom - top)
  }));
  return { d: smoothPath(points), points };
}

/** Vertical stacked bars: actionable (blue) over non-actionable (neutral). */
function stackedBars(el, labels, actionable, nonActionable, geo) {
  const { groupW, gap, baseline, top, offsetX } = geo;
  const peak = Math.max(...actionable.map((v, i) => v + nonActionable[i]), 1);
  el.innerHTML = labels.map((_, i) => {
    const a = actionable[i], n = nonActionable[i], sum = a + n;
    const totalH = (sum / peak) * (baseline - top);
    const aH = sum > 0 ? totalH * (a / sum) : 0;
    const nH = totalH - aH;
    const x = i * gap + offsetX, aY = baseline - aH;
    return `<rect x="${x}" y="${aY.toFixed(1)}" width="${groupW}"
              height="${Math.max(aH, 0).toFixed(1)}" fill="var(--blue)" rx="2"/>
            <rect x="${x}" y="${(aY - nH).toFixed(1)}" width="${groupW}"
              height="${Math.max(nH, 0).toFixed(1)}" fill="${NEUTRAL}" rx="2"/>`;
  }).join('');
}

/* ── Tooltip ─────────────────────────────────────────────────────────────── */

/* Shared hover layer for the hand-rolled inline-SVG charts in this file (no
   charting library — see the header comment). One `.chart-tooltip` div per
   chart-body; callers show/position/hide it and supply the HTML content.
   Content is built by each chart's own hover handler via buildTooltipHTML()
   below, which escapes every label through esc() since series/category
   names can originate in an uploaded CSV (ASSET_ID, OPERATOR, EVENT_CODE). */
function showTooltip(tipEl, container, x, y, html) {
  if (!tipEl) return;
  tipEl.innerHTML = html;
  tipEl.dataset.open = 'true';
  const box = container.getBoundingClientRect();
  const tw = tipEl.offsetWidth || 160, th = tipEl.offsetHeight || 60;
  let left = x + 14, top = y - th - 10;
  if (left + tw > box.width) left = x - tw - 14;
  if (top < 0) top = y + 14;
  tipEl.style.left = `${Math.max(4, left)}px`;
  tipEl.style.top = `${Math.max(4, top)}px`;
}

function hideTooltip(tipEl) {
  if (tipEl) tipEl.dataset.open = 'false';
}

/** Build the inner HTML for a tooltip: title + rows of {label, value, color}. */
function tooltipHTML(title, rows, note) {
  const rowsHtml = rows.map(r => `
    <div class="chart-tooltip-row">
      ${r.color ? `<span class="chart-tooltip-key" style="background:${r.color}"></span>` : ''}
      <span class="chart-tooltip-label">${esc(r.label)}</span>
      <span class="chart-tooltip-value">${esc(r.value)}</span>
    </div>`).join('');
  return `<div class="chart-tooltip-title">${esc(title)}</div>${rowsHtml}` +
         (note ? `<div class="chart-tooltip-note">${esc(note)}</div>` : '');
}

/** Wire mousemove/mouseleave over an SVG's hit layer to a tooltip div.
    `locate(evt, svg)` returns the nearest data index (or null) given a
    pointer event in SVG user-space coordinates; `content(i)` returns the
    tooltip HTML for that index. Keeps every chart's hover logic declarative
    instead of duplicating the coordinate-mapping boilerplate per chart.

    Every chart re-renders on each store change (filter, refresh, import),
    which would normally pile up a fresh closure on `addEventListener` every
    time. Assigning to `.onmousemove`/`.onmouseleave` instead of adding a
    listener replaces the previous handler rather than stacking a new one,
    so repeated renders stay at exactly one handler each. */
function wireHover(svg, tipEl, { toSvgPoint, locate, content }) {
  if (!svg || !tipEl) return;
  const container = svg.closest('.chart-body') || svg.parentElement;
  svg.onmousemove = evt => {
    const pt = toSvgPoint(evt, svg);
    const i = locate(pt);
    if (i == null) { hideTooltip(tipEl); return; }
    const html = content(i, pt);
    if (!html) { hideTooltip(tipEl); return; }
    const rect = container.getBoundingClientRect();
    showTooltip(tipEl, container, evt.clientX - rect.left, evt.clientY - rect.top, html);
  };
  svg.onmouseleave = () => hideTooltip(tipEl);
}

/** Convert a mouse event to the SVG's own viewBox coordinate space, so hit
    testing works regardless of how the SVG is scaled by CSS (preserveAspectRatio
    is "none" on every chart in this file, so this is a simple linear map). */
function svgPoint(evt, svg) {
  const rect = svg.getBoundingClientRect();
  const vb = svg.viewBox.baseVal;
  const x = ((evt.clientX - rect.left) / rect.width) * vb.width + vb.x;
  const y = ((evt.clientY - rect.top) / rect.height) * vb.height + vb.y;
  return { x, y };
}

/* ── Chart registry ─────────────────────────────────────────────────────── */

export const charts = {

  /* KPI strip — one definition, both pages. Replaces the paired ov/an IDs. */
  kpis(el, d, { refs }) {
    const set = (node, text) => { if (node) node.textContent = text; };
    set(refs.alerts, fmt.int(d.kpis.totalAlerts));
    set(refs.assets, fmt.int(d.kpis.distinctAssets));
    set(refs.sync,   fmt.sync(d.kpis.avgSyncSeconds));
    set(refs.ratio,  fmt.pct(d.kpis.actionableRatio, 1));
  },

  /* Key Insights panel (Analytics) — 3-5 short bullets, each computed from
     real `derived` data. A bullet that can't be computed (no comparison
     period, no hourly data, etc.) is simply omitted — never a placeholder
     with a fabricated number. Every value here traces back to derived.*,
     nothing is hardcoded. */
  insights(el, d) {
    if (!el) return;
    const rows = [];
    const dot = color => `<span class="an-insight-dot" style="background:${color}"></span>`;

    // 1. Period-over-period volume change (derived.comparison) — the
    // PER-ASSET rate, not the raw alert count. Raw-count percent change has
    // no ceiling (a small previous-period total can make even a modest
    // absolute change read as a four-digit percent, same failure mode the
    // KPI cards' own comparison line was redesigned to avoid — see
    // dds-insights.js's kpiTile()). The rate cancels out fleet-size growth,
    // so "alerts per asset increased 40%" here means drivers actually got
    // worse, not that more vehicles started reporting. PCT_MIN_RATE_BASELINE
    // mirrors dds-state.js's PCT_MIN_BASELINE but scaled for a rate that's
    // typically single digits to tens, not hundreds.
    const PCT_MIN_RATE_BASELINE = 1;
    const cmp = d.comparison;
    const totalAlertsMetric = cmp?.available ? cmp.metrics.find(m => m.key === 'totalAlerts') : null;
    const perAssetRates = totalAlertsMetric?.perAsset;
    if (perAssetRates && perAssetRates.current != null && perAssetRates.previous != null
        && Math.abs(perAssetRates.previous) >= PCT_MIN_RATE_BASELINE) {
      const rateDelta = perAssetRates.current - perAssetRates.previous;
      const up = rateDelta > 0;
      const color = up ? 'var(--danger)' : 'var(--success)';
      const pct = Math.abs((rateDelta / Math.abs(perAssetRates.previous)) * 100);
      rows.push(`${dot(color)}<span>Alerts per asset ${up ? 'increased' : 'decreased'}
        <b>${pct.toFixed(0)}%</b> compared with the previous period
        (${esc(cmp.periods.previous)}).</span>`);
    }

    // 2. Night-shift share (derived.shiftDistribution).
    const { DAY, NIGHT } = d.shiftDistribution;
    const shiftTotal = DAY.units + NIGHT.units;
    if (shiftTotal > 0) {
      const dominant = NIGHT.pct >= DAY.pct ? { label: 'Night', pct: NIGHT.pct, color: 'var(--sev-elevated)' }
                                             : { label: 'Day', pct: DAY.pct, color: 'var(--blue)' };
      rows.push(`${dot(dominant.color)}<span>${esc(dominant.label)} shift accounts for
        <b>${dominant.pct.toFixed(0)}%</b> of total alerts.</span>`);
    }

    // 3. Peak hour window (derived.hourly) — single peak hour, UTC.
    const totalsByHour = d.hourly.DAY.map((v, i) => v + d.hourly.NIGHT[i]);
    const peakSum = totalsByHour.reduce((s, v) => s + v, 0);
    if (peakSum > 0) {
      const peakHour = totalsByHour.indexOf(Math.max(...totalsByHour));
      const hh = h => `${String(h).padStart(2, '0')}:00`;
      rows.push(`${dot('var(--purple)')}<span>Most alerts occur between
        <b>${hh(peakHour)}–${hh((peakHour + 1) % 24)}</b> UTC.</span>`);
    }

    // 4. Highest-volume unit (derived.topAssets).
    if (d.topAssets.length) {
      const top = d.topAssets[0];
      rows.push(`${dot('var(--blue)')}<span>Unit <b>${esc(top.id)}</b> recorded the highest
        alert volume (${fmt.int(top.total)} alerts).</span>`);
    }

    // 5. Sync delay — only worth a line if the worst bucket is non-trivial.
    const worst = d.syncBuckets.actionable.at(-1) + d.syncBuckets.nonActionable.at(-1);
    const syncTotal = d.syncBuckets.actionable.reduce((s, v) => s + v, 0) +
                       d.syncBuckets.nonActionable.reduce((s, v) => s + v, 0);
    if (syncTotal > 0 && worst / syncTotal >= 0.1) {
      rows.push(`${dot('var(--warning)')}<span><b>${fmt.int(worst)}</b> event(s)
        (${fmt.pct(worst / syncTotal * 100)}) took over 10 hours to sync — the longest delay bucket.</span>`);
    }

    // `el` is #anInsights, which already carries the .an-insights-list
    // layout class in markup — no extra wrapper needed here.
    el.innerHTML = rows.length
      ? rows.map(r => `<div class="an-insight-row">${r}</div>`).join('')
      : `<div class="an-insights-empty">Not enough data yet to compute insights.</div>`;
  },

  /* Shift split donut. `measure` resolves the Overview/Analytics conflict. */
  shiftDonut(el, d, { refs, measure = 'units' }) {
    const pick = s => measure === 'units' ? s.units : s.assets;
    const day = pick(d.shiftDistribution.DAY);
    const night = pick(d.shiftDistribution.NIGHT);
    const total = day + night;
    const unit = measure === 'units' ? 'events' : 'assets';

    donutSplit(refs.arc, refs.total, day, total);
    if (refs.dayValue)   refs.dayValue.textContent   = `${fmt.int(day)} ${unit}`;
    if (refs.nightValue) refs.nightValue.textContent = `${fmt.int(night)} ${unit}`;
    if (refs.dayPct)   refs.dayPct.textContent   = fmt.pct(total ? day / total * 100 : 0);
    if (refs.nightPct) refs.nightPct.textContent = fmt.pct(total ? night / total * 100 : 0);
  },

  /* Event codes — bar list (Overview) or severity donut+legend (Analytics).
     The donut variant colors by severityForCode() (known categories get a
     meaningful color; unknown codes fall back to the stable colorForCode()
     hash) rather than the arbitrary EVENT_COLORS hash used everywhere. */
  eventCodes(el, d, { variant = 'bars', refs, limit = 6, measure = 'units', tip } = {}) {
    const val = c => measure === 'units' ? c.units : c.events;
    const codes = d.eventCodeDistribution.slice(0, limit);

    if (variant === 'bars') {
      const total = codes.reduce((s, c) => s + val(c), 0);
      barList(el, codes.map(c => ({ label: c.code, value: val(c) })),
        { max: total, emptyText: 'No event codes' });
      return;
    }
    const segs = codes.map(c => ({ value: val(c), color: severityForCode(c.code).fg }));
    const total = donutSegments(refs.arcs, segs);
    if (refs.count) refs.count.textContent = codes.length;
    if (refs.legend) refs.legend.innerHTML = codes.map((c) => {
      const pct = total ? Math.round(val(c) / total * 100) : 0;
      return `<div class="dl-row">
        <span class="legend-dot" style="background:${severityForCode(c.code).fg}"></span>
        <div class="dl-name">${esc(c.code)}</div>
        <div class="dl-pct">${pct}%</div></div>`;
    }).join('');

    // Hover — per-arc tooltip. Wired once; harmless to re-wire on every
    // render since it's the same handful of listeners on the same node.
    if (tip && refs.arcs) {
      const arcEls = [...refs.arcs.querySelectorAll('circle')];
      arcEls.forEach((arcEl, i) => {
        const c = codes[i];
        if (!c) return;
        const pct = total ? Math.round(val(c) / total * 100) : 0;
        arcEl.style.pointerEvents = 'stroke';
        arcEl.addEventListener('mousemove', evt => {
          const container = refs.arcs.closest('.donut-wrap') || refs.arcs.closest('.chart-body');
          const rect = container.getBoundingClientRect();
          showTooltip(tip, container, evt.clientX - rect.left, evt.clientY - rect.top,
            tooltipHTML(c.code, [{ label: measure === 'units' ? 'Alerts' : 'Events', value: fmt.int(val(c)) },
                                  { label: 'Share', value: `${pct}%` }]));
        });
        arcEl.addEventListener('mouseleave', () => hideTooltip(tip));
      });
    }
  },

  /* Trend over time. `series` selects which lines to draw; the FIRST entry
     in `series` is treated as primary (drives the tooltip's lead value and
     the fill wash).
     NOTE ON SCALING (corrected 2026-08-28 — this comment previously said
     "every entry shares one scale," which was never true of the inlined
     index.html version of this function and is a real, deliberate
     dual-axis chart: Overview's "Alert Volume Over Time" plots Total
     Alerts and Distinct Assets each on ITS OWN min/max scale, with two
     tinted y-axes (#ovTrendYAxis / #ovTrendYAxisRight) — see index.html's
     renderer for the full per-series-scaling rationale (alert counts in
     the thousands vs. asset counts in the dozens can't share one axis
     without flattening the smaller series). This is a knowing exception to
     the dataviz skill's one-axis rule, not an oversight — flagged here so
     the two known divergences (this file trails index.html's inlined
     trend() on showPrev/per-series scaling/SERIES_COLOR) don't also carry
     a false claim about what the shipped chart does. This file (src/) is
     the older, simpler version — see README's src/ sync note. */
  trend(el, d, { refs, series = ['units'], geo = { top: 8, bottom: 168, width: 992 }, tip, insightEl } = {}) {
    const pts = d.trend;
    if (!pts.length) {
      if (refs.axis) refs.axis.innerHTML = '';
      if (insightEl) insightEl.textContent = '';
      if (refs.hover) refs.hover.innerHTML = '';
      return;
    }

    const paths = { units: refs.unitsPath, events: refs.eventsPath, assets: refs.assetsPath };
    const SERIES_LABEL = { units: 'Total Alerts', events: 'Events', assets: 'Distinct Assets' };
    const SERIES_COLOR = { units: 'var(--sev-elevated)', events: 'var(--sev-elevated)', assets: 'var(--purple)' };

    // Shared scale across series so the lines are visually comparable —
    // never a second y-axis (see module header).
    const all = series.flatMap(k => pts.map(p => p[k]));
    const min = Math.min(...all), max = Math.max(...all);

    let primary = null;
    for (const key of series) {
      const { d: path, points } = linePath(pts.map(p => p[key]), { ...geo, min, max });
      if (paths[key]) paths[key].setAttribute('d', path);
      if (!primary) primary = { path, points };
    }
    if (refs.fill && primary) {
      refs.fill.setAttribute('d', `${primary.path} ${geo.width},180 0,180 Z`);
    }
    // No per-point markers on the line itself — the hover crosshair below
    // already surfaces the exact value at any point, so a permanent row of
    // dots is redundant and clutters a smooth curve. refs.dots is left
    // unset intentionally; its host <g> stays empty.

    /* Sparse date axis: at most ~6 labels regardless of how many shift days
       are plotted, so 60 points don't collapse into unreadable overlap. */
    if (refs.axis) {
      const maxLabels = 6;
      const stride = Math.max(1, Math.ceil(pts.length / maxLabels));
      refs.axis.innerHTML = pts.map((p, i) => {
        const show = i === 0 || i === pts.length - 1 || i % stride === 0;
        return `<span class="axis">${show ? esc(fmt.shortDate(p.date)) : ''}</span>`;
      }).join('');
    }

    /* Data-derived insight — computed peak day for the primary series only.
       Omitted entirely (never a placeholder) when there's nothing to say. */
    if (insightEl) {
      const primaryKey = series[0];
      const peak = pts.reduce((a, b) => b[primaryKey] > a[primaryKey] ? b : a);
      insightEl.textContent = pts.length > 1
        ? `Peak: ${fmt.int(peak[primaryKey])} ${SERIES_LABEL[primaryKey].toLowerCase()} on ${fmt.shortDate(peak.date)}.`
        : '';
    }

    // Hover — vertical crosshair snapped to nearest point, one tooltip
    // listing every plotted series at that date (dataviz skill: "the
    // crosshair finds the X"; "one tooltip, every series").
    if (tip && refs.hover) {
      const xs = primary.points.map(p => p.x);
      refs.hover.innerHTML =
        `<line id="${el?.id ?? 'trend'}-crosshair" x1="0" y1="${geo.top}" x2="0" y2="${geo.bottom}"
           stroke="var(--border)" stroke-width="1" opacity="0" />`;
      const crosshair = refs.hover.firstElementChild;
      const svg = refs.unitsPath?.ownerSVGElement || refs.assetsPath?.ownerSVGElement;
      if (svg) {
        wireHover(svg, tip, {
          toSvgPoint: svgPoint,
          locate(pt) {
            let best = 0, bestDist = Infinity;
            xs.forEach((x, i) => { const dist = Math.abs(x - pt.x); if (dist < bestDist) { bestDist = dist; best = i; } });
            return best;
          },
          content(i) {
            const p = pts[i];
            crosshair.setAttribute('x1', xs[i].toFixed(1));
            crosshair.setAttribute('x2', xs[i].toFixed(1));
            crosshair.setAttribute('opacity', '1');
            return tooltipHTML(fmt.shortDate(p.date), series.map(key => ({
              label: SERIES_LABEL[key] ?? key, value: fmt.int(p[key]), color: SERIES_COLOR[key]
            })));
          }
        });
        // Chain onto the handler wireHover just assigned rather than adding
        // a second mouseleave listener (see wireHover's note on re-renders).
        const prevLeave = svg.onmouseleave;
        svg.onmouseleave = evt => { crosshair.setAttribute('opacity', '0'); prevLeave?.(evt); };
      }
    }
  },

  /* Hourly — single series (Overview bars) or DAY-vs-NIGHT lines (Analytics). */
  hourly(el, d, { variant = 'bars', refs, geo, tip } = {}) {
    if (variant === 'bars') {
      const totals = d.hourly.DAY.map((v, i) => v + d.hourly.NIGHT[i]);
      const peak = Math.max(...totals, 1);
      const g = geo ?? { barW: 28, gap: 42, baseline: 128, top: 5, offsetX: 4 };
      el.innerHTML = totals.map((v, h) => {
        const height = (v / peak) * (g.baseline - g.top);
        return `<rect x="${h * g.gap + g.offsetX}" y="${(g.baseline - height).toFixed(1)}"
                  width="${g.barW}" height="${height.toFixed(1)}" rx="2"/>`;
      }).join('');
      return;
    }
    /* Lines: DAY vs NIGHT on a shared scale.
       v2.2 split the date range into arbitrary early/late halves, which
       produced a different comparison every time a file was imported.
       DAY vs NIGHT is stable and matches the chart's title. Night uses the
       elevated/orange severity tone (not --amber) so it's unambiguous
       against the amber "caution" severity slot used elsewhere. */
    const g = geo ?? { top: 15, bottom: 210, width: 720 };
    const max = Math.max(...d.hourly.DAY, ...d.hourly.NIGHT, 1);
    const dayPts = linePath(d.hourly.DAY, { ...g, min: 0, max }).points;
    const nightPts = linePath(d.hourly.NIGHT, { ...g, min: 0, max }).points;
    if (refs.dayPath)   refs.dayPath.setAttribute('d',   linePath(d.hourly.DAY,   { ...g, min: 0, max }).d);
    if (refs.nightPath) refs.nightPath.setAttribute('d', linePath(d.hourly.NIGHT, { ...g, min: 0, max }).d);
    if (refs.legend) refs.legend.innerHTML =
      `<div class="legend-item"><span class="legend-dot" style="background:var(--blue)"></span>Day shift</div>
       <div class="legend-item"><span class="legend-dot" style="background:var(--sev-elevated)"></span>Night shift</div>`;

    // Hover — crosshair snapped to nearest hour, tooltip with both series + total.
    if (tip && refs.hover) {
      const svg = refs.dayPath?.ownerSVGElement || refs.nightPath?.ownerSVGElement;
      if (svg) {
        refs.hover.innerHTML = `<line x1="0" y1="${g.top}" x2="0" y2="${g.bottom}"
          stroke="var(--border)" stroke-width="1" opacity="0"/>`;
        const crosshair = refs.hover.firstElementChild;
        wireHover(svg, tip, {
          toSvgPoint: svgPoint,
          locate(pt) {
            let best = 0, bestDist = Infinity;
            dayPts.forEach((p, i) => { const dist = Math.abs(p.x - pt.x); if (dist < bestDist) { bestDist = dist; best = i; } });
            return best;
          },
          content(h) {
            crosshair.setAttribute('x1', dayPts[h].x.toFixed(1));
            crosshair.setAttribute('x2', dayPts[h].x.toFixed(1));
            crosshair.setAttribute('opacity', '1');
            const day = d.hourly.DAY[h], night = d.hourly.NIGHT[h];
            return tooltipHTML(`${String(h).padStart(2, '0')}:00 UTC`, [
              { label: 'Day shift', value: fmt.int(day), color: 'var(--blue)' },
              { label: 'Night shift', value: fmt.int(night), color: 'var(--sev-elevated)' },
              { label: 'Total', value: fmt.int(day + night) }
            ]);
          }
        });
        const prevLeave = svg.onmouseleave;
        svg.onmouseleave = evt => { crosshair.setAttribute('opacity', '0'); prevLeave?.(evt); };
      }
    }
  },

  syncBuckets(el, d, { geo }) {
    stackedBars(el, SYNC_BUCKETS, d.syncBuckets.actionable, d.syncBuckets.nonActionable,
      geo ?? { groupW: 130, gap: 184, baseline: 128, top: 10, offsetX: 46 });
  },

  /* Sync Interval Distribution — same SYNC_BUCKETS as syncBuckets, but as a
     single total-per-bucket bar rather than actionable/non-actionable
     stacks. This chart answers "how fast do syncs happen", where the
     actionable split is a distraction, not the point. The worst bucket
     (10h+ — the longest sync delay) is highlighted in the warning tone;
     every other bucket stays a single analytical blue, since only the
     worst bucket is actually actionable information. */
  syncInterval(el, d, { geo, tip, insightEl } = {}) {
    const g = geo ?? { barW: 34, gap: 60, baseline: 128, top: 10, offsetX: 13 };
    const totals = SYNC_BUCKETS.map((_, i) =>
      d.syncBuckets.actionable[i] + d.syncBuckets.nonActionable[i]);
    const peak = Math.max(...totals, 1);
    const worstIdx = SYNC_BUCKETS.length - 1;   // '10h+'
    const bars = totals.map((v, i) => {
      const height = (v / peak) * (g.baseline - g.top);
      const x = i * g.gap + g.offsetX, y = g.baseline - height;
      const fill = i === worstIdx && v > 0 ? 'var(--warning)' : 'var(--blue)';
      return { x, y, height, v, fill };
    });
    el.innerHTML = bars.map(b =>
      `<rect x="${b.x}" y="${b.y.toFixed(1)}" width="${g.barW}"
         height="${Math.max(b.height, 0).toFixed(1)}" fill="${b.fill}" rx="2"/>`).join('');

    /* Data-derived insight — only worth a line if the worst bucket (10h+,
       this app's slowest sync-delay bucket) is a non-trivial share of all
       synced events. Omitted (not a placeholder) when there's no data or
       the worst bucket is negligible. */
    if (insightEl) {
      const total = totals.reduce((s, v) => s + v, 0);
      const worstShare = total ? totals[worstIdx] / total : 0;
      insightEl.textContent = (total > 0 && worstShare >= 0.1)
        ? `${fmt.int(totals[worstIdx])} event(s) (${fmt.pct(worstShare * 100)}) took over 10 hours to sync.`
        : '';
    }

    if (tip) {
      const svg = el.ownerSVGElement || el.closest('svg');
      if (svg) {
        wireHover(svg, tip, {
          toSvgPoint: svgPoint,
          locate(pt) {
            const i = bars.findIndex(b => pt.x >= b.x - g.gap / 2 + g.barW / 2 && pt.x < b.x + g.gap / 2 + g.barW / 2);
            return i >= 0 ? i : null;
          },
          content(i) {
            const total = totals.reduce((s, v) => s + v, 0);
            const pct = total ? Math.round(totals[i] / total * 100) : 0;
            return tooltipHTML(SYNC_BUCKETS[i], [
              { label: 'Events', value: fmt.int(totals[i]), color: bars[i].fill },
              { label: 'Share', value: `${pct}%` }
            ], i === worstIdx ? 'Longest sync delay bucket' : null);
          }
        });
      }
    }
  },

  alertBuckets(el, d, { geo }) {
    stackedBars(el, ALERT_BUCKETS, d.alertBuckets.actionable, d.alertBuckets.nonActionable,
      geo ?? { groupW: 130, gap: 184, baseline: 128, top: 10, offsetX: 46 });
  },

  /* Alert Volume by Day of Week — same bar-geometry approach as
     syncInterval() above (computed rects, no scaled/stretched viewBox), just
     7 categories instead of 5. The single highest weekday is picked out in
     --navy so a scheduling pattern (e.g. weekend volume) reads at a glance;
     every other bar stays the neutral --blue-200 rather than a 7-step
     gradient, which would imply an ordering (least->most) the days don't
     actually have. */
  dayOfWeek(el, d, { geo, tip, insightEl } = {}) {
    const g = geo ?? { barW: 30, gap: 42, baseline: 128, top: 10, offsetX: 6 };
    const items = d.dayOfWeek ?? [];
    const peak = Math.max(...items.map(x => x.units), 1);
    const peakIdx = items.length
      ? items.reduce((best, x, i) => x.units > items[best].units ? i : best, 0)
      : -1;
    const bars = items.map((x, i) => {
      const height = (x.units / peak) * (g.baseline - g.top);
      const xPos = i * g.gap + g.offsetX, y = g.baseline - height;
      const fill = i === peakIdx && x.units > 0 ? 'var(--navy)' : 'var(--blue-200)';
      return { x: xPos, y, height, v: x.units, fill, day: x.day };
    });
    el.innerHTML = bars.map(b =>
      `<rect x="${b.x}" y="${b.y.toFixed(1)}" width="${g.barW}"
         height="${Math.max(b.height, 0).toFixed(1)}" fill="${b.fill}" rx="3"/>`).join('');

    /* Same "only worth a line if it's non-trivial" convention as
       syncInterval()'s insight — silent (not a placeholder) when volume is
       too flat across the week for a peak day to mean anything. */
    if (insightEl) {
      const total = items.reduce((s, x) => s + x.units, 0);
      const peakShare = total && peakIdx >= 0 ? items[peakIdx].units / total : 0;
      insightEl.textContent = (total > 0 && peakShare >= (1 / 7) * 1.3)
        ? `${items[peakIdx].day} concentrates ${fmt.pct(peakShare * 100)} of the week's volume.`
        : '';
    }

    if (tip) {
      const svg = el.ownerSVGElement || el.closest('svg');
      if (svg) {
        wireHover(svg, tip, {
          toSvgPoint: svgPoint,
          locate(pt) {
            const i = bars.findIndex(b => pt.x >= b.x - g.gap / 2 + g.barW / 2 && pt.x < b.x + g.gap / 2 + g.barW / 2);
            return i >= 0 ? i : null;
          },
          content(i) {
            const total = items.reduce((s, x) => s + x.units, 0);
            const pct = total ? Math.round(bars[i].v / total * 100) : 0;
            return tooltipHTML(bars[i].day, [
              { label: 'Alerts', value: fmt.int(bars[i].v), color: bars[i].fill },
              { label: 'Share of week', value: `${pct}%` }
            ], i === peakIdx ? 'Highest-volume day' : null);
          }
        });
      }
    }
  },

  /* Top Units by Alert Volume — ranked bar list, single consistent blue,
     top entry subtly highlighted via .ev-row[data-rank="1"] (see index.html
     CSS). Tooltip carries only what's actually derivable from topAssets:
     count and % of total — no fabricated "primary alert type" or "active
     days" field, since derive() doesn't produce those per-asset today. */
  topAssets(el, d, { limit = 10, showPct = true, tip } = {}) {
    const items = d.topAssets.slice(0, limit);
    const total = d.kpis.totalAlerts;
    barList(el, items.map(a => ({ label: a.id, value: a.total })),
      { showPct, emptyText: 'No assets in range' });
    [...el.querySelectorAll('.ev-row')].forEach((row, i) => {
      row.dataset.rank = String(i + 1);
      if (!tip) return;
      const a = items[i];
      const pct = total ? Math.round(a.total / total * 100) : 0;
      row.addEventListener('mousemove', evt => {
        const container = el.closest('.ev-list-wrap') || el.closest('.card') || el;
        const rect = container.getBoundingClientRect();
        showTooltip(tip, container, evt.clientX - rect.left, evt.clientY - rect.top,
          tooltipHTML(a.id, [
            { label: 'Alerts', value: fmt.int(a.total) },
            { label: 'Share of total', value: `${pct}%` }
          ]));
      });
      row.addEventListener('mouseleave', () => hideTooltip(tip));
    });
  },

  /* Operators with Highest Alert Volume — compact table (rank/operator/
     alerts/share). derived.topOperators is [{id, total}] only — no
     "primary alert type" or "last alert" field exists, so those columns
     are not shown rather than fabricated. */
  topOperators(el, d, { limit = 10 } = {}) {
    const items = d.topOperators.slice(0, limit);
    const total = d.kpis.totalAlerts;
    if (!items.length) {
      el.innerHTML = `<tr><td colspan="4"><div class="ev-empty">No operator data</div></td></tr>`;
      return;
    }
    el.innerHTML = items.map((o, i) => {
      const pct = total ? (o.total / total * 100) : 0;
      return `<tr>
        <td>${i + 1}</td>
        <td>${esc(o.id)}</td>
        <td>${fmt.int(o.total)}</td>
        <td>${fmt.pct(pct, 1)}</td>
      </tr>`;
    }).join('');
  },

  /* Raw-row log, newest first — see derive()'s recentAlerts in dds-state.js.
     Deliberately no status/acknowledgment column: the data model has no
     such field, and a decorative one would be indistinguishable from a
     real one to anyone reading the table. Event column now carries a
     severity badge (severityForCode) instead of plain text. */
  recentAlerts(el, d) {
    const rows = d.recentAlerts ?? [];
    if (!rows.length) {
      el.innerHTML = `<tr><td colspan="6"><div class="ev-empty">No alerts in range</div></td></tr>`;
      return;
    }
    el.innerHTML = rows.map(r => {
      const sev = severityForCode(r.eventCode);
      return `
      <tr>
        <td>${esc(fmt.dateTime(r.time))}</td>
        <td>${esc(r.operator)}</td>
        <td>${esc(r.asset)}</td>
        <td><span class="pill" style="background:${sev.bg};color:${sev.fg}">${esc(r.eventCode)}</span></td>
        <td>${r.shift === 'DAY' ? '<span class="pill" data-variant="info">Day Shift</span>'
              : r.shift === 'NIGHT' ? '<span class="pill" data-variant="warning">Night Shift</span>'
              : '<span class="pill" data-variant="neutral">—</span>'}</td>
        <td>${fmt.int(r.count)}</td>
      </tr>`;
    }).join('');
  }
};

/* ── Page configuration ─────────────────────────────────────────────────── */

const $ = id => document.getElementById(id);

/* Measure choice, made once, applied everywhere. Change `MEASURE` and both
   pages move together — which was the whole point of the merge. */
const MEASURE = 'units';

export const PAGES = {
  overview: [
    { chart: 'kpis', refs: () => ({
        alerts: $('ovKpiAlerts'), assets: $('ovKpiUnits'),
        sync: $('ovKpiSync'), ratio: $('ovKpiRatio') }) },
    { chart: 'shiftDonut', measure: MEASURE, refs: () => ({
        arc: $('shiftDonutArc'), total: $('shiftDonutTotal'),
        dayValue: $('shiftDayUnits'), dayPct: $('shiftDayPct'),
        nightValue: $('shiftNightUnits'), nightPct: $('shiftNightPct') }) },
    { chart: 'trend', series: ['units'], refs: () => ({
        unitsPath: $('trendLinePath'), fill: $('trendFillPath'),
        dots: $('trendDots'), axis: $('trendAxis'), badge: $('trendBadge') }) },
    { chart: 'hourly',        variant: 'bars', el: () => $('ovHourlyBars') },
    { chart: 'eventCodes',    variant: 'bars', measure: MEASURE, el: () => $('ovEventCodeList') },
    { chart: 'syncBuckets',   el: () => $('ovSyncBars') },
    { chart: 'alertBuckets',  el: () => $('ovBucketBars') },
    { chart: 'topAssets',     limit: 6, showPct: false, el: () => $('ovTopAssetList') }
  ],

  /* No 'kpis' or 'summary' entries here: the Analytics KPI strip is a
     period-comparison view (delta chips, sparkline, baseline note), not
     the plain label+value tiles that chart renders — renderAnalyticsKpis()
     (dds-insights.js) owns #anKpiRow and #anSummaryBody's old content is
     now folded into those tiles. See dds-insights.js for both.

     `tip`/`insightEl` are resolved once per render, same as `el`/`refs` —
     each points at the `.chart-tooltip`/`.chart-insight-line` node living
     in that chart's own `.chart-body` (see the ANALYTICS markup). */
  analytics: [
    { chart: 'trend', series: ['units', 'assets'], refs: () => ({
        unitsPath: $('anTrendAlertsPath'), assetsPath: $('anTrendAssetsPath'),
        fill: $('anTrendFillPath'), dots: $('anTrendDots'), axis: $('anTrendAxis'),
        hover: $('anTrendHover') }),
      tip: () => $('anTrendTooltip'), insightEl: () => $('anTrendInsight') },
    { chart: 'eventCodes', variant: 'donut', measure: MEASURE, refs: () => ({
        arcs: $('anEventDonutArcs'), count: $('anEventDonutCount'),
        legend: $('anEventDonutLegend') }),
      tip: () => $('anEventDonutTooltip') },
    { chart: 'hourly', variant: 'lines', refs: () => ({
        dayPath: $('anHourlyEarlyPath'), nightPath: $('anHourlyLatePath'),
        legend: $('anHourlyLegend'), hover: $('anHourlyHover') }),
      tip: () => $('anHourlyTooltip') },
    { chart: 'syncInterval', el: () => $('anSyncIntervalBars'),
      tip: () => $('anSyncIntervalTooltip'), insightEl: () => $('anSyncIntervalInsight') },
    { chart: 'shiftDonut', measure: MEASURE, refs: () => ({
        arc: $('anShiftDonutArc'), total: $('anShiftDonutTotal'),
        dayValue: $('anShiftDayAlerts'), dayPct: $('anShiftDayPct'),
        nightValue: $('anShiftNightAlerts'), nightPct: $('anShiftNightPct') }) },
    { chart: 'topAssets', limit: 8, showPct: true, el: () => $('anTopUnitsList'),
      tip: () => $('anTopUnitsTooltip') },
    { chart: 'topOperators', limit: 10, el: () => $('anTopOperatorList') },
    { chart: 'recentAlerts', el: () => $('anRecentAlertsBody') },
    { chart: 'insights', el: () => $('anInsights') }
  ]
};

/* ── Renderer ───────────────────────────────────────────────────────────── */

export function renderPage(pageName, derived) {
  const config = PAGES[pageName];
  if (!config || !derived) return;

  for (const { chart, el, refs, tip, insightEl, ...opts } of config) {
    const fn = charts[chart];
    if (!fn) { console.warn(`Unknown chart: ${chart}`); continue; }

    const node = el?.() ?? null;
    const resolved = refs?.() ?? {};
    const tipNode = tip?.() ?? null;
    const insightNode = insightEl?.() ?? null;
    // Skip cleanly if this page's markup isn't mounted.
    if (!node && !tipNode && !insightNode && !Object.values(resolved).some(Boolean)) continue;

    try {
      fn(node, derived, { ...opts, refs: resolved, tip: tipNode, insightEl: insightNode });
    } catch (err) {
      // One broken chart must not blank the whole dashboard.
      console.error(`Chart "${chart}" failed to render`, err);
    }
  }
}

/** Bind to the store: every state change repaints the active page. */
export function mount(store, getActivePage) {
  return store.subscribe(state => {
    const page = getActivePage();
    if (state.status === 'ready' && state.derived) renderPage(page, state.derived);
    document.body.dataset.status = state.status;   // hook for loading/error CSS
  });
}
