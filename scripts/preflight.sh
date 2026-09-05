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
step "no browser dialogs (prompt/alert/confirm)" python3 scripts/check-no-browser-dialogs.py
step "every CI step can find its own files" python3 scripts/check-ci-workdir.py
step "PARITY.md rows are evidenced" python3 scripts/check-parity.py
step "the built site would index correctly" python3 scripts/check-site-seo.py
step "0059 exemption list agrees across three files" python3 supabase/check-exemption-lists.py
step "site links and app entry points" bash supabase/check-site-links.sh

# The install checks must cover every migration on disk. This is a CI step I had
# NOT copied here, and it is what failed the first push this script called
# clean: detect.sql had no row for 0095 or 0096, so "is my database up to date?"
# had quietly stopped answering two migrations ago.
step "verify.sql and detect.sql cover every migration" bash -c '
  fail=0
  for n in 0035 0036 0037 0038 0039 0040 0041 0042 0043 0044 0045 0046 0047 0048 0049; do
    grep -q "'"'"'$n'"'"'" supabase/verify.sql || { echo "verify.sql does not check $n"; fail=1; }
    grep -q "'"'"'${n}_" supabase/repair/detect.sql || { echo "detect.sql does not check $n"; fail=1; }
    test -f "supabase/repair/${n}_"*.sql || { echo "no repair file for $n"; fail=1; }
  done
  for f in supabase/migrations/*.sql; do
    n=$(basename "$f" | cut -c1-4)
    [ "$n" \> "0049" ] || continue
    grep -q "$n" supabase/verify.sql || { echo "verify.sql never mentions $n"; fail=1; }
    grep -q "'"'"'${n}_" supabase/repair/detect.sql || { echo "detect.sql does not check $n"; fail=1; }
  done
  exit $fail'

# A suite nothing runs is a suite that rots. CI asserts every file in
# supabase/tests has a step; so does this, or a new suite can be written, pass
# here, and never run again.
step "every SQL suite has a CI step" bash -c '
  fail=0
  for t in supabase/tests/*.sql; do
    grep -q "$(basename "$t")" .github/workflows/ci.yml || {
      echo "no CI step runs $(basename "$t")"; fail=1; }
  done
  exit $fail'

echo
echo "== the app =="
step "typecheck" bash -c 'cd web && npx tsc --noEmit'
step "unit and page tests" bash -c 'cd web && npm test --silent'
step "production build" bash -c 'cd web && npm run build'
# THE RENDERING HARNESSES. This step was missing, and it is the second time this
# script has printed PREFLIGHT CLEAN on a commit CI then failed.
#
# web/tools/ hands the real components fixture objects typed as the real
# interfaces, and `npm test` deliberately does not run them. Adding two required
# fields to PortalFees left four fixtures missing them; `tsc` said nothing
# because web/tsconfig.json included only src/, and CI failed inside the
# component with "Cannot read properties of undefined (reading 'length')".
# tools/ is typechecked now AND the harnesses run here.
step "rendering harnesses still render" bash -c 'cd web && npm run harness:node20'

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

  # THE UPGRADE A SCHOOL ACTUALLY PERFORMS.
  #
  # Every check above installs from nothing. That is not what a running school
  # does: it already has the earlier bundles and pastes the new one on top. That
  # difference is not academic here, it is the shape of the incident that cost a
  # real school fifteen migrations, and CI carries a step reproducing that exact
  # historical cutoff.
  #
  # This is the simpler, current question: does the NEWEST bundle apply cleanly
  # to a database that already has all the others, and does verify.sql still
  # come back clean afterwards? That is the instruction being handed to a school
  # today, so it is the one worth failing on.
  newest=$(ls supabase/bundles/*.sql | sort -V | tail -1)
  dropdb --if-exists preflight_upgrade >/dev/null 2>&1
  createdb preflight_upgrade >/dev/null 2>&1
  psql -q -d preflight_upgrade -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
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
  ok=1
  for b in $(ls supabase/bundles/*.sql | sort -V); do
    [ "$b" = "$newest" ] && continue
    psql -q -d preflight_upgrade -v ON_ERROR_STOP=1 -f "$b" >/dev/null 2>/tmp/pf.err || {
      printf '%-52s FAIL\n' "upgrade: the school as it was (${b##*/})"
      head -3 /tmp/pf.err | sed 's/^/      /'; fails=$((fails + 1)); ok=0; break
    }
  done
  if [ "$ok" = 1 ]; then
    # ONE transaction, exactly as the SQL Editor runs a pasted file. A bundle
    # that only works statement by statement fails for the school.
    if psql -q -d preflight_upgrade -v ON_ERROR_STOP=1 --single-transaction \
         -f "$newest" >/dev/null 2>/tmp/pf.err; then
      printf '%-52s ok\n' "upgrade: ${newest##*/} onto an existing school"
    else
      printf '%-52s FAIL\n' "upgrade: ${newest##*/} onto an existing school"
      head -5 /tmp/pf.err | sed 's/^/      /'; fails=$((fails + 1)); ok=0
    fi
  fi
  if [ "$ok" = 1 ]; then
    v=$(psql -q -d preflight_upgrade -f supabase/verify.sql 2>&1 | grep -c 'FAIL')
    if [ "$v" = 0 ]; then printf '%-52s ok\n' "upgrade: verify.sql has no FAIL row"
    else printf '%-52s FAIL (%s rows)\n' "upgrade: verify.sql has no FAIL row" "$v"; fails=$((fails + 1)); fi
  fi

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

  # In REVERSE too, which CI also does. A suite that only passes when its
  # predecessor has just run is depending on that predecessor's leftovers, and
  # will fail the day somebody reorders them.
  bad=0
  for t in $(ls supabase/tests/*.sql | sort -r); do
    psql -q -d preflight_migrations -v ON_ERROR_STOP=1 -f "$t" >/dev/null 2>/tmp/pf.err || {
      printf '%-52s FAIL\n' "${t##*/} (reverse order)"
      grep -E 'ERROR|FAIL' /tmp/pf.err | head -3 | sed 's/^/      /'
      bad=$((bad + 1)); fails=$((fails + 1))
    }
  done
  [ "$bad" = 0 ] && printf '%-52s ok\n' "all SQL suites again, in reverse order"
fi

# WHAT THIS SCRIPT STILL DOES NOT RUN.
#
# Printed every time, not hidden behind a flag. The first version said
# "PREFLIGHT CLEAN" on a commit CI then failed, because it silently covered nine
# of the ten multi-line CI steps. A checker that does not say what it skipped is
# claiming more than it checked, which is the same fault as one that lies.
echo
echo "== CI steps this script does NOT run =="
python3 scripts/preflight-gaps.py

echo
if [ "$fails" = 0 ]; then
  echo "PREFLIGHT CLEAN. Safe to push."
  exit 0
fi
echo "$fails CHECK(S) FAILED. Do not push."
exit 1
