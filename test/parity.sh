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
create table if not exists auth.users (id uuid primary key);
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
insert into public.imports(id,uploaded_by,storage_key,original_name,status)
  values ('$IMP','$USR','k/parity','fixture.json','complete');
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
