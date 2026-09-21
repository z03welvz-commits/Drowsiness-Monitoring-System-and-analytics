#!/usr/bin/env bash
# ============================================================================
# DDS — JS/SQL parity test
# ----------------------------------------------------------------------------
# Asserts that derive() in dds-state.js and dds_metrics() in Postgres produce
# byte-identical output for the same rows.
#
# Why this exists: shift attribution is implemented twice — once in JS for
# local imports, once in SQL for the dashboard. Two implementations that
# disagree produce plausible-looking wrong numbers with no error raised.
# This test is the only thing standing between you and that.
#
# Run in CI on every change to dds-state.js or supabase/migrations/*.sql.
#
# Usage:  ./test/parity.sh [PGHOST] [PGPORT]
# ============================================================================
set -euo pipefail

PGHOST="${1:-/tmp}"
PGPORT="${2:-5433}"
PGUSER="${PGUSER:-postgres}"
DB="dds_parity_$$"
USR='22222222-2222-2222-2222-222222222222'
IMP='33333333-3333-3333-3333-333333333333'
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

psql() { command psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -v ON_ERROR_STOP=1 "$@"; }
cleanup() { psql -d postgres -q -c "drop database if exists $DB;" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "→ creating $DB"
psql -d postgres -q -c "create database $DB;"

# Supabase-provided objects the migrations reference. In CI against a real
# Supabase branch these already exist; locally they need stubbing.
psql -d "$DB" -q <<'SQL'
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key, email text);
create or replace function auth.uid() returns uuid
  language sql stable as $$ select current_setting('dds.uid', true)::uuid $$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='authenticated')
    then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='anon')
    then create role anon; end if;
end $$;
SQL

echo "→ applying migrations"
for f in "$ROOT"/supabase/migrations/*.sql; do
  # Forward-declaration, test-harness only, injected right before the first
  # file that needs it. 0064_fix_driver_asset_weekly_unspecified_streak.sql
  # and 0086_entity_status_reopen_actioned_recurrence.sql both create their
  # own `language sql` functions whose bodies call public.dds_current_
  # streak() — a real function, but one whose own CREATE doesn't appear
  # until 0088_streak_threshold_raised_to_20.sql. `language sql` functions
  # are validated against the catalog at CREATE time (unlike plpgsql), so
  # replaying these 162 files from an empty database in strict numeric
  # order fails here even though the same order has run fine against the
  # live, already-migrated project for years — dds_current_streak() already
  # existed there before these two files were ever applied for real. This
  # stub is 0088's own real body, copied verbatim, so results stay correct
  # for any call made before the real 0088/0133 versions `create or
  # replace` over it later in this same replay. Needs `public.events`
  # (created by 0001) to already exist, hence injected here rather than in
  # the pre-migration setup block above.
  if [[ "$(basename "$f")" == 0064_* ]]; then
    echo "   (forward-declaring dds_current_streak() ahead of 0088 — see comment)"
    psql -d "$DB" -q <<'SQL'
create or replace function public.dds_current_streak(
  p_entity_type text,
  p_entity_id text,
  p_day_threshold integer default 20,
  p_lookback_days integer default 90
)
returns integer
language sql
stable
set search_path to 'public'
as $function$
  with entity_days as (
    select shift_date, sum(event_count) as day_total
    from public.events
    where (p_entity_type = 'driver' and coalesce(emp_no, 'UNSPECIFIED') = p_entity_id)
       or (p_entity_type = 'asset' and asset_id = p_entity_id)
    group by shift_date
  ),
  last_day as (
    select max(shift_date) as d from entity_days
  ),
  cal as (
    select generate_series(
      (select d from last_day) - (greatest(coalesce(p_lookback_days, 90), 1) - 1) * interval '1 day',
      (select d from last_day),
      interval '1 day'
    )::date as cal_date
  ),
  joined as (
    select cal.cal_date,
           (coalesce(ed.day_total, 0) >= coalesce(p_day_threshold, 20)) as qualifies
    from cal
    left join entity_days ed on ed.shift_date = cal.cal_date
  ),
  ranked as (
    select row_number() over (order by cal_date desc) as rn, qualifies
    from joined
  ),
  first_break as (
    select min(rn) as rn from ranked where not qualifies
  )
  select coalesce(
    case
      when (select rn from first_break) is null then (select count(*) from ranked)
      else (select rn from first_break) - 1
    end, 0
  );
$function$;
SQL
  fi
  echo "   $(basename "$f")"
  psql -d "$DB" -q -f "$f"
done

echo "→ computing JS expectation"
node --input-type=module -e "
import {annotate,derive} from '$ROOT/src/dds-state.js';
import {readFileSync,writeFileSync} from 'fs';
const raw=JSON.parse(readFileSync('$ROOT/test/fixture.json'));
const {rows,rejected}=annotate(raw);
if(rejected.length) { console.error('fixture has rejected rows:',rejected.length); }
writeFileSync('/tmp/js-$$.json', JSON.stringify(derive(rows,null)));
"

echo "→ seeding + ingesting via dds_ingest()"
psql -d "$DB" -q <<SQL
insert into auth.users(id) values ('$USR');
insert into public.imports(id,uploaded_by,original_name,status)
  values ('$IMP','$USR','fixture.json','complete');
SQL
python3 - "$ROOT/test/fixture.json" "$IMP" > /tmp/seed-$$.sql <<'PY'
import json,sys
rows=json.load(open(sys.argv[1]))
print("select public.dds_ingest('%s', $json$%s$json$::jsonb);" % (sys.argv[2], json.dumps(rows)))
PY
psql -d "$DB" -q -c "set dds.uid='$USR'" -f /tmp/seed-$$.sql >/dev/null

echo "→ calling dds_metrics()"
command psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$DB" -At \
  -c "set dds.uid='$USR'" \
  -c "select public.dds_metrics();" | tail -n +2 > /tmp/sql-$$.json

echo "→ comparing"
python3 - /tmp/js-$$.json /tmp/sql-$$.json <<'PY'
import json,sys
def norm(o):
    # generatedAt is a clock read; filters echo the input. Neither is derived.
    if isinstance(o,dict):
        return {k:norm(v) for k,v in sorted(o.items()) if k not in ('generatedAt','filters')}
    if isinstance(o,list): return [norm(v) for v in o]
    if isinstance(o,(int,float)) and not isinstance(o,bool): return round(float(o),6)
    return o
js=norm(json.load(open(sys.argv[1]))); sq=norm(json.load(open(sys.argv[2])))
# trend[].operatingHours (0099_dds_metrics_operating_hours.sql) is summed
# from public.minestat_shifts — a separate ingest path derive() has no
# input for at all (its only argument is DDS alert-event rows). Expected
# to exist only on the SQL side; not a drift this test can check.
#
# trend[].actionableRatio/distinctOperators (0103_dds_metrics_trend_
# ratio_and_drivers.sql) are excluded for a different reason: derive()'s
# own per-day `operators` count is keyed on raw OPERATOR text (falling
# back to an 'Unspecified' sentinel for blanks), while the SQL side keys
# distinctOperators on emp_no (excluding null emp_no rows entirely) — two
# different identities over the same rows, not expected to agree numerically.
# JS's own per-day fields for the same reason: `operators` (raw-text
# identity, see above) and `sleep`/`drowsy` (a severity split by
# event-CODE-text regex — dds-state.js's own comment calls these
# "sparkline series only... No existing consumer of trend reads them").
# SQL's trend carries a different, event-COUNT-magnitude severity axis
# instead (criticalUnits/highUnits, 0115_dds_metrics_severity_trend.sql) —
# not the same computation under a different name, a different axis
# entirely (see PENDING_102's A4 finding on the two severity axes).
# trend[].alertsPerOperatingHour/stillArriving are SQL-only for the same
# reason as operatingHours above: both are derived from minestat_shifts
# data (0109/0110), which derive() has no input for at all.
#
# kpis.avgAlertDurationSeconds/trend[].avgDurationSeconds (0161) are SQL-only
# for a different reason than the above: unlike operatingHours, derive()'s
# own DDS-row input DOES carry start/end times an equivalent could be
# computed from — but nothing in this codebase calls derive() for anything
# but the historical local-import preview, which has no consumer for a
# duration figure, so it was never extended to match. SQL-only by omission,
# not by structural impossibility; add a JS-side equivalent if a consumer
# for it in that path ever appears.
for t in (sq.get('trend') or []):
    t.pop('operatingHours', None)
    t.pop('actionableRatio', None)
    t.pop('distinctOperators', None)
    t.pop('alertsPerOperatingHour', None)
    t.pop('criticalUnits', None)
    t.pop('highUnits', None)
    t.pop('stillArriving', None)
    t.pop('avgDurationSeconds', None)
for t in (js.get('trend') or []):
    t.pop('operators', None)
    t.pop('sleep', None)
    t.pop('drowsy', None)
# kpis.distinctOperators: same raw-text-vs-emp_no identity split as above,
# at the whole-period level instead of per-day. kpis.alertsPerOperatingHour
# is SQL-only, same minestat_shifts reason as trend[] above.
for d in (js.get('kpis') or {}), (sq.get('kpis') or {}):
    d.pop('distinctOperators', None)
sq.get('kpis', {}).pop('alertsPerOperatingHour', None)
sq.get('kpis', {}).pop('avgAlertDurationSeconds', None)
# meta.stillArrivingThresholdDays (0110) is a server-side config constant
# (a threshold, not a derived value) with no equivalent concept in a
# one-shot local import; SQL-only by design.
sq.get('meta', {}).pop('stillArrivingThresholdDays', None)
# topOperators/operatorConsistency: whole-array casualties of the same
# raw-text-vs-emp_no identity split as kpis.distinctOperators above — not
# just a few extra/missing fields but a completely different grouping, so
# lengths and contents are never expected to line up. Excluded outright
# rather than diffed field-by-field.
for d in (js, sq):
    d.pop('topOperators', None)
    d.pop('operatorConsistency', None)
# assetConsistency[]/operatorConsistency[]: flagged/severity/severityRank are
# a classification derive() computes inline (applySeverity() in
# dds-state.js) on top of the shared, actually-compared highDayRatio number —
# not a second independent computation of that number itself, so drift here
# isn't the JS/SQL disagreement this test exists to catch. dds_metrics()
# (0142_analytics_associative_cross_filters.sql) deliberately never adds
# them: per dds-state.js's own comment, that was meant to be applied
# client-side over the raw highDayRatio, by both data sources, from one
# shared rule. In practice index.html (the live app) never adopted that
# rule at all — it has zero references to highDayRatio or applySeverity, and
# its own severityBadge() classifies by event-code text, an unrelated axis —
# so this is dead classification logic on the JS side of an otherwise-live
# comparison, not a live drift risk.
for key in ('assetConsistency', 'operatorConsistency'):
    for row in (js.get(key) or []):
        row.pop('flagged', None)
        row.pop('severity', None)
        row.pop('severityRank', None)
def diff(a,b,p=''):
    out=[]
    if isinstance(a,dict) and isinstance(b,dict):
        for k in sorted(set(a)|set(b)):
            if k not in a: out.append(f'{p}.{k}: only in SQL')
            elif k not in b: out.append(f'{p}.{k}: only in JS')
            else: out+=diff(a[k],b[k],f'{p}.{k}')
    elif isinstance(a,list) and isinstance(b,list):
        if len(a)!=len(b): out.append(f'{p}: length JS={len(a)} SQL={len(b)}')
        else:
            for i,(x,y) in enumerate(zip(a,b)): out+=diff(x,y,f'{p}[{i}]')
    elif a!=b: out.append(f'{p}: JS={a!r}  SQL={b!r}')
    return out
d=diff(js,sq)
if d:
    print(f"\n  FAIL — {len(d)} difference(s):")
    for x in d[:30]: print('   ',x)
    sys.exit(1)
print("\n  PASS — JS and SQL produce identical metrics")
PY
rm -f /tmp/js-$$.json /tmp/sql-$$.json /tmp/seed-$$.sql
