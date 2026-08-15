/* ============================================================================
   DDS — State Model & Derived Metrics
   ----------------------------------------------------------------------------
   Single source of truth for the dashboard. Replaces DOM-ID-as-state.

   Contract:
     - `rows` is the ONLY input. Everything else is derived.
     - `derive(rows, filters)` is pure: same input -> same output, no DOM.
     - The shape returned by `derive()` IS the API response shape.
       When the backend lands, swap `derive()` for `fetch()` and nothing
       downstream changes.

   TIME SEMANTICS (do not change without changing the backend):
     All timestamps are parsed and evaluated in UTC. The existing mock is
     internally consistent about this (parseDateTime -> Date.UTC, all readers
     use getUTC*). The server MUST return UTC and MUST NOT localize, or shift
     attribution will silently break for night shifts.
   ========================================================================= */

/* ── Domain constants ───────────────────────────────────────────────────── */

export const EXPECTED_COLUMNS = [
  'UPDATE_TIME', 'START_TIME', 'END_TIME',
  'ASSET_ID', 'EVENT_CODE', 'EVENT_COUNT', 'OPERATOR'
];

// OPERATOR (driver) isn't always captured at the source — some assets report
// unmanned or the field is left blank. A file missing it is still valid;
// those rows fall back to the UNSPECIFIED_OPERATOR label at aggregation time.
export const OPTIONAL_COLUMNS = ['OPERATOR'];
export const UNSPECIFIED_OPERATOR = 'Unspecified';

export const SHIFT = { DAY: 'DAY', NIGHT: 'NIGHT', UNKNOWN: '' };

// Shift classification boundaries (minutes from UTC midnight)
export const DAY_START_MIN = 5 * 60 + 21;   // 05:21
export const DAY_END_MIN   = 17 * 60 + 21;  // 17:21 (exclusive)

// Actionable windows. Contiguous — every second belongs to exactly one shift.
export const DAY_WINDOW   = { start: [5, 21, 0],  end: [17, 20, 59] };
export const NIGHT_WINDOW = { start: [17, 21, 0], end: [5, 20, 59] }; // end is +1 day

/* BOUNDARY — resolved. v2.2 left 17:20:00–17:20:59 in no window at all, so
   anything landing there was forced NON_ACTIONABLE. DAY now runs through
   17:20:59 and NIGHT begins 17:21:00: contiguous, no gap, no overlap.
   Mirrored exactly in supabase/migrations/0001_init.sql — change both or
   neither, and re-run the parity test. */

export const SYNC_BUCKETS  = ['<3h', '3-6h', '6-8h', '8-10h', '10h+'];
export const ALERT_BUCKETS = ['<5', '5-10', '10-15', '15-20', '20+'];

/* ── State ──────────────────────────────────────────────────────────────── */

export function createState() {
  return {
    // ---- raw ----
    rows: [],            // annotated rows (see annotate())
    imports: [],         // [{ id, name, size, uploadedAt, rowCount, problems }]

    // ---- query ----
    filters: {
      from: null,        // 'MM/DD/YYYY' | null
      to: null,
      shift: null,       // 'DAY' | 'NIGHT' | null (= both)
      assetIds: [],      // [] = all
      eventCodes: [],    // [] = all
      actionableOnly: false
    },

    // ---- derived (never written by hand; output of derive()) ----
    derived: null,

    // ---- async / UI ----
    status: 'idle',      // 'idle' | 'loading' | 'ready' | 'error'
    error: null          // { code, message } — never a raw stack trace
  };
}

/* ── Time helpers (UTC-only) ────────────────────────────────────────────── */

// Accepts '/' or '-' as the date separator, ':SS' and AM/PM as optional, and
// either month-first or day-first ordering (disambiguated by detectDayFirst,
// since real-world exports vary and a 31/07/2026 value only fails silently
// if this is too strict).
const DATETIME_RE =
  /^(\d{1,2})[/-](\d{1,2})[/-](\d{4})[T\s]+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?$/;

// Year-first ISO-ish order ("2026-07-28 03:38:09" / "2026/07/28..."): the
// leading 4-digit group makes this unambiguous on its own — no day-first/
// month-first guessing needed, unlike DATETIME_RE above — so it's matched
// as its own pattern rather than folded into detectDayFirst's heuristic.
const DATETIME_YMD_RE =
  /^(\d{4})[/-](\d{1,2})[/-](\d{1,2})[T\s]+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?$/;

/* Some exports produce a timestamp that looks identical on screen to
   "31/07/2026 22:12:43" but is not built from plain ASCII -- a non-breaking
   space or zero-width space instead of a regular space, a full-width digit
   set, or an en/em dash standing in for the date separator. Normalizing to
   plain ASCII before either regex sees the string covers that whole class.
   Every non-ASCII code point below is written as a \u escape sequence, not
   a literal pasted character. */
export function normalizeDateTimeStr(s) {
  // Visible-width spaces: these separate two real tokens (date from time),
  // so they collapse to a single ASCII space -- deleting them outright
  // would glue two digit groups together into one unparseable run.
  const SPACE_CODES = [
    0x00A0, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006,
    0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x2028, 0x2029
  ];
  // Zero-width: these carry no visible width, so they're stripped to
  // nothing rather than becoming a space -- a stray one landing MID-DIGIT
  // ("3<ZWSP>1/07/2026...") must not turn into "3 1/07/2026...".
  const ZERO_WIDTH_CODES = [0x200B, 0xFEFF];
  const HYPHEN_CODES = [0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212];

  const toCharClass = codes => '[' + codes.map(c => '\\u' + c.toString(16).padStart(4, '0')).join('') + ']';
  const spaceRe = new RegExp(toCharClass(SPACE_CODES), 'g');
  const zeroWidthRe = new RegExp(toCharClass(ZERO_WIDTH_CODES), 'g');
  const hyphenRe = new RegExp(toCharClass(HYPHEN_CODES), 'g');
  // Full-width digits 0xFF10-0xFF19 ('0'-'9') and full-width solidus
  // 0xFF0F ('/'), built from code points only -- no literal non-ASCII
  // character anywhere in this function's source.
  const FULLWIDTH_DIGIT_CODES = [0xFF10, 0xFF11, 0xFF12, 0xFF13, 0xFF14, 0xFF15, 0xFF16, 0xFF17, 0xFF18, 0xFF19];
  const fullWidthDigitRe = new RegExp(toCharClass(FULLWIDTH_DIGIT_CODES), 'g');
  const fullWidthSlashRe = new RegExp('\\u' + (0xFF0F).toString(16), 'g');

  return String(s)
    .replace(zeroWidthRe, '')
    .replace(spaceRe, ' ')
    .replace(hyphenRe, '-')
    .replace(fullWidthDigitRe, c => String.fromCharCode(c.charCodeAt(0) - 0xFEE0))
    .replace(fullWidthSlashRe, '/');
}

export function parseDateTime(str, { dayFirst = false } = {}) {
  // XLSX cellDates:true hands back real Date objects for date-formatted
  // cells instead of a string — pass them through rather than stringifying
  // and failing the regex.
  if (str instanceof Date) return Number.isNaN(str.getTime()) ? null : str;
  if (!str || !String(str).trim()) return null;
  const normalized = normalizeDateTimeStr(str).trim();

  // Year-first order is checked first and, if it matches, settles month/day
  // unambiguously on its own — dayFirst never applies to it, since there is
  // no day-vs-month guessing to do once the year is already pinned to the
  // leading 4-digit group.
  const ymd = DATETIME_YMD_RE.exec(normalized);
  if (ymd) {
    const yyyy = Number(ymd[1]), month = Number(ymd[2]), dd = Number(ymd[3]);
    let HH = Number(ymd[4]);
    const MM = Number(ymd[5]);
    const SS = ymd[6] ? Number(ymd[6]) : 0;
    const ampm = ymd[7];
    if (month < 1 || month > 12 || dd < 1 || dd > 31) return null;
    if (ampm) {
      const pm = /p/i.test(ampm);
      if (pm && HH < 12) HH += 12;
      if (!pm && HH === 12) HH = 0;
    }
    if (HH > 23) return null;
    return new Date(Date.UTC(yyyy, month - 1, dd, HH, MM, SS));
  }

  const m = DATETIME_RE.exec(normalized);
  if (!m) return null;
  const a = Number(m[1]), b = Number(m[2]), yyyy = Number(m[3]);
  let HH = Number(m[4]);
  const MM = Number(m[5]);
  const SS = m[6] ? Number(m[6]) : 0;
  const ampm = m[7];

  const [month, dd] = dayFirst ? [b, a] : [a, b];
  if (month < 1 || month > 12 || dd < 1 || dd > 31) return null;

  if (ampm) {
    const pm = /p/i.test(ampm);
    if (pm && HH < 12) HH += 12;
    if (!pm && HH === 12) HH = 0;
  }
  if (HH > 23) return null;

  return new Date(Date.UTC(yyyy, month - 1, dd, HH, MM, SS));
}

// A file's date convention is consistent across all its rows, so one
// unambiguous value (a day-of-month > 12) is enough to settle it for every
// row — including the ambiguous-looking ones the regex alone can't resolve.
// Falls back to month-first (the documented default) when nothing disambiguates.
export function detectDayFirst(rawRows) {
  for (const row of rawRows) {
    for (const col of ['START_TIME', 'UPDATE_TIME', 'END_TIME']) {
      const v = field(row, col);
      if (!v) continue;
      const m = /^(\d{1,2})[/-](\d{1,2})[/-]\d{4}/.exec(normalizeDateTimeStr(v).trim());
      if (!m) continue;
      const a = Number(m[1]), b = Number(m[2]);
      if (a > 12 && b <= 12) return true;
      if (b > 12 && a <= 12) return false;
    }
  }
  return false;
}

const dateOnly = d => new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
const addDays  = (d, n) => new Date(d.getTime() + n * 86400000);
const atTime   = (d, [h, m, s]) => new Date(Date.UTC(
  d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), h, m, s));
const minutesOf = d => d.getUTCHours() * 60 + d.getUTCMinutes() + d.getUTCSeconds() / 60;

export const formatDate = d =>
  `${String(d.getUTCMonth() + 1).padStart(2, '0')}/` +
  `${String(d.getUTCDate()).padStart(2, '0')}/${d.getUTCFullYear()}`;

/* ── Domain logic ───────────────────────────────────────────────────────── */

export function classifyShift(startTime) {
  const t = minutesOf(startTime);
  const base = dateOnly(startTime);
  if (t >= DAY_START_MIN && t < DAY_END_MIN) {
    return { shift: SHIFT.DAY, shiftDate: base };
  }
  // Early-morning tail (00:00–05:20) belongs to the PREVIOUS day's night shift.
  return {
    shift: SHIFT.NIGHT,
    shiftDate: t < DAY_START_MIN ? addDays(base, -1) : base
  };
}

export function shiftWindow(shift, shiftDate) {
  return shift === SHIFT.DAY
    ? { start: atTime(shiftDate, DAY_WINDOW.start), end: atTime(shiftDate, DAY_WINDOW.end) }
    : { start: atTime(shiftDate, NIGHT_WINDOW.start),
        end:   atTime(addDays(shiftDate, 1), NIGHT_WINDOW.end) };
}

const field = (row, col) => {
  if (row[col] !== undefined) return row[col];
  const k = Object.keys(row).find(k => k.trim().toUpperCase() === col);
  return k ? row[k] : undefined;
};
const num = v => { const n = parseFloat(v); return Number.isFinite(n) ? n : 0; };

/* ── Ingest: raw rows -> annotated rows ─────────────────────────────────── */

/* REJECT AT IMPORT — rows whose timestamps can't be parsed never enter the
   dataset. They are returned separately so the import UI can report them.
   Consequence: derived totals always reconcile with the trend chart, because
   every surviving row has a shift. meta.reconciles is therefore always true
   for locally-loaded data; it remains in the shape as a server-side guard. */
export function annotate(rawRows) {
  const dayFirst = detectDayFirst(rawRows);
  const problems = [];
  const rejected = [];
  const rows = [];
  rawRows.forEach((row, i) => {
    const startTime  = parseDateTime(field(row, 'START_TIME'), { dayFirst });
    const updateTime = parseDateTime(field(row, 'UPDATE_TIME'), { dayFirst });
    const endTime    = parseDateTime(field(row, 'END_TIME'), { dayFirst });

    if (!startTime || !updateTime) {
      const reason = !startTime ? 'Unparseable START_TIME' : 'Unparseable UPDATE_TIME';
      problems.push({ rowIndex: i, reason });
      rejected.push({ rowIndex: i, reason, row });
      return;                                   // excluded from the dataset
    }

    const { shift, shiftDate } = classifyShift(startTime);
    const win = shiftWindow(shift, shiftDate);
    const actionable = updateTime >= win.start && updateTime <= win.end;

    // Sync lag: how long after the event ended did it reach the server.
    const syncSeconds = endTime ? (updateTime - endTime) / 1000 : null;

    rows.push({
      ...row,
      SHIFT: shift,
      SHIFT_DATE: formatDate(shiftDate),
      ACTIONABLE: actionable ? 'ACTIONABLE' : 'NON_ACTIONABLE',
      _startHour: startTime.getUTCHours(),
      _startTime: startTime,          // full Date — sort key for recent-alerts lists
      _syncSeconds: syncSeconds != null && syncSeconds >= 0 ? syncSeconds : null
    });
  });
  return { rows, problems, rejected };
}

/* ── Filtering ──────────────────────────────────────────────────────────── */

export function applyFilters(rows, f) {
  if (!f) return rows;
  return rows.filter(r => {
    if (f.shift && r.SHIFT !== f.shift) return false;
    if (f.actionableOnly && r.ACTIONABLE !== 'ACTIONABLE') return false;
    if (f.from && r.SHIFT_DATE && r.SHIFT_DATE < f.from) return false;
    if (f.to   && r.SHIFT_DATE && r.SHIFT_DATE > f.to)   return false;
    if (f.assetIds?.length   && !f.assetIds.includes(field(r, 'ASSET_ID'))) return false;
    if (f.eventCodes?.length && !f.eventCodes.includes(field(r, 'EVENT_CODE'))) return false;
    return true;
  });
}

/* ── Derive: the API response shape ─────────────────────────────────────── */

export function derive(allRows, filters) {
  const rows = applyFilters(allRows, filters);

  let totalAlerts = 0, actionableAlerts = 0;
  let syncSum = 0, syncN = 0;
  let unclassifiedRows = 0, unclassifiedUnits = 0;

  const assets = new Map();      // id -> { total, actionable, nonActionable, days:Set }
  const operators = new Map();   // id -> { total, actionable, nonActionable, days:Set }
  const eventCodes = new Map();  // code -> { units, events }
  const byDate = new Map();      // MM/DD/YYYY -> { units, events, assets:Set, syncSum, syncN }
  const hourly = { DAY: Array(24).fill(0), NIGHT: Array(24).fill(0) };
  // "YYYY-MM" -> number[24] — one line per calendar month for the Hourly
  // chart's by-month view (charts.hourlyMonthly()). Separate from `hourly`
  // above (DAY/NIGHT split), which several other consumers still read
  // unchanged — see that field's own comment further down.
  const hourlyByMonth = new Map();
  const shiftTotals = { DAY: { units: 0, assets: new Set() },
                        NIGHT: { units: 0, assets: new Set() } };
  const syncBuckets  = { actionable: [0,0,0,0,0], nonActionable: [0,0,0,0,0] };
  const alertBuckets = { actionable: [0,0,0,0,0], nonActionable: [0,0,0,0,0] };

  for (const r of rows) {
    const units = num(field(r, 'EVENT_COUNT'));
    const isAct = r.ACTIONABLE === 'ACTIONABLE';
    const asset = field(r, 'ASSET_ID');
    const operRaw = field(r, 'OPERATOR');
    const oper  = (operRaw != null && String(operRaw).trim()) ? String(operRaw).trim() : UNSPECIFIED_OPERATOR;
    const code  = field(r, 'EVENT_CODE');

    totalAlerts += units;
    if (isAct) actionableAlerts += units;

    /* ⚠ RECONCILIATION — inherited from v2.2 compute().
       Rows with an unparseable timestamp have no SHIFT, so they are excluded
       from trend/shift/hourly but STILL counted in totalAlerts. Result:
       kpis.totalAlerts can exceed sum(trend.units). Surfaced in meta so the
       UI can warn instead of silently disagreeing with itself. */
    if (!r.SHIFT) { unclassifiedRows++; unclassifiedUnits += units; }

    if (asset) {
      const a = assets.get(asset) || { total: 0, actionable: 0, nonActionable: 0, dayTotals: new Map() };
      a.total += units;
      isAct ? (a.actionable += units) : (a.nonActionable += units);
      if (r.SHIFT_DATE) a.dayTotals.set(r.SHIFT_DATE, (a.dayTotals.get(r.SHIFT_DATE) || 0) + units);
      assets.set(asset, a);
    }
    {
      const o = operators.get(oper) || { total: 0, actionable: 0, nonActionable: 0, dayTotals: new Map() };
      o.total += units;
      isAct ? (o.actionable += units) : (o.nonActionable += units);
      if (r.SHIFT_DATE) o.dayTotals.set(r.SHIFT_DATE, (o.dayTotals.get(r.SHIFT_DATE) || 0) + units);
      operators.set(oper, o);
    }
    if (code) {
      const c = eventCodes.get(code) || { units: 0, events: 0 };
      c.units += units; c.events += 1;
      eventCodes.set(code, c);
    }

    if (r._startHour != null && hourly[r.SHIFT]) hourly[r.SHIFT][r._startHour] += units;

    if (r._startHour != null && r._startTime) {
      // UTC month key, matching _startHour's own UTC convention (see
      // annotate()'s _startHour: startTime.getUTCHours()) — "the hour" and
      // "the month it's grouped under" must agree on which clock they're
      // reading, or a day near a UTC month boundary could double count.
      const mKey = `${r._startTime.getUTCFullYear()}-${String(r._startTime.getUTCMonth() + 1).padStart(2, '0')}`;
      const bucket = hourlyByMonth.get(mKey) || Array(24).fill(0);
      bucket[r._startHour] += units;
      hourlyByMonth.set(mKey, bucket);
    }

    if (shiftTotals[r.SHIFT]) {
      shiftTotals[r.SHIFT].units += units;
      if (asset) shiftTotals[r.SHIFT].assets.add(asset);
    }

    if (r._syncSeconds != null) {
      syncSum += r._syncSeconds; syncN++;
      const h = r._syncSeconds / 3600;
      const i = h < 3 ? 0 : h < 6 ? 1 : h < 8 ? 2 : h < 10 ? 3 : 4;
      syncBuckets[isAct ? 'actionable' : 'nonActionable'][i]++;
    }

    const ai = units < 5 ? 0 : units < 10 ? 1 : units < 15 ? 2 : units < 20 ? 3 : 4;
    alertBuckets[isAct ? 'actionable' : 'nonActionable'][ai]++;

    if (r.SHIFT_DATE) {
      const d = byDate.get(r.SHIFT_DATE) || { units: 0, events: 0, assets: new Set(), syncSum: 0, syncN: 0 };
      d.units += units; d.events += 1;
      if (asset) d.assets.add(asset);
      // Same null-when-unmeasured convention as the whole-period
      // avgSyncSeconds below — a day with zero synced rows must not
      // silently read as a sync delay of zero.
      if (r._syncSeconds != null) { d.syncSum += r._syncSeconds; d.syncN += 1; }
      byDate.set(r.SHIFT_DATE, d);
    }
  }

  /* Ties at the LIMIT boundary must break the same way here and in SQL, or
     two assets with equal totals swap in and out of the top-10 depending on
     which engine answered. Secondary sort on id makes it deterministic.
     Mirrored by `order by total desc, asset_id` in 0002_metrics.sql. */
  const topN = (map, n = 10) =>
    [...map.entries()]
      .map(([id, v]) => ({ id, total: v.total, actionable: v.actionable,
                            nonActionable: v.nonActionable, activeDays: v.dayTotals.size }))
      .sort((a, b) => b.total - a.total || String(a.id).localeCompare(String(b.id)))
      .slice(0, n);

  /* HIGH-CONSISTENCY FLAG — a driver/unit is "High" when MOST of its active
     days (>50%) each had more than HIGH_DAY_THRESHOLD alerts, not just a
     single bad day. A one-off spike (1 day over threshold out of 20) is
     noise; a driver whose alerts are over threshold on 6 of 7 active days
     is a pattern. highDays/activeDays (highDayRatio) is exposed so the UI
     can explain the flag with real numbers ("6 of 7 active days (86%) had
     more than 10 alerts") instead of just showing a bare label.
     consistencyRate (alerts per active day) is kept alongside as a
     supporting number the table already showed, not the flagging basis
     itself anymore.
     Unranked / uncapped (unlike topN above) — the monitoring page wants
     every driver/unit, not just the top 10 by volume, since a low-volume
     entity whose few days are consistently over threshold is exactly what
     "needs attention" should surface and a volume-only top-10 would miss. */
  const HIGH_DAY_THRESHOLD = 10;

  const withConsistency = map =>
    [...map.entries()]
      .map(([id, v]) => {
        const activeDays = v.dayTotals.size;
        const highDays = [...v.dayTotals.values()].filter(day => day > HIGH_DAY_THRESHOLD).length;
        const highDayRatio = activeDays ? (highDays / activeDays) * 100 : 0;
        return {
          id, total: v.total, actionable: v.actionable, nonActionable: v.nonActionable,
          activeDays,
          highDays,
          highDayRatio,
          flagged: activeDays > 0 && highDays / activeDays > 0.5,
          consistencyRate: v.total / (activeDays || 1),
          actionableRatio: v.total ? (v.actionable / v.total) * 100 : 0
        };
      })
      .sort((a, b) => (b.flagged - a.flagged) || b.highDayRatio - a.highDayRatio ||
        b.consistencyRate - a.consistencyRate || String(a.id).localeCompare(String(b.id)));

  /* Most-recent-first log. _startTime is only absent on rows whose
     timestamp failed to parse — annotate() already excludes those from
     `rows` entirely, so no null guard is needed here. Ties (same
     millisecond) break on asset id for a stable, deterministic order. */
  const recentAlerts = [...rows]
    .sort((a, b) => b._startTime - a._startTime ||
      String(field(a, 'ASSET_ID')).localeCompare(String(field(b, 'ASSET_ID'))))
    .slice(0, 8)
    .map(r => ({
      time: r._startTime.toISOString(),
      operator: (() => {
        const v = field(r, 'OPERATOR');
        return (v != null && String(v).trim()) ? String(v).trim() : UNSPECIFIED_OPERATOR;
      })(),
      asset: field(r, 'ASSET_ID') ?? '—',
      eventCode: field(r, 'EVENT_CODE') ?? '—',
      shift: r.SHIFT || SHIFT.UNKNOWN,
      count: num(field(r, 'EVENT_COUNT'))
    }));

  const dayU = shiftTotals.DAY.units, nightU = shiftTotals.NIGHT.units;
  const shiftSum = dayU + nightU;

  return {
    meta: {
      rowCount: rows.length,
      unclassifiedRows,          // rows with unparseable timestamps
      unclassifiedUnits,         // their EVENT_COUNT — the trend/KPI delta
      reconciles: unclassifiedUnits === 0,
      filters: filters ?? null,
      generatedAt: new Date().toISOString()
    },

    // ---- KPI strip (both Overview and Analytics consume this) ----
    kpis: {
      totalAlerts,
      distinctAssets: assets.size,
      distinctOperators: operators.size,
      avgSyncSeconds: syncN ? syncSum / syncN : null,
      actionableRatio: totalAlerts ? (actionableAlerts / totalAlerts) * 100 : 0
    },

    // ---- charts ----
    trend: [...byDate.entries()]
      .map(([date, v]) => ({
        date, units: v.units, events: v.events, assets: v.assets.size,
        avgSyncSeconds: v.syncN ? v.syncSum / v.syncN : null
      }))
      .sort((a, b) => new Date(a.date) - new Date(b.date)),

    shiftDistribution: {
      DAY:   { units: dayU,   assets: shiftTotals.DAY.assets.size,
               pct: shiftSum ? (dayU / shiftSum) * 100 : 0 },
      NIGHT: { units: nightU, assets: shiftTotals.NIGHT.assets.size,
               pct: shiftSum ? (nightU / shiftSum) * 100 : 0 }
    },

    eventCodeDistribution: [...eventCodes.entries()]
      .map(([code, v]) => ({ code, units: v.units, events: v.events,
                             pct: totalAlerts ? (v.units / totalAlerts) * 100 : 0 }))
      .sort((a, b) => b.units - a.units || a.code.localeCompare(b.code)),

    hourly,                              // { DAY: number[24], NIGHT: number[24] }

    // One entry per calendar month present in the data, sorted chronologically
    // ("YYYY-MM" sorts correctly as a plain string). Powers the Hourly chart's
    // by-month view (charts.hourlyMonthly()) — a separate field from `hourly`
    // above rather than a replacement, since several other consumers
    // (insightBullets.peakHour, the a11y hourly table, CSV export) still read
    // the DAY/NIGHT shape unchanged.
    hourlyByMonth: [...hourlyByMonth.entries()]
      .map(([month, hours]) => ({ month, hours }))
      .sort((a, b) => a.month.localeCompare(b.month)),

    syncBuckets:  { labels: SYNC_BUCKETS,  ...syncBuckets  },
    alertBuckets: { labels: ALERT_BUCKETS, ...alertBuckets },

    topAssets:    topN(assets),          // [{ id, total, actionable, nonActionable, activeDays }]
    topOperators: topN(operators),       // [{ id, total, actionable, nonActionable, activeDays }]

    // Full (uncapped) per-entity breakdown, sorted flagged-first — feeds the
    // Driver & Asset Monitoring page. See withConsistency() above for the
    // flagging rule and why this is a separate list rather than reusing
    // topAssets/topOperators.
    assetConsistency:    withConsistency(assets),    // [{ id, total, actionable, nonActionable, activeDays, highDays, highDayRatio, flagged, consistencyRate, actionableRatio }]
    operatorConsistency: withConsistency(operators), // same shape, keyed by OPERATOR

    // Most recent individual rows, newest first — a log view, not an
    // aggregate. Respects the active filters, same as everything above.
    recentAlerts                         // [{ time, operator, asset, eventCode, shift, count }]
  };
}

/* ── Period comparison ──────────────────────────────────────────────────────
   "vs last month" needs a baseline, and the honest baseline is an equal-length
   window immediately before the selected one — not a calendar month. Imported
   files are historical and often partial, so a calendar-month baseline
   silently compares 31 days against 9 and reports a 70% "drop" that is really
   just missing data.

   RATE vs VOLUME. Raw totals are confounded by fleet size: if alerts rise 50%
   while active assets rise 25%, per-asset risk only rose 20%. Both are
   reported so the confound is visible instead of hidden. */

const MS_DAY = 86400000;
const toDate = mmddyyyy => {
  const [m, d, y] = String(mmddyyyy).split('/').map(Number);
  return new Date(Date.UTC(y, m - 1, d));
};

/* Baseline-window fallback. The primary rule stays "equal length to the
   current period, immediately preceding it" (spanDays). When that window
   isn't fully covered by the data, instead of immediately settling for a
   caveat-flagged partial baseline, try shorter STANDARD granularities —
   30 days, then 7, then 1 (yesterday) — skipping any step that's not
   actually shorter than spanDays (already covered by the primary attempt).
   Both `current` AND `previous` shrink to the SAME chosen length, clipped
   to the most recent N days of whatever `current` originally was — never
   just `previous`. Comparing a shrunk previous window against the
   ORIGINAL, longer current window (e.g. 7 days of history vs a 30-day
   current total) produced a real but wildly disproportionate percentage —
   more alerts almost always accumulate over 30 days than over 7, so
   "current vastly exceeds previous" was structural, not a genuine trend.
   Every comparison here is strictly N days vs N days, for whichever N is
   the largest granularity fully covered by the data on BOTH sides. Only
   falls all the way back to the original partial-equal-length behavior if
   none of 30/7/1 works either. */
const BASELINE_FALLBACK_DAYS = [30, 7, 1];

/** Resolve current and baseline windows from the filters and available data. */
export function resolvePeriods(allRows, filters, fallbackDays = 30) {
  const dates = [...new Set(allRows.map(r => r.SHIFT_DATE).filter(Boolean))]
    .sort((a, b) => toDate(a) - toDate(b));
  if (!dates.length) return null;

  let from, to;
  if (filters?.from && filters?.to) {
    from = toDate(filters.from); to = toDate(filters.to);
  } else {
    // No explicit range: most recent `fallbackDays` of shift dates present.
    to = toDate(dates.at(-1));
    from = new Date(Math.max(toDate(dates[0]).getTime(), to.getTime() - (fallbackDays - 1) * MS_DAY));
  }
  const spanDays = Math.round((to - from) / MS_DAY) + 1;
  const prevTo = new Date(from.getTime() - MS_DAY);
  const earliest = toDate(dates[0]);

  // Primary: equal-length window, immediately preceding `current`.
  const prevFrom = new Date(prevTo.getTime() - (spanDays - 1) * MS_DAY);
  if (prevFrom >= earliest) {
    return {
      spanDays,
      current:  { from, to },
      previous: { from: prevFrom, to: prevTo },
      baselineComplete: true,
      baselineCoverage: 1,
      baselineDays: spanDays
    };
  }

  // Equal-length isn't fully covered — try each standard granularity that's
  // actually shorter than spanDays (a step >= spanDays was already just
  // tried above and failed, so re-trying it here would be redundant).
  // BOTH windows clip to `days` here — `current` clips to its own most
  // recent `days`, not the original (longer) span, so the two sides
  // being compared are always the same length.
  for (const days of BASELINE_FALLBACK_DAYS) {
    if (days >= spanDays) continue;
    const candidateFrom = new Date(prevTo.getTime() - (days - 1) * MS_DAY);
    if (candidateFrom >= earliest) {
      const clippedCurrentFrom = new Date(to.getTime() - (days - 1) * MS_DAY);
      return {
        spanDays: days,
        current:  { from: clippedCurrentFrom, to },
        previous: { from: candidateFrom, to: prevTo },
        baselineComplete: true,
        baselineCoverage: 1,
        baselineDays: days
      };
    }
  }

  // Nothing — not the equal-length window, not 30d/7d/1d — is fully
  // covered. Fall back to the equal-length window flagged partial, same
  // as the original (pre-fallback) behavior, so the UI still shows
  // *something* rather than nothing.
  return {
    spanDays,
    current:  { from, to },
    previous: { from: prevFrom, to: prevTo },
    // Baseline is partial when the data does not reach back far enough. A 12%
    // change measured against 4 days of history is noise, and the UI must be
    // able to say so rather than presenting it as fact.
    baselineComplete: false,
    baselineCoverage: Math.max(0, Math.min(1,
      (prevTo - Math.max(prevFrom, earliest)) / ((spanDays - 1) * MS_DAY || 1))),
    baselineDays: spanDays
  };
}

const inWindow = (row, w) => {
  if (!row.SHIFT_DATE) return false;
  const d = toDate(row.SHIFT_DATE);
  return d >= w.from && d <= w.to;
};

const fmtRange = w => `${formatDate(w.from)} – ${formatDate(w.to)}`;

/* The absolute floor a previous-period value must clear before a
   period-over-period percentage is considered meaningful, regardless of
   what a given metric's own (much lower) minBaseline allows through for the
   plain delta. Below this, a swing of even one unit produces a triple-digit
   "+%" that is technically correct and practically misleading, so pct comes
   back null and callers fall back to the plain delta instead. */
const PCT_MIN_BASELINE = 10;

/**
 * Compare the selected period against the equal-length preceding period.
 * Returns null when there is no usable baseline — the caller shows "no
 * comparison available" rather than a fabricated 0%.
 */
export function compare(allRows, filters) {
  const periods = resolvePeriods(allRows, filters);
  if (!periods) return null;

  const base = applyFilters(allRows, { ...filters, from: null, to: null });
  const cur  = base.filter(r => inWindow(r, periods.current));
  const prev = base.filter(r => inWindow(r, periods.previous));
  if (!prev.length) {
    return { available: false, reason: 'No data in the preceding period',
             periods: { current: fmtRange(periods.current),
                        previous: fmtRange(periods.previous) } };
  }

  const a = derive(cur, null), b = derive(prev, null);

  const activeDays = rows => new Set(rows.map(r => r.SHIFT_DATE)).size || 1;

  /* Per-asset-per-active-day: the volume-independent risk rate. This is the
     number that actually tells you whether drivers got drowsier. */
  const rate = (k, rows) =>
    k.distinctAssets ? k.totalAlerts / k.distinctAssets / activeDays(rows) : 0;

  /* Plain per-asset rate (no active-days divisor) for the KPI tile
     comparison line — "how many alerts per vehicle" rather than the
     alertRate metric's "per vehicle per active day" risk rate. Passed to
     metric() as opts.perAsset so kpiTile() can show the avg-alerts-per-
     asset rate for both periods instead of a raw previous-period total for
     alert-COUNT metrics specifically — normalizing by fleet size the other
     metrics (asset count itself, driver count, sync delay, actionable
     ratio) don't share, since "assets per asset" isn't a meaningful rate. */
  const perAssetRate = (count, assetCount) => assetCount ? count / assetCount : null;
  const perAsset = (curCount, prevCount) => ({
    current: perAssetRate(curCount, a.kpis.distinctAssets),
    previous: perAssetRate(prevCount, b.kpis.distinctAssets)
  });

  const metric = (key, label, curVal, prevVal, opts = {}) => {
    const delta = curVal - prevVal;
    // Percent change is meaningless against a tiny baseline, not just a zero one.
    const pctUsable = Math.abs(prevVal) >= Math.max(opts.minBaseline ?? 1e-9, PCT_MIN_BASELINE);
    return {
      key, label,
      current: curVal, previous: prevVal, delta,
      pct: pctUsable ? (delta / Math.abs(prevVal)) * 100 : null,
      /* Direction is about GOOD/BAD, not up/down. More alerts is bad; faster
         sync is good. Colouring by arrow direction alone would paint a
         genuine improvement red. */
      goodWhen: opts.goodWhen ?? 'down',
      unit: opts.unit ?? 'count',
      significant: Math.abs(delta) > (opts.noiseFloor ?? 0),
      perAsset: opts.perAsset
    };
  };

  return {
    available: true,
    periods: {
      current: fmtRange(periods.current),
      previous: fmtRange(periods.previous),
      spanDays: periods.spanDays,
      // How far back the baseline window actually reaches — 30, 7, or 1
      // when the fallback cascade kicked in; equal to spanDays when the
      // primary equal-length window was fully available. Lets the KPI
      // tile say "vs last 30 days" / "vs last 7 days" / "vs yesterday"
      // instead of a generic "vs previous period" once the baseline
      // length no longer always matches the current period's length.
      baselineDays: periods.baselineDays
    },
    baselineComplete: periods.baselineComplete,
    baselineCoverage: periods.baselineCoverage,
    metrics: [
      metric('totalAlerts', 'Total alerts', a.kpis.totalAlerts, b.kpis.totalAlerts,
             { goodWhen: 'down', minBaseline: 1,
               perAsset: perAsset(a.kpis.totalAlerts, b.kpis.totalAlerts) }),
      metric('alertRate', 'Alerts per asset per active day',
             rate(a.kpis, cur), rate(b.kpis, prev),
             { goodWhen: 'down', unit: 'rate', minBaseline: 0.01 }),
      metric('distinctAssets', 'Assets reporting',
             a.kpis.distinctAssets, b.kpis.distinctAssets,
             { goodWhen: 'flat', minBaseline: 1 }),
      metric('distinctOperators', 'Drivers involved',
             a.kpis.distinctOperators, b.kpis.distinctOperators,
             { goodWhen: 'down', minBaseline: 1 }),
      metric('avgSyncSeconds', 'Average sync delay',
             a.kpis.avgSyncSeconds ?? 0, b.kpis.avgSyncSeconds ?? 0,
             { goodWhen: 'down', unit: 'duration', minBaseline: 1 }),
      metric('actionableRatio', 'Actionable ratio',
             a.kpis.actionableRatio, b.kpis.actionableRatio,
             { goodWhen: 'up', unit: 'percent', minBaseline: 0.5 })
    ]
  };
}

/* ── Store: subscribe / render-from-state ───────────────────────────────── */

export function createStore(initial = createState()) {
  let state = initial;
  const listeners = new Set();
  const emit = () => listeners.forEach(fn => fn(state));

  return {
    get: () => state,
    subscribe(fn) { listeners.add(fn); fn(state); return () => listeners.delete(fn); },

    /** Local path (today): recompute in the browser. */
    load(rawRows) {
      const { rows, problems, rejected } = annotate(rawRows);
      state = { ...state, rows, status: 'ready', error: null };
      state.derived = derive(rows, state.filters);
      state.derived.comparison = compare(rows, state.filters);
      emit();
      return { problems, rejected, accepted: rows.length };
    },

    /** Server path (later): the ONLY function that changes. Same shape out. */
    async fetchMetrics(filters = state.filters) {
      state = { ...state, status: 'loading', error: null };
      emit();
      try {
        const qs = new URLSearchParams(
          Object.entries(filters).filter(([, v]) =>
            v != null && v !== false && !(Array.isArray(v) && !v.length))
            .map(([k, v]) => [k, Array.isArray(v) ? v.join(',') : v])
        );
        const res = await fetch(`/api/metrics?${qs}`, { credentials: 'same-origin' });
        if (!res.ok) throw new Error(`HTTP_${res.status}`);
        state = { ...state, derived: await res.json(), filters, status: 'ready' };
      } catch (e) {
        // Never surface raw errors to the UI.
        state = { ...state, status: 'error',
                  error: { code: 'METRICS_FETCH_FAILED',
                           message: 'Unable to load metrics. Please retry.' } };
      }
      emit();
    },

    setFilters(patch) {
      const filters = { ...state.filters, ...patch };
      const derived = derive(state.rows, filters);
      derived.comparison = compare(state.rows, filters);
      state = { ...state, filters, derived };
      emit();
    },

    /* ── Cloud path (Supabase) — used by App.loadFromServer() in index.html.
       dds_metrics() already returns the derive()-shaped object server-side,
       so there's nothing to compute here; these three just move state in
       and out of "loading" around that call. Kept separate from
       fetchMetrics() above (the earlier /api/metrics REST design) rather
       than merged into it, since the caller owns the Cloud client and the
       comparison-period fetch logic that produces `derived`. */

    /** Set already-annotated rows plus a precomputed derived object. Used by
        the import pipeline, which annotates during validation and must not pay
        to re-parse every timestamp a second time. */
    _setRows(rows, derived) {
      state = { ...state, rows, derived, status: 'ready', error: null };
      emit();
    },

    _setStatus(status) { state = { ...state, status }; emit(); },

    _setError(message) {
      state = { ...state, status: 'error',
                error: { code: 'METRICS_FETCH_FAILED', message } };
      emit();
    }
  };
}
