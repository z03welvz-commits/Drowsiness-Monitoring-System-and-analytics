#!/usr/bin/env node
/* ============================================================================
 * DDS — JS/SQL parity comparator (Node, no external dependencies)
 * ----------------------------------------------------------------------------
 * Why this exists alongside parity.sh:
 *
 * parity.sh is the full end-to-end test — it creates a scratch database,
 * replays every migration, ingests the fixture through dds_ingest(), and
 * diffs the result against derive(). It is the stronger test and remains the
 * one to run in CI.
 *
 * But it needs `psql` AND a real `python3`, and on a stock Windows machine it
 * cannot run at all: psql is absent unless Postgres is installed, and the
 * `python3` on PATH is the Microsoft Store stub, which prints an install
 * advert and exits non-zero. The practical consequence was that the parity
 * check — described in README.md as "the only thing standing between JS and
 * SQL agreeing and JS and SQL silently disagreeing" — was never actually run.
 *
 * This script closes that gap with what a Windows machine already has: Node.
 * It does NOT replace parity.sh. It takes the SQL side's output as a JSON
 * file (however you obtained it) and diffs it against the JS side computed
 * locally, applying exactly the same normalisation rules parity.sh uses.
 *
 * Usage:
 *   # 1. Get the SQL side. Any of these works:
 *   #      - Supabase dashboard SQL editor: select public.dds_metrics();
 *   #        then export/copy the JSON cell into a file
 *   #      - psql -At -c "select public.dds_metrics();" > sql.json
 *   #      - an MCP/REST call that returns the same object
 *   #
 *   # 2. Diff it against the JS side:
 *   node test/compare-derived.mjs sql.json
 *
 *   # Or compute only the JS side (to inspect / to feed elsewhere):
 *   node test/compare-derived.mjs --emit-js > js.json
 *
 * Exit code is 0 on match, 1 on any difference — so it works in CI as-is.
 * ========================================================================= */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { annotate, derive } from '../src/dds-state.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURE = resolve(HERE, 'fixture.json');

/* ── Normalisation ──────────────────────────────────────────────────────────
   Identical in intent to parity.sh's `norm()`:
     - generatedAt is a clock read and filters echoes the input; neither is
       derived from the rows, so both are excluded from the comparison.
     - Numbers are rounded to 6 decimal places. Postgres numeric and IEEE-754
       double do not agree bit-for-bit on values like 93.27548806941431, and
       that difference is not a logic bug — it is the two engines' float
       representations. 6dp is far tighter than any displayed precision.
     - Object keys are sorted so key ORDER never counts as a difference;
       JSON objects are unordered by definition and jsonb_build_object does
       not preserve insertion order.
   Array order IS significant and is deliberately NOT normalised — ordering
   (topAssets ties, recentAlerts recency, trend chronology) is exactly the
   kind of drift this test exists to catch. */
const IGNORED_META_KEYS = new Set(['generatedAt', 'filters']);

function norm(value) {
  if (Array.isArray(value)) return value.map(norm);
  if (value && typeof value === 'object') {
    const out = {};
    for (const key of Object.keys(value).sort()) {
      if (IGNORED_META_KEYS.has(key)) continue;
      out[key] = norm(value[key]);
    }
    return out;
  }
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Math.round(value * 1e6) / 1e6;
  }
  return value;
}

/* Structural diff producing dotted paths, so a failure names the exact field
   rather than dumping two large objects and leaving you to spot it. */
function diff(a, b, path = '') {
  const out = [];
  const aIsObj = a && typeof a === 'object' && !Array.isArray(a);
  const bIsObj = b && typeof b === 'object' && !Array.isArray(b);

  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) {
      out.push(`${path}: length JS=${a.length} SQL=${b.length}`);
    } else {
      a.forEach((x, i) => out.push(...diff(x, b[i], `${path}[${i}]`)));
    }
  } else if (aIsObj && bIsObj) {
    for (const key of [...new Set([...Object.keys(a), ...Object.keys(b)])].sort()) {
      if (!(key in a)) out.push(`${path}.${key}: only in SQL`);
      else if (!(key in b)) out.push(`${path}.${key}: only in JS`);
      else out.push(...diff(a[key], b[key], `${path}.${key}`));
    }
  } else if (!Object.is(a, b)) {
    out.push(`${path}: JS=${JSON.stringify(a)}  SQL=${JSON.stringify(b)}`);
  }
  return out;
}

/* ── JS side ────────────────────────────────────────────────────────────── */

function computeJs() {
  const raw = JSON.parse(readFileSync(FIXTURE, 'utf8'));
  const { rows, rejected } = annotate(raw);
  if (rejected.length) {
    // Not fatal — the fixture may intentionally carry unparseable rows — but
    // it changes what the SQL side must have ingested, so it must be visible.
    console.error(`  note: fixture has ${rejected.length} rejected row(s); ` +
                  `dds_ingest() must have received the same ${rows.length} accepted rows`);
  }
  return derive(rows, null);
}

/* ── Entry point ────────────────────────────────────────────────────────── */

const args = process.argv.slice(2);

if (args.includes('--emit-js')) {
  process.stdout.write(JSON.stringify(computeJs(), null, 2));
  process.exit(0);
}

const sqlPath = args[0];
if (!sqlPath) {
  console.error('usage: node test/compare-derived.mjs <sql-output.json>');
  console.error('       node test/compare-derived.mjs --emit-js > js.json');
  process.exit(2);
}

const js = computeJs();

let sqlText = readFileSync(resolve(process.cwd(), sqlPath), 'utf8').trim();
// psql -At and some dashboard exports wrap the jsonb cell in quotes and
// escape the inner quotes; unwrap that before parsing.
if (sqlText.startsWith('"') && sqlText.endsWith('"')) {
  sqlText = JSON.parse(sqlText);
}
const sql = typeof sqlText === 'string' ? JSON.parse(sqlText) : sqlText;

const differences = diff(norm(js), norm(sql));

if (differences.length) {
  console.error(`\n  FAIL — ${differences.length} difference(s):`);
  for (const d of differences.slice(0, 40)) console.error('   ', d);
  if (differences.length > 40) {
    console.error(`    ... and ${differences.length - 40} more`);
  }
  process.exit(1);
}

console.log('\n  PASS — JS and SQL produce identical metrics');
