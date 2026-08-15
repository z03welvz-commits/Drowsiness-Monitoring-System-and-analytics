/* ============================================================================
   DDS — Accessibility Layer
   ----------------------------------------------------------------------------
   v2.2 audit: 0 aria-*, 0 role=, 0 tabindex, 0 alt= across 58 inline SVGs and
   19 buttons. 7 icon-only buttons had no accessible name. 4 of 10 inputs had
   no associated label. No <main>, no <h1> — headings started at h2.

   Two halves:
     applyStatic()  — one-time markup fixes (landmarks, labels, icon naming)
     describeChart()— data-driven titles + sr-only tables, refreshed on render

   The second half is why this is JS and not markup: a chart description that
   says "Trend over time" is useless. One that says "Alert trend across 14
   days, peaking at 412 on Mar 18" is the actual content, and it changes every
   time the data does.
   ========================================================================= */

import { fmt } from './dds-charts.js';

const esc = s => String(s ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ── Live region ────────────────────────────────────────────────────────── */

let liveRegion = null;

/** Announce to screen readers without moving focus. */
export function announce(message, { assertive = false } = {}) {
  if (!liveRegion) return;
  liveRegion.setAttribute('aria-live', assertive ? 'assertive' : 'polite');
  // Clear first — identical consecutive text is not re-announced.
  liveRegion.textContent = '';
  setTimeout(() => { liveRegion.textContent = message; }, 50);
}

/* ── Static markup fixes ────────────────────────────────────────────────── */

const ICON_LABELS = {
  'sound-preview-btn': 'Preview notification sound',
  'edit':       'Edit user',
  'deactivate': 'Deactivate user',
  'activate':   'Activate user'
};

export function applyStatic(root = document) {
  /* 1. Decorative icons — 16x16 and 24x24 SVGs always sit beside a text
        label. Announcing them duplicates the label, so hide them. Charts
        (larger viewBoxes) are handled by describeChart() instead. */
  root.querySelectorAll('svg').forEach(svg => {
    const vb = (svg.getAttribute('viewBox') || '').split(/\s+/);
    const w = parseFloat(vb[2]) || 0;
    if (svg.dataset.chart) return;                 // meaningful — skip
    if (w <= 24) {
      svg.setAttribute('aria-hidden', 'true');
      svg.setAttribute('focusable', 'false');      // IE/Edge tab-stop fix
    }
  });

  /* 2. Icon-only buttons — 7 of them had no accessible name at all.
        Prefer an explicit data-label; fall back to the class map. */
  root.querySelectorAll('button').forEach(btn => {
    if (btn.getAttribute('aria-label') || btn.textContent.trim()) return;
    const explicit = btn.dataset.label;
    const byClass = [...btn.classList].map(c => ICON_LABELS[c]).find(Boolean);
    const action = btn.dataset.action ? ICON_LABELS[btn.dataset.action] : null;
    const subject = btn.dataset.subject ? ` ${btn.dataset.subject}` : '';
    const label = explicit || (action ? action + subject : byClass);
    if (label) btn.setAttribute('aria-label', label);
    else console.warn('Icon button with no accessible name', btn);
  });

  /* 3. Landmarks + document outline. */
  const shell = root.querySelector('.app');
  const nav = root.querySelector('.sidenav');
  const main = root.querySelector('#main');
  if (nav && !nav.getAttribute('aria-label')) {
    nav.setAttribute('role', 'navigation');
    nav.setAttribute('aria-label', 'Sections');
  }
  if (main) { main.setAttribute('role', 'main'); main.id = 'main'; main.tabIndex = -1; }

  /* The brand title is the only h1-worthy string; headings jumped straight
     to h2, which leaves screen-reader users without a document title. */
  const brand = root.querySelector('.nav-brand-title');
  if (brand && brand.tagName !== 'H1') {
    const h1 = document.createElement('h1');
    h1.className = brand.className;
    h1.textContent = brand.textContent;
    brand.replaceWith(h1);
  }

  /* 4. Skip link — first thing in the tab order. */
  if (shell && !root.querySelector('.skip-link')) {
    const skip = document.createElement('a');
    skip.className = 'skip-link';
    skip.href = '#main';
    skip.textContent = 'Skip to main content';
    shell.parentNode.insertBefore(skip, shell);
  }

  /* 5. Inputs without a label — 4 of 10 in v2.2. Wire by proximity, and
        warn loudly for any that can't be resolved. */
  root.querySelectorAll('input, select').forEach(input => {
    if (input.type === 'hidden') return;
    const hasLabel = input.id && root.querySelector(`label[for="${CSS.escape(input.id)}"]`);
    if (hasLabel || input.getAttribute('aria-label')) return;
    const near = input.closest('.field-group, .sound-row, .field-row')
      ?.querySelector('.field-label, .sound-row-label');
    if (near) {
      if (!input.id) input.id = `f-${Math.random().toString(36).slice(2, 8)}`;
      near.setAttribute('for', input.id);
      if (near.tagName !== 'LABEL') input.setAttribute('aria-label', near.textContent.trim());
    } else {
      console.warn('Input with no accessible name', input);
    }
    /* Hint text becomes the description rather than floating unread. */
    const hint = input.closest('.field-group')?.querySelector('.field-hint');
    if (hint) {
      if (!hint.id) hint.id = `${input.id}-hint`;
      input.setAttribute('aria-describedby', hint.id);
    }
  });

  /* 6. Nav as a tab set, so arrow keys work and the current page is announced. */
  const items = [...root.querySelectorAll('.nav-item')];
  items.forEach(item => {
    item.setAttribute('role', 'tab');
    item.setAttribute('aria-selected', String(item.classList.contains('active')));
    item.tabIndex = item.classList.contains('active') ? 0 : -1;
  });
  const list = items[0]?.parentElement;
  if (list) list.setAttribute('role', 'tablist');

  list?.addEventListener('keydown', e => {
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) return;
    e.preventDefault();
    const i = items.indexOf(document.activeElement);
    const next = e.key === 'Home' ? 0
      : e.key === 'End' ? items.length - 1
      : e.key === 'ArrowDown' ? (i + 1) % items.length
      : (i - 1 + items.length) % items.length;
    items[next]?.focus();
  });

  /* 7. Live region. */
  if (!liveRegion) {
    liveRegion = document.createElement('div');
    liveRegion.className = 'sr-only';
    liveRegion.setAttribute('aria-live', 'polite');
    liveRegion.setAttribute('aria-atomic', 'true');
    document.body.appendChild(liveRegion);
  }

  /* 8. Pages as tabpanels. */
  root.querySelectorAll('section[id]').forEach(sec => {
    sec.setAttribute('role', 'tabpanel');
    sec.tabIndex = 0;
    if (!sec.getAttribute('aria-label')) {
      const title = sec.querySelector('.topbar-title')?.textContent?.trim();
      if (title) sec.setAttribute('aria-label', title);
    }
  });
}

/** Keep aria-selected in sync with showPage(). */
export function setActivePage(pageId, root = document) {
  root.querySelectorAll('.nav-item').forEach(item => {
    const on = item.classList.contains('active');
    item.setAttribute('aria-selected', String(on));
    item.tabIndex = on ? 0 : -1;
  });
  const label = root.querySelector(`#${CSS.escape(pageId)}`)?.getAttribute('aria-label');
  if (label) announce(`${label} view`);
}

/* ── Chart descriptions (data-driven) ───────────────────────────────────── */

const table = (caption, headers, rows) => `
  <table>
    <caption>${esc(caption)}</caption>
    <thead><tr>${headers.map(h => `<th scope="col">${esc(h)}</th>`).join('')}</tr></thead>
    <tbody>${rows.map(r => `<tr>${r.map((c, i) =>
      i === 0 ? `<th scope="row">${esc(c)}</th>` : `<td>${esc(c)}</td>`).join('')}</tr>`).join('')}
    </tbody>
  </table>`;

/** Returns { title, desc, table } for a chart, computed from live data. */
export const describe = {
  trend(d) {
    const pts = d.trend;
    if (!pts.length) return { title: 'Alert volume over time', desc: 'No data in range.' };
    const peak = pts.reduce((a, b) => b.units > a.units ? b : a);
    const low  = pts.reduce((a, b) => b.units < a.units ? b : a);
    return {
      title: 'Alert volume over time',
      desc: `Alert volume across ${pts.length} shift days, from ` +
            `${fmt.shortDate(pts[0].date)} to ${fmt.shortDate(pts.at(-1).date)}. ` +
            `Highest ${fmt.int(peak.units)} on ${fmt.shortDate(peak.date)}; ` +
            `lowest ${fmt.int(low.units)} on ${fmt.shortDate(low.date)}.`,
      table: table('Alerts by shift date', ['Date', 'Alerts', 'Events', 'Assets'],
        pts.map(p => [fmt.shortDate(p.date), fmt.int(p.units), fmt.int(p.events), fmt.int(p.assets)]))
    };
  },

  shiftDonut(d) {
    const { DAY, NIGHT } = d.shiftDistribution;
    return {
      title: 'Distribution by shift',
      desc: `Day shift ${fmt.pct(DAY.pct)} with ${fmt.int(DAY.units)} alerts; ` +
            `night shift ${fmt.pct(NIGHT.pct)} with ${fmt.int(NIGHT.units)} alerts.`,
      table: table('Alerts by shift', ['Shift', 'Alerts', 'Assets', 'Share'], [
        ['Day', fmt.int(DAY.units), fmt.int(DAY.assets), fmt.pct(DAY.pct)],
        ['Night', fmt.int(NIGHT.units), fmt.int(NIGHT.assets), fmt.pct(NIGHT.pct)]
      ])
    };
  },

  eventCodes(d) {
    const codes = d.eventCodeDistribution;
    if (!codes.length) return { title: 'Event severity distribution', desc: 'No event codes.' };
    return {
      title: 'Event severity distribution',
      desc: `${codes.length} event types. Most common is ${codes[0].code} at ` +
            `${fmt.pct(codes[0].pct)} of ${fmt.int(d.kpis.totalAlerts)} alerts.`,
      table: table('Alerts by event code', ['Code', 'Alerts', 'Events', 'Share'],
        codes.map(c => [c.code, fmt.int(c.units), fmt.int(c.events), fmt.pct(c.pct)]))
    };
  },

  hourly(d) {
    const totals = d.hourly.DAY.map((v, i) => v + d.hourly.NIGHT[i]);
    const peakHour = totals.indexOf(Math.max(...totals));
    const hh = h => `${String(h).padStart(2, '0')}:00`;
    return {
      title: 'Alert activity by hour',
      desc: `Alerts by hour of day, UTC. Peak at ${hh(peakHour)} with ` +
            `${fmt.int(totals[peakHour])} alerts.`,
      table: table('Alerts by hour', ['Hour (UTC)', 'Day shift', 'Night shift', 'Total'],
        totals.map((t, h) => [hh(h), fmt.int(d.hourly.DAY[h]), fmt.int(d.hourly.NIGHT[h]), fmt.int(t)]))
    };
  },

  syncBuckets(d) {
    const b = d.syncBuckets;
    return {
      title: 'Alert sync delay distribution',
      desc: `Events grouped by delay between event end and server sync, ` +
            `split by actionable status.`,
      table: table('Sync delay buckets', ['Delay', 'Actionable', 'Non-actionable'],
        b.labels.map((l, i) => [l, fmt.int(b.actionable[i]), fmt.int(b.nonActionable[i])]))
    };
  },

  alertBuckets(d) {
    const b = d.alertBuckets;
    return {
      title: 'Alert count distribution',
      desc: `Events grouped by alert count per record, split by actionable status.`,
      table: table('Alert count buckets', ['Alerts per event', 'Actionable', 'Non-actionable'],
        b.labels.map((l, i) => [l, fmt.int(b.actionable[i]), fmt.int(b.nonActionable[i])]))
    };
  },

  topAssets(d) {
    const t = d.topAssets;
    if (!t.length) return { title: 'Top units by alert volume', desc: 'No asset data.' };
    return {
      title: 'Top units by alert volume',
      desc: `${t.length} units ranked by alert volume. Highest is ${t[0].id} ` +
            `with ${fmt.int(t[0].total)} alerts.`,
      table: table('Alerts by unit', ['Unit', 'Total', 'Actionable', 'Non-actionable'],
        t.map(a => [a.id, fmt.int(a.total), fmt.int(a.actionable), fmt.int(a.nonActionable)]))
    };
  },

  syncInterval(d) {
    const b = d.syncBuckets;
    const totals = b.labels.map((_, i) => b.actionable[i] + b.nonActionable[i]);
    const peakI = totals.indexOf(Math.max(...totals));
    return {
      title: 'Sync interval distribution',
      desc: `Events grouped by delay between event end and server sync. ` +
            `Most common interval is ${b.labels[peakI]} with ${fmt.int(totals[peakI])} events.`,
      table: table('Sync interval buckets', ['Delay', 'Events'],
        b.labels.map((l, i) => [l, fmt.int(totals[i])]))
    };
  },

  /* No `table` field: this node is now a real <table> (rank/operator/
     alerts/share) with proper <thead>/<th> markup, same reasoning as
     recentAlerts below — a screen reader can navigate it directly, so a
     second sr-only table would be a redundant duplicate. */
  topOperators(d) {
    const t = d.topOperators;
    if (!t.length) return { title: 'Operators with highest alert volume', desc: 'No operator data.' };
    return {
      title: 'Operators with highest alert volume',
      desc: `${t.length} operators ranked by alert volume. Highest is ${t[0].id} ` +
            `with ${fmt.int(t[0].total)} alerts.`
    };
  },

  /* No `table` field: unlike the SVG charts above, this node IS already a
     real <table> with proper <thead>/<th> markup — a screen reader can
     navigate it directly. A second sr-only table here would be a
     redundant duplicate, not an accessibility gap to fill. This entry
     only exists to give the section a spoken landmark name. */
  recentAlerts(d) {
    const n = d.recentAlerts?.length ?? 0;
    return {
      title: 'Recent alerts',
      desc: n ? `${n} most recent alert records, newest first.` : 'No alerts in range.'
    };
  },

  kpis(d) {
    return {
      title: 'Key metrics',
      desc: `${fmt.int(d.kpis.totalAlerts)} total alerts across ` +
            `${fmt.int(d.kpis.distinctAssets)} assets. Average sync ` +
            `${fmt.sync(d.kpis.avgSyncSeconds)}. Actionable ratio ` +
            `${fmt.pct(d.kpis.actionableRatio, 1)}.`
    };
  },

  /* No `table` field: the Key Insights panel is already plain-text prose
     (each bullet is a full sentence, not a chart needing a numeric table
     alongside it) — this entry gives the section a spoken landmark name
     and description so a screen reader user knows what the region is
     before reading its (already-accessible) text content. */
  insights(d) {
    return {
      title: 'Key insights',
      desc: 'Short, data-derived summary points about current fleet alert activity.'
    };
  }
};

/* ── Wiring ─────────────────────────────────────────────────────────────── */

/**
 * Attach descriptions to every chart on a page.
 * Markup contract: the SVG carries data-chart="<key>"; the sr-only table is
 * injected as a sibling so it sits in reading order right after the visual.
 */
export function describePage(pageName, derived, root = document) {
  if (!derived) return;

  root.querySelectorAll('[data-chart]').forEach(node => {
    const key = node.dataset.chart;
    const build = describe[key];
    if (!build) return;

    let info;
    try { info = build(derived); }
    catch (err) { console.error(`Description failed for "${key}"`, err); return; }

    if (node.tagName.toLowerCase() === 'svg') {
      node.setAttribute('role', 'img');
      node.removeAttribute('aria-hidden');

      // <title> and <desc> must be the FIRST children to be picked up.
      let titleEl = node.querySelector(':scope > title');
      let descEl  = node.querySelector(':scope > desc');
      if (!titleEl) {
        titleEl = document.createElementNS('http://www.w3.org/2000/svg', 'title');
        node.prepend(titleEl);
      }
      if (!descEl) {
        descEl = document.createElementNS('http://www.w3.org/2000/svg', 'desc');
        titleEl.after(descEl);
      }
      titleEl.textContent = info.title;
      descEl.textContent = info.desc || '';
    } else {
      node.setAttribute('role', 'group');
      node.setAttribute('aria-label', `${info.title}. ${info.desc || ''}`);
    }

    /* Screen-reader data table — the numbers behind the picture. Sighted
       users never see it; it is the only way the chart data is reachable. */
    if (info.table) {
      const host = node.closest('.card') || node.parentElement;
      let tbl = host.querySelector(':scope > .sr-only[data-chart-table]');
      if (!tbl) {
        tbl = document.createElement('div');
        tbl.className = 'sr-only';
        tbl.setAttribute('data-chart-table', key);
        host.appendChild(tbl);
      }
      tbl.innerHTML = info.table;
    }
  });
}

/** One call to wire everything. Returns the store unsubscribe fn. */
export function initA11y(store, getActivePage) {
  applyStatic();
  let lastStatus = null;

  return store.subscribe(state => {
    if (state.status === 'ready' && state.derived) {
      describePage(getActivePage(), state.derived);
      if (lastStatus === 'loading') {
        const { meta, kpis } = state.derived;
        announce(`Loaded ${fmt.int(meta.rowCount)} records, ` +
                 `${fmt.int(kpis.totalAlerts)} alerts.` +
                 (meta.reconciles ? '' :
                  ` Warning: ${fmt.int(meta.unclassifiedRows)} rows had unreadable timestamps.`));
      }
    }
    if (state.status === 'loading' && lastStatus !== 'loading') announce('Loading data');
    if (state.status === 'error') announce(state.error?.message || 'Error loading data',
                                           { assertive: true });
    lastStatus = state.status;
  });
}
