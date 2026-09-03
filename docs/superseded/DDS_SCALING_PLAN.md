> **Superseded 2026-09-03.** Benchmarks `annotate()`/`derive()` in the
> deleted `src/dds-state.js` — the client-side ingestion/aggregation path
> that ran before the Sep 1 2026 full `index.html` replacement. The current
> app has no local ingestion pipeline; every upload goes straight through
> `dds_ingest()`/`dds_minestat_ingest()` server-side. Kept for historical
> reference only.

# DDS — Scaling to 1M Rows

All numbers below are **measured on your actual pipeline**, not estimated.
Node 22, synthetic data matching your column shape (500 assets, 200 operators,
6 event codes, 29 shift days). A browser will be slower than these figures,
typically 1.5–2×.

---

## 1. Where the time actually goes

| Rows | `annotate()` | `derive()` | Heap |
|---:|---:|---:|---:|
| 10,000 | 293 ms | 97 ms | 15 MB |
| 100,000 | 1,265 ms | 311 ms | 97 MB |
| **1,000,000** | **9,880 ms** | **884 ms** | **926 MB** |

Two things fall out of this immediately:

**`annotate()` is the problem, not `derive()`.** Aggregation is 8% of the cost.
Ingestion is 92%.

**926 MB of heap will crash a browser tab.** Chrome's practical per-tab budget
is 1–2 GB on desktop and far less on mobile. This isn't "slow", it's a hard
failure before you reach a wait-time question.

### Cost breakdown per operation (1M rows)

| Operation | Cost | Note |
|---|---:|---|
| Regex timestamp parse ×3M | **2,806 ms** | single largest line item |
| `charCode` timestamp parse ×3M | 491 ms | 5.7× faster, same result |
| Object spread `{...row}` ×1M | 470 ms | also the source of the 926 MB |
| Mutate in place ×1M | 189 ms | 2.5× faster than spread |
| Columnar typed arrays ×1M | 359 ms | and ~7× smaller |
| `new Date()` ×3M | 290 ms | avoid; keep epoch numbers |

The regex in `parseDateTime` runs three times per row. At 1M rows that's 3M
regex executions — 28% of total runtime in one function.

---

## 2. The decisive number

| Payload | Size |
|---|---:|
| 1M rows as CSV | ~91 MB |
| 1M rows as JSON | ~179 MB |
| **`derived` from 1,000 rows** | **3.8 KB** |
| **`derived` from 100,000 rows** | **4.1 KB** |

`derived` is **flat**. It does not grow with row count, because it's 29 trend
points, 2 shift buckets, 6 event codes, 24 hourly slots, and two top-10 lists.
100× the rows produced 0.3 KB more output.

**This is the whole plan in one line: the browser should never receive rows.**
It should receive `derived`. Everything below is either how to achieve that, or
what to do in the cases where you can't.

---

## 3. Tier 0 — Aggregate server-side (the actual fix)

Your `GET /api/metrics` contract already returns exactly `derived`. Move the
computation behind it and the client's work becomes constant-time regardless of
whether the fleet has 10K rows or 100M.

```sql
-- One pass, one index. Replaces annotate() + derive() entirely.
CREATE INDEX idx_events_shift ON events (shift_date, shift, asset_id);

SELECT shift_date, shift,
       SUM(event_count)                       AS units,
       COUNT(*)                               AS events,
       COUNT(DISTINCT asset_id)               AS assets,
       SUM(event_count) FILTER (WHERE actionable) AS actionable_units
FROM events
WHERE shift_date BETWEEN $1 AND $2
GROUP BY shift_date, shift;
```

**Compute `shift`, `shift_date`, and `actionable` once at ingest**, store them as
columns, and index them. They're deterministic functions of `START_TIME` and
`UPDATE_TIME` — recomputing them on every dashboard load is pure waste.

> ⚠ The shift-attribution logic must be **identical** in SQL and JS, including
> the night-tail `-1 day` rule and the 17:20:00–17:20:59 boundary gap. Two
> implementations that disagree is worse than a slow dashboard, because it's
> silent. Write a fixture file of ~50 edge-case rows and assert both produce
> byte-identical output in CI.

**Expected result:** sub-100 ms response, ~4 KB over the wire, constant as the
fleet grows.

### Pre-aggregation, when even that isn't fast enough

At ~100M rows, add a rollup table refreshed on ingest:

```sql
CREATE MATERIALIZED VIEW metrics_daily AS
SELECT shift_date, shift, asset_id, event_code,
       SUM(event_count) AS units, COUNT(*) AS events
FROM events GROUP BY 1,2,3,4;
```

Dashboard queries hit the rollup; drill-downs hit the raw table.

---

## 4. Tier 1 — When the browser must parse (your dropzone)

Your import flow is genuinely client-side, so it needs its own answer. Three
changes, in order of payoff:

### 4a. Move it off the main thread

Nothing else matters if the UI is frozen. Even a fast parse blocks input,
animation, and the spinner you'd use to show progress.

```js
// worker.js
self.onmessage = async ({ data: { file } }) => {
  const reader = file.stream().getReader();
  let processed = 0;
  for await (const chunk of readLines(reader)) {
    ingestChunk(chunk);                       // columnar, see 4b
    processed += chunk.length;
    self.postMessage({ type: 'progress', processed });   // real progress bar
  }
  self.postMessage({ type: 'done', derived: deriveColumnar() });
};
```

Only `derived` crosses back — ~4 KB, not 179 MB. Use `postMessage` with a
transferable `ArrayBuffer` if you ever need to send columns.

### 4b. Columnar storage with typed arrays

Measured, same 1M rows:

| | Object pipeline | Columnar | Gain |
|---|---:|---:|---:|
| `annotate` | 9,880 ms | **1,786 ms** | **5.5×** |
| `derive` | 884 ms | **222 ms** | **4.0×** |
| Heap | 926 MB | **130 MB** | **7.1×** |

Total: **10.8 s → 2.0 s, and 926 MB → 130 MB.** The memory drop is what takes
this from "crashes the tab" to "works on a laptop."

Three techniques, all verified above:

```js
// 1. Timestamps as epoch numbers in Float64Array — never Date objects,
//    never regex. 5.7x faster than the current parseDateTime().
function ts(s) {
  if (!s || s.length < 19) return NaN;
  const M = (s.charCodeAt(0)-48)*10 + (s.charCodeAt(1)-48);
  const D = (s.charCodeAt(3)-48)*10 + (s.charCodeAt(4)-48);
  const Y = (s.charCodeAt(6)-48)*1000 + (s.charCodeAt(7)-48)*100
          + (s.charCodeAt(8)-48)*10 + (s.charCodeAt(9)-48);
  const h = (s.charCodeAt(11)-48)*10 + (s.charCodeAt(12)-48);
  const m = (s.charCodeAt(14)-48)*10 + (s.charCodeAt(15)-48);
  const sec = (s.charCodeAt(17)-48)*10 + (s.charCodeAt(18)-48);
  return Date.UTC(Y, M-1, D, h, m, sec);      // NaN-safe: bad input -> NaN
}

// 2. Dictionary-encode repeating strings. 1M rows have 500 distinct
//    ASSET_IDs — store an Int32 index, not 1M copies of "TRK-042".
const assets = new Map();
const assetIdx = new Int32Array(N);
const intern = (map, v) => { let i = map.get(v);
  if (i === undefined) { i = map.size; map.set(v, i); } return i; };

// 3. Flags as Uint8Array, not strings.
const shift = new Uint8Array(N);       // 0 unknown, 1 day, 2 night
const actionable = new Uint8Array(N);  // vs "ACTIONABLE" — 1 byte vs ~24
```

`ACTIONABLE: 'NON_ACTIONABLE'` as a string costs roughly 30 bytes per row —
30 MB at 1M rows, for one bit of information.

### 4c. Normalize headers once, not per cell

`getField()` currently falls back to `Object.keys(row).find(...)` whenever a
header has stray whitespace. That's an O(columns) scan **per field access, per
row** — 7M scans at 1M rows. Resolve the header→index map once after parsing
the first line, then index positionally.

---

## 5. Tier 2 — Never render 1M rows

Your Data Management table will destroy the browser long before the parse does:
1M `<tr>` elements is roughly 3–5 GB of DOM.

- **Virtualize.** Render only the ~40 visible rows. `@tanstack/react-virtual`,
  or ~60 lines of vanilla scroll math since you have no framework.
- **Or paginate server-side** — `LIMIT 100 OFFSET n`, which also keeps the rows
  off the client entirely and stays consistent with Tier 0.
- **Cap the preview.** After import, show the first 100 rows plus a count. Nobody
  visually scans a million records; they filter.

---

## 6. Perceived speed

A 2-second wait that shows progress feels faster than an 800 ms freeze that
doesn't, because a frozen tab is indistinguishable from a crash.

- **Stream progress from the worker.** You know the byte count; report real
  percentages, not a spinner.
- **Render `derived` incrementally.** KPIs can paint after the first chunk and
  refine as more arrives — your store already re-renders on every state change,
  so this is nearly free.
- **Use the skeleton states** already in `dds-tokens.css`; `mount()` sets
  `body[data-status]` for exactly this.
- **Announce completion** via the live region in `dds-a11y.js` — screen-reader
  users otherwise have no idea a long parse finished.
- **Debounce filters** (~150 ms). At 1M rows, filtering on every keystroke
  re-runs the whole aggregation.

---

## 7. Recommended sequence

| # | Change | Effort | Payoff |
|---|---|---|---|
| 1 | Web Worker for import | Low | Unfreezes the UI — do this first regardless |
| 2 | `charCode` timestamp parse | Low | −2.3 s at 1M |
| 3 | Header map resolved once | Low | Removes an O(n·m) trap |
| 4 | Columnar typed arrays | Medium | 5.5× faster, 7× less memory |
| 5 | Virtualized table | Medium | Prevents DOM collapse |
| 6 | **Server-side aggregation** | Medium | **Makes row count irrelevant** |
| 7 | Pre-computed shift columns + index | Medium | Sub-100 ms queries |
| 8 | Materialized rollup | Higher | Only needed past ~100M rows |

Items 1–3 are an afternoon and take 1M rows from 10.8 s to roughly 7 s without
architectural change. Item 4 gets you to 2 s. **Item 6 is the one that actually
solves the problem** — after it, the client does no aggregation at all and 1M vs
100M stops mattering.

---

## 8. Two limits worth naming now

**Import size cap.** Even done well, a 91 MB upload parsed in-browser is a poor
experience and a trivial DoS vector server-side. Cap browser-side import at
~50K rows and route anything larger to a server-side ingest job with a status
poll. The API contract already has `POST /api/imports` returning an `id` — make
it async and add `GET /api/imports/:id` for progress.

**Streaming still needs bounded memory.** A worker that streams the file but
accumulates every row in an array still ends at 926 MB. Streaming and columnar
storage are complementary; doing only the first one moves the crash, it doesn't
prevent it.
