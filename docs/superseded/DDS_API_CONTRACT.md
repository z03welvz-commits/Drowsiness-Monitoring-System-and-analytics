> **Superseded 2026-09-03.** Describes `dds-state.js`'s `derive()` and the
> pre-`ab07107` frontend that called it client-side. That file was deleted
> (orphaned since the Sep 1 2026 full `index.html` replacement — nothing in
> the live app has called it since) and the current app is 100% server-driven
> via `dds_metrics()`/`dds_alert_logs()` etc. Kept for historical reference
> only — do not treat anything below as describing the current app.

# DDS — API Contract v1

Derived from `dds-state.js`. The `derive()` return value **is** this contract —
if the two disagree, `dds-state.js` wins and this doc is stale.

---

## Design rule

> The frontend never computes metrics from raw rows once the backend exists.
> `GET /api/metrics` returns the exact shape `derive()` returns today.
> Only `store.fetchMetrics()` changes. Charts, KPIs, and tables are untouched.

---

## Time semantics — read this first

All timestamps are **UTC**. The mock is already internally consistent about this
(`Date.UTC` on parse, `getUTC*` on every read). The server must match.

| Rule | Value |
|---|---|
| Input format | `MM/DD/YYYY HH:mm:ss` (also accepts `DD/MM/YYYY`, `-` separators, missing `:ss`, and `AM/PM`; day-first vs. month-first is auto-detected per file from any unambiguous value, e.g. a day > 12) |
| DAY shift starts | 05:21 UTC |
| DAY shift ends | 17:20 UTC |
| DAY actionable window | 05:21:00 → 17:19:59 |
| NIGHT actionable window | 17:21:00 → 05:20:59 (+1 day) |
| Night-tail rule | `START_TIME` before 05:21 attributes to the **previous** day's night shift |

**If the server localizes timestamps, night-shift attribution breaks silently.**
No error will be thrown; the numbers will just be wrong. Store as `timestamptz`,
query in UTC.

### ⚠ Two open decisions the backend must not guess

1. **Boundary gap.** `17:20:00–17:20:59` falls in neither actionable window, so
   anything landing there is forced `NON_ACTIONABLE`. Intended, or should DAY
   end at `17:20:59`? Pick one before writing the query.

2. **Unclassified rows.** Rows with unparseable timestamps have no `SHIFT`, so
   they're excluded from trend/shift/hourly but **still counted in
   `kpis.totalAlerts`**. This means `totalAlerts` can exceed `sum(trend.units)`.
   Currently surfaced via `meta.reconciles`. Decide: exclude them from KPIs, or
   keep and show the warning banner.

---

## `GET /api/metrics`

### Query parameters

| Param | Type | Default | Notes |
|---|---|---|---|
| `from` | `MM/DD/YYYY` | — | inclusive, on `SHIFT_DATE` not calendar date |
| `to` | `MM/DD/YYYY` | — | inclusive |
| `shift` | `DAY \| NIGHT` | both | |
| `assetIds` | csv | all | |
| `eventCodes` | csv | all | |
| `actionableOnly` | bool | `false` | |

**Server-side filtering is mandatory.** The client must never receive rows it
isn't authorized to see and then filter them in JS — that's a client-side
authorization bypass. Scope every query by the caller's tenant/site from the
session, never from a request parameter.

### Response `200`

```jsonc
{
  "meta": {
    "rowCount": 1482,
    "unclassifiedRows": 3,
    "unclassifiedUnits": 11,
    "reconciles": false,
    "filters": { "from": "03/01/2025", "to": "03/31/2025", "shift": null },
    "generatedAt": "2025-04-01T00:00:00.000Z"
  },

  "kpis": {
    "totalAlerts": 8421,        // sum(EVENT_COUNT)
    "distinctAssets": 47,
    "avgSyncSeconds": 1100.4,   // mean(UPDATE_TIME - END_TIME), negatives dropped
    "actionableRatio": 86.49    // percent, 0-100
  },

  "trend": [                    // sorted ascending by date
    { "date": "03/01/2025", "units": 210, "events": 34, "assets": 12 }
  ],

  "shiftDistribution": {
    "DAY":   { "units": 3100, "assets": 31, "pct": 36.8 },
    "NIGHT": { "units": 5321, "assets": 39, "pct": 63.2 }
  },

  "eventCodeDistribution": [    // sorted desc by units
    { "code": "DROWSY", "units": 4900, "events": 612, "pct": 58.2 }
  ],

  "hourly": {                   // index = UTC hour of START_TIME
    "DAY":   [0,0,0,0,0,12,45,  "...24 total"],
    "NIGHT": [33,21,18,9,4,2,0, "...24 total"]
  },

  "syncBuckets": {
    "labels": ["<3h","3-6h","6-8h","8-10h","10h+"],
    "actionable":    [412, 88, 31, 12, 4],
    "nonActionable": [ 21, 40, 55, 61, 9]
  },

  "alertBuckets": {
    "labels": ["<5","5-10","10-15","15-20","20+"],
    "actionable":    [220, 180, 90, 40, 18],
    "nonActionable": [ 30,  22, 14,  8,  3]
  },

  "topAssets": [                // max 10, sorted desc by total
    { "id": "TRK-01", "total": 412, "actionable": 388, "nonActionable": 24 }
  ],

  "topOperators": [             // max 10, sorted desc by total
    { "id": "A. Cruz", "total": 388 }
  ]
}
```

### Errors

Return a **stable code plus a safe message**. Never a stack trace, SQL fragment,
driver error, or internal ID.

```json
{ "error": { "code": "METRICS_FETCH_FAILED", "message": "Unable to load metrics." } }
```

| Status | Code |
|---|---|
| `400` | `INVALID_FILTER` |
| `401` | `UNAUTHENTICATED` |
| `403` | `FORBIDDEN` |
| `429` | `RATE_LIMITED` |
| `500` | `METRICS_FETCH_FAILED` |

---

## `POST /api/imports`

Multipart upload of the CSV/XLSX.

**Required columns** (case-insensitive, whitespace-trimmed):
`UPDATE_TIME, START_TIME, END_TIME, ASSET_ID, EVENT_CODE, EVENT_COUNT, OPERATOR`

### Response `201`

```json
{
  "id": "imp_01H...",
  "name": "march_2025.csv",
  "rowCount": 1482,
  "uploadedAt": "2025-04-01T00:00:00.000Z",
  "problems": [{ "rowIndex": 41, "reason": "Unparseable START_TIME" }]
}
```

### File-upload threat notes

The dropzone is the largest attack surface in this app. Server-side, before
anything touches the parser:

- **Re-validate the header server-side.** `checkHeader()` in the browser is a UX
  affordance, not a control.
- **Cap file size and row count**, and rate-limit the endpoint. An unbounded
  spreadsheet parse is a trivial DoS.
- **Sniff content type**, don't trust the extension or the `Content-Type` header.
- **Never store under the user-supplied filename.** Generate the key server-side;
  a raw filename is a path-traversal vector.
- **Treat every cell as hostile text.** A cell starting with `=`, `+`, `-`, or
  `@` becomes a formula on re-export — prefix with `'` on any CSV you emit
  (CSV injection). On render, insert with `textContent`, never `innerHTML`;
  `ASSET_ID` and `OPERATOR` are attacker-controlled and land directly in the
  Top-Offenders tables.
- **Parse out-of-process or in a worker** with a timeout.

---

## Other endpoints

| Method | Path | Notes |
|---|---|---|
| `GET` | `/api/imports` | list; scoped to caller's tenant |
| `DELETE` | `/api/imports/:id` | verify ownership server-side — classic IDOR |
| `GET` | `/api/settings` | never return password fields |
| `PATCH` | `/api/settings` | re-auth before password change |
| `GET` | `/api/users` | **admin only** — enforce server-side |

The mock's Settings page has a `role-admin` / `role-b2b` / `role-oa` badge set.
Those are display state only. Every one of them must be re-checked on the server
for every request — a hidden nav item is not an access control.

---

## Build order

1. Wire `createStore()` into the existing pages; delete the `ov*` / `an*` ID pairs.
2. Merge `OverviewCharts` + `AnalyticsCharts` into one renderer taking `derived`.
3. Stand up `GET /api/metrics` returning this JSON — stub it with a fixture first.
4. Flip `store.load()` → `store.fetchMetrics()`. Nothing else moves.
5. Add loading / empty / error states (they now have a real `status` to bind to).
