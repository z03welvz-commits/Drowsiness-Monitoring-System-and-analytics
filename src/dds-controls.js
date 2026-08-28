/* ============================================================================
   DDS — Controls Layer
   ----------------------------------------------------------------------------
   Turns the dead UI into working UI.

   v2.2 audit findings this addresses:
     - 3 filter "controls" (.cpill) were <div>s with a chevron icon implying a
       dropdown that did not exist. Not focusable, not clickable, no menu.
     - Refresh had no handler.
     - Export had no handler.
     - KPIs were hardcoded in markup (4,200 / 284 / 4.3 sec / 72.8%), so a
       first-time user saw confident fake numbers before importing anything.

   Everything here drives store.setFilters() — the same path the charts already
   subscribe to — so filtering is a state change, not a DOM operation.
   ========================================================================= */

import { fmt } from './dds-charts.js';
import { announce } from './dds-a11y.js';

/* ── CSV export ─────────────────────────────────────────────────────────── */

/* A cell beginning with = + - @ (or tab/CR) is executed as a formula when the
   CSV is opened in Excel or Sheets. ASSET_ID and OPERATOR come from an
   uploaded file, so an attacker controls them — prefix to neutralise.
   Quotes are doubled per RFC 4180. */
function csvCell(value) {
  let s = String(value ?? '');
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

const csv = rows => rows.map(r => r.map(csvCell).join(',')).join('\r\n');

function download(filename, text, mime = 'text/csv;charset=utf-8') {
  // BOM so Excel reads UTF-8 asset/operator names correctly.
  const blob = new Blob(['\uFEFF' + text], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = Object.assign(document.createElement('a'), { href: url, download: filename });
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}

/** Build a multi-section CSV of everything currently on screen. */
export function exportDerived(derived, filters) {
  const out = [];
  const section = (title, headers, rows) => {
    out.push([title], headers, ...rows, []);
  };

  out.push(['DDS Export'], ['Generated', derived.meta.generatedAt],
           ['Rows', derived.meta.rowCount]);
  if (filters?.from || filters?.to) out.push(['Range', `${filters.from ?? 'start'} to ${filters.to ?? 'end'}`]);
  if (filters?.shift) out.push(['Shift', filters.shift]);
  if (!derived.meta.reconciles) {
    out.push(['WARNING', `${derived.meta.unclassifiedRows} row(s) had unreadable ` +
      `timestamps; their ${derived.meta.unclassifiedUnits} alerts are in totals ` +
      `but excluded from trend and shift figures.`]);
  }
  out.push([]);

  section('KEY METRICS', ['Metric', 'Value'], [
    ['Total alerts', derived.kpis.totalAlerts],
    ['Distinct assets', derived.kpis.distinctAssets],
    ['Avg sync', fmt.sync(derived.kpis.avgSyncSeconds)],
    ['Actionable ratio', fmt.pct(derived.kpis.actionableRatio, 1)]
  ]);

  section('TREND BY SHIFT DATE', ['Date', 'Alerts', 'Events', 'Assets'],
    derived.trend.map(t => [t.date, t.units, t.events, t.assets]));

  section('BY SHIFT', ['Shift', 'Alerts', 'Assets', 'Share %'], [
    ['Day', derived.shiftDistribution.DAY.units, derived.shiftDistribution.DAY.assets,
     derived.shiftDistribution.DAY.pct.toFixed(1)],
    ['Night', derived.shiftDistribution.NIGHT.units, derived.shiftDistribution.NIGHT.assets,
     derived.shiftDistribution.NIGHT.pct.toFixed(1)]
  ]);

  section('BY EVENT CODE', ['Code', 'Alerts', 'Events', 'Share %'],
    derived.eventCodeDistribution.map(c => [c.code, c.units, c.events, c.pct.toFixed(1)]));

  section('BY HOUR (UTC)', ['Hour', 'Day shift', 'Night shift'],
    derived.hourly.DAY.map((v, h) => [`${String(h).padStart(2, '0')}:00`, v, derived.hourly.NIGHT[h]]));

  section('TOP ASSETS', ['Asset', 'Total', 'Actionable', 'Non-actionable'],
    derived.topAssets.map(a => [a.id, a.total, a.actionable, a.nonActionable]));

  section('TOP OPERATORS', ['Operator', 'Total'],
    derived.topOperators.map(o => [o.id, o.total]));

  const stamp = new Date().toISOString().slice(0, 10);
  download(`dds-export-${stamp}.csv`, csv(out));
  return out.length;
}

/* ── Accessible dropdown ────────────────────────────────────────────────── */

/* The .cpill elements were <div>s — no keyboard access, no role, no menu.
   This upgrades them in place to the WAI-ARIA listbox pattern: button with
   aria-haspopup, popup with role=listbox, arrow keys, Home/End, Escape,
   type-ahead, and click-outside dismissal. */

let openMenu = null;

function closeMenu() {
  if (!openMenu) return;
  openMenu.trigger.setAttribute('aria-expanded', 'false');
  openMenu.list.remove();
  openMenu = null;
}

document.addEventListener('click', e => {
  if (openMenu && !openMenu.list.contains(e.target) && !openMenu.trigger.contains(e.target)) {
    closeMenu();
  }
});
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && openMenu) { openMenu.trigger.focus(); closeMenu(); }
});

/**
 * @param {Element} el       the existing .cpill node
 * @param {object}  config   { label, options:[{value,label}], value, onSelect }
 */
export function createDropdown(el, { label, options, value, onSelect }) {
  // Swap the <div> for a real <button> so it is focusable and announced.
  const trigger = document.createElement('button');
  trigger.className = el.className;
  trigger.type = 'button';
  trigger.setAttribute('aria-haspopup', 'listbox');
  trigger.setAttribute('aria-expanded', 'false');
  trigger.setAttribute('aria-label', label);
  el.replaceWith(trigger);

  let current = value;

  const paint = () => {
    const opt = options.find(o => o.value === current) ?? options[0];
    trigger.innerHTML = '';
    trigger.append(opt.label);
    const chev = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    chev.setAttribute('viewBox', '0 0 24 24');
    chev.setAttribute('fill', 'none');
    chev.setAttribute('stroke', 'currentColor');
    chev.setAttribute('stroke-width', '2.5');
    chev.setAttribute('aria-hidden', 'true');
    chev.setAttribute('focusable', 'false');
    chev.innerHTML = '<path d="M6 9l6 6 6-6"/>';
    trigger.append(chev);
    trigger.dataset.active = String(current !== options[0].value);
  };

  const open = () => {
    if (openMenu?.trigger === trigger) return closeMenu();
    closeMenu();

    const list = document.createElement('div');
    list.className = 'menu';
    list.setAttribute('role', 'listbox');
    list.setAttribute('aria-label', label);
    list.tabIndex = -1;

    options.forEach(o => {
      const item = document.createElement('div');
      item.className = 'menu-item';
      item.setAttribute('role', 'option');
      item.setAttribute('aria-selected', String(o.value === current));
      item.tabIndex = -1;
      item.textContent = o.label;
      item.addEventListener('click', () => {
        current = o.value;
        paint();
        closeMenu();
        trigger.focus();
        onSelect(o.value);
      });
      list.append(item);
    });

    trigger.parentElement.style.position ||= 'relative';
    trigger.insertAdjacentElement('afterend', list);
    trigger.setAttribute('aria-expanded', 'true');
    openMenu = { trigger, list };

    const items = [...list.children];
    (items.find(i => i.getAttribute('aria-selected') === 'true') ?? items[0])?.focus();

    list.addEventListener('keydown', e => {
      const i = items.indexOf(document.activeElement);
      const go = n => { e.preventDefault(); items[n]?.focus(); };
      if (e.key === 'ArrowDown') go((i + 1) % items.length);
      else if (e.key === 'ArrowUp') go((i - 1 + items.length) % items.length);
      else if (e.key === 'Home') go(0);
      else if (e.key === 'End') go(items.length - 1);
      else if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); document.activeElement.click(); }
      else if (e.key === 'Tab') closeMenu();
    });
  };

  trigger.addEventListener('click', open);
  trigger.addEventListener('keydown', e => {
    if (e.key === 'ArrowDown' || e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(); }
  });

  paint();
  return { setValue(v) { current = v; paint(); }, element: trigger };
}

/* ── Filter option builders ─────────────────────────────────────────────── */

/* filters.from/to are 'MM/DD/YYYY' (see dds-state.js SHIFT_DATE), but
   <input type="date"> reads/writes 'YYYY-MM-DD' — convert at the edges so
   the store never sees the input's native format. */
function dateInputToFilter(v) {
  if (!v) return null;
  const [y, m, d] = v.split('-');
  return `${m}/${d}/${y}`;
}

export const SHIFT_OPTIONS = [
  { value: 'all',   label: 'All shifts' },
  { value: 'DAY',   label: 'Day shift' },
  { value: 'NIGHT', label: 'Night shift' }
];

export const STATUS_OPTIONS = [
  { value: 'all',        label: 'All records' },
  { value: 'actionable', label: 'Actionable only' }
];

/* ── Empty state ────────────────────────────────────────────────────────── */

/* The hardcoded KPIs were the single most misleading thing in the mock: a user
   who had imported nothing still saw "4,200 alerts / 72.8% actionable".

   The static markup also ships every chart pre-drawn with sample squiggles
   baked into `d`/`cx`/`cy` attributes — that's how the mock looked good as a
   screenshot before any rendering code existed. Adding a "No data yet"
   message next to that art is not enough: the message and the fake curve
   both sit in the same .chart-body, so a real user sees a confident-looking
   trend line *and* a caption disputing it. The shapes underneath must be
   hidden, not just captioned over. */
const CHART_SHAPE_SELECTOR = 'svg[data-chart] path, svg[data-chart] circle, svg[data-chart] rect';

export function renderEmptyState(root = document) {
  root.querySelectorAll('.kpi-val').forEach(el => { el.textContent = '—'; });
  root.querySelectorAll('.kpi-delta').forEach(el => { el.hidden = true; });

  // Hide the placeholder art. visibility (not display/removal) so the SVG's
  // own layout — viewBox, axis lines — stays intact for when data arrives;
  // only the drawn sample values disappear.
  root.querySelectorAll(CHART_SHAPE_SELECTOR).forEach(el => {
    el.dataset.emptyHidden = 'true';
    el.style.visibility = 'hidden';
  });

  root.querySelectorAll('.chart-body, .ev-list').forEach(el => {
    if (el.querySelector('.state-empty')) return;
    el.insertAdjacentHTML('beforeend', `
      <div class="state-empty">
        <div class="state-empty-title">No data yet</div>
        <div>Import a CSV or Excel export to populate this view.</div>
      </div>`);
  });
}

function clearEmptyState(root = document) {
  root.querySelectorAll('.state-empty').forEach(el => el.remove());
  root.querySelectorAll('.kpi-delta').forEach(el => { el.hidden = false; });

  // Un-hide so real rendering can draw into these elements again. The chart
  // renderer overwrites `d`/`cx`/`cy` with real values on the very next
  // paint, so this never re-exposes the placeholder art — only the frame.
  root.querySelectorAll('[data-empty-hidden="true"]').forEach(el => {
    el.style.visibility = '';
    delete el.dataset.emptyHidden;
  });
}

/* ── Wiring ─────────────────────────────────────────────────────────────── */

/**
 * @param {object} store          from dds-state.js
 * @param {object} handlers       { onRefresh?: () => Promise|void }
 */
export function initControls(store, { onRefresh } = {}) {
  const state = store.get();

  /* Date range — real From/To <input type="date"> fields (Overview's
     #ovDateFrom/#ovDateTo, Analytics' #anDateFrom/#anDateTo), same pattern
     as Alert Logs' #alDateFrom/#alDateTo. Replaced the old preset dropdown
     (Today/Last 7/14/30 shift days) so any single day or custom range is
     directly pickable instead of only four canned windows. */
  document.querySelectorAll('.al-date-range').forEach(range => {
    const fromInput = range.querySelector('input[id$="DateFrom"]');
    const toInput = range.querySelector('input[id$="DateTo"]');
    if (!fromInput || !toInput) return;

    fromInput.addEventListener('change', () => {
      store.setFilters({ from: dateInputToFilter(fromInput.value) });
      announce(fromInput.value ? `From date: ${fromInput.value}` : 'From date cleared');
    });
    toInput.addEventListener('change', () => {
      store.setFilters({ to: dateInputToFilter(toInput.value) });
      announce(toInput.value ? `To date: ${toInput.value}` : 'To date cleared');
    });
  });

  /* Filter pills. Each .cpill is matched by its text so this works against the
     existing markup without an edit; give them data-filter="shift|status"
     to be explicit. */
  document.querySelectorAll('.cpill').forEach(el => {
    if (el.id === 'importedCountPill') return;          // a count, not a control
    const text = el.textContent.trim().toLowerCase();
    const kind = el.dataset.filter
      ?? (text.includes('shift') ? 'shift'
        : text.includes('area') ? 'area'
        : null);

    if (kind === 'shift') {
      createDropdown(el, {
        label: 'Shift', value: 'all', options: SHIFT_OPTIONS,
        onSelect: v => {
          store.setFilters({ shift: v === 'all' ? null : v });
          announce(`Shift filter: ${v === 'all' ? 'all shifts' : v.toLowerCase()}`);
        }
      });
    } else if (kind === 'area') {
      /* v2.2 showed an "All Areas" filter, but no column in EXPECTED_COLUMNS
         carries an area/site. Repurposed to a status filter, which the data
         does support. Restore it as an area filter once the schema has a
         site column — see the API contract. */
      createDropdown(el, {
        label: 'Record status', value: 'all', options: STATUS_OPTIONS,
        onSelect: v => {
          store.setFilters({ actionableOnly: v === 'actionable' });
          announce(v === 'actionable' ? 'Showing actionable only' : 'Showing all records');
        }
      });
    }
  });

  /* Refresh — was inert. */
  document.querySelectorAll('button').forEach(btn => {
    const label = btn.textContent.trim();

    if (label === 'Refresh') {
      btn.addEventListener('click', async () => {
        btn.dataset.loading = 'true';
        btn.disabled = true;
        try {
          await (onRefresh ? onRefresh() : store.fetchMetrics?.());
          announce('Data refreshed');
        } catch {
          announce('Refresh failed', { assertive: true });
        } finally {
          delete btn.dataset.loading;
          btn.disabled = false;
        }
      });
    }

    if (label === 'Export') {
      btn.addEventListener('click', () => {
        const { derived, filters } = store.get();
        if (!derived) { announce('Nothing to export yet', { assertive: true }); return; }
        exportDerived(derived, filters);
        announce('Export downloaded');
      });
      // Nothing to export until data exists.
      btn.disabled = !store.get().derived;
    }
  });

  /* Keep empty state and Export availability in sync with the store.
     'error' gets its own dedicated box (renderErrorState(), wired
     separately) and must not also get the empty-state box here — without
     this exclusion a chart already showing "No data yet" that then fails
     on retry would keep its stale .state-empty box stacked underneath
     the newly-added .state-error one, since neither renderer clears the
     other's box. clearEmptyState() still runs on 'error' so a prior empty
     box is removed. */
  return store.subscribe(s => {
    const hasData = s.status === 'ready' && s.derived && s.derived.meta.rowCount > 0;
    if (s.status === 'error') { clearEmptyState(); }
    else { hasData ? clearEmptyState() : renderEmptyState(); }
    document.querySelectorAll('button').forEach(b => {
      if (b.textContent.trim() === 'Export') b.disabled = !hasData;
    });
  });
}
