#!/usr/bin/env bash
# Everything CI runs, run here first.
#
# WHY THIS EXISTS
#
# I pushed four times in a row and CI found something every time: functions
# reachable by anon, a test that passed only because of a gitignored .env, an
# exemption list living in three files where the guard read two, three
# SECURITY DEFINER statements with no school filter, a function granted and
# called from nowhere, and finally a committed bundle that had gone stale.
#
# Every one of those was caught by a check this repository already had. The
# failure was not the code, it was running the checks one at a time and by
# memory, discovering the next one only after the last was fixed. Six round
# trips, each costing a CI run and the reviewer's patience.
#
# So: one command, everything, in the order that fails cheapest first.
#
#   scripts/preflight.sh              full run
#   scripts/preflight.sh --quick      skip the fresh-database rebuilds
#
# It needs a Postgres to talk to:
#   su pguser -c "/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pgd/data \
#     -o '-k /tmp/pgd -p 5455' -l /tmp/pgd/log start"
#   export PGHOST=/tmp/pgd PGPORT=5455 PGUSER=postgres
set -uo pipefail
cd "$(dirname "$0")/.."

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

fails=0
step() {
  printf '%-52s ' "$1"; shift
  if out=$("$@" 2>&1); then
    echo "ok"
  else
    echo "FAIL"
    echo "$out" | tail -12 | sed 's/^/      /'
    fails=$((fails + 1))
  fi
}

echo "== the cheap ones =="
step "bundles are in sync with the migrations" bash -c \
  './supabase/build-bundles.sh >/dev/null && git diff --exit-code --stat supabase/bundles/'
step "no em dashes" python3 scripts/check-no-emdash.py
step "PARITY.md rows are evidenced" python3 scripts/check-parity.py
step "the built site would index correctly" python3 scripts/check-site-seo.py
step "0059 exemption list agrees across three files" python3 supabase/check-exemption-lists.py
step "site links and app entry points" bash supabase/check-site-links.sh

echo
echo "== the app =="
step "typecheck" bash -c 'cd web && npx tsc --noEmit'
step "unit and page tests" bash -c 'cd web && npm test --silent'
step "production build" bash -c 'cd web && npm run build'

echo
echo "== the database, against \$PGDATABASE =="
for g in check-columns-used.sh check-constraint-functions.sh check-reachable.sh check-rpc-contract.sh; do
  step "$g" bash -c "./supabase/$g"
done
step "check-ledger-baseline.sh" bash supabase/check-ledger-baseline.sh
step "check-site-prices.sh" bash supabase/check-site-prices.sh
for g in check-definer-queries.py check-import-keys.py check-readonly-writes.py \
         check-definer-idor.py check-metadata-trust.py check-orphan-queries.py \
         check-print-ids.py; do
  step "$g" python3 "./supabase/$g"
done

if [ "$QUICK" = 0 ]; then
  echo
  echo "== fresh databases, both install paths =="
  # A guard that runs against the database you have been editing all afternoon
  # proves less than one that runs against the database a school will have.
  for mode in migrations bundles; do
    db="preflight_$mode"
    dropdb --if-exists "$db" >/dev/null 2>&1
    createdb "$db" >/dev/null 2>&1
    psql -q -d "$db" -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key, email text,
  raw_user_meta_data jsonb default '{}'::jsonb, raw_app_meta_data jsonb default '{}'::jsonb,
  last_sign_in_at timestamptz, created_at timestamptz default now());
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;
alter default privileges in schema public grant all on tables to postgres, anon, authenticated, service_role;
SQL
    if [ "$mode" = migrations ]; then
      files=$(ls supabase/migrations/*.sql)
    else
      files=$(ls supabase/bundles/*.sql | sort -V)
    fi
    ok=1
    for f in $files; do
      psql -q -d "$db" -v ON_ERROR_STOP=1 -f "$f" >/dev/null 2>/tmp/pf.err || {
        printf '%-52s FAIL\n' "$mode: applying ${f##*/}"; head -4 /tmp/pf.err | sed 's/^/      /'
        fails=$((fails + 1)); ok=0; break
      }
    done
    [ "$ok" = 1 ] && printf '%-52s ok\n' "$mode apply cleanly"

    n=$(psql -tA -d "$db" -c "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and has_function_privilege('anon', p.oid,'execute')" 2>/dev/null)
    if [ "${n:-1}" = 0 ]; then printf '%-52s ok\n' "$mode: anon can execute nothing"
    else printf '%-52s FAIL (%s open)\n' "$mode: anon can execute nothing" "$n"; fails=$((fails + 1)); fi

    v=$(psql -q -d "$db" -f supabase/verify.sql 2>&1 | grep -c 'FAIL')
    if [ "$v" = 0 ]; then printf '%-52s ok\n' "$mode: verify.sql has no FAIL row"
    else printf '%-52s FAIL (%s rows)\n' "$mode: verify.sql has no FAIL row" "$v"; fails=$((fails + 1)); fi

    d=$(psql -q -d "$db" -f supabase/repair/detect.sql 2>&1 | grep -c 'MISSING')
    if [ "$d" = 0 ]; then printf '%-52s ok\n' "$mode: detect.sql has no MISSING row"
    else printf '%-52s FAIL (%s rows)\n' "$mode: detect.sql has no MISSING row" "$d"; fails=$((fails + 1)); fi
  done

  echo
  echo "== every SQL suite, on the fresh migrations database =="
  bad=0
  for t in supabase/tests/*.sql; do
    psql -q -d preflight_migrations -v ON_ERROR_STOP=1 -f "$t" >/dev/null 2>/tmp/pf.err || {
      printf '%-52s FAIL\n' "${t##*/}"; grep -E 'ERROR|FAIL' /tmp/pf.err | head -3 | sed 's/^/      /'
      bad=$((bad + 1)); fails=$((fails + 1))
    }
  done
  [ "$bad" = 0 ] && printf '%-52s ok (%s suites)\n' "all SQL suites" "$(ls supabase/tests/*.sql | wc -l)"
fi

echo
if [ "$fails" = 0 ]; then
  echo "PREFLIGHT CLEAN. Safe to push."
  exit 0
fi
echo "$fails CHECK(S) FAILED. Do not push."
exit 1
