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

# ---------------------------------------------------------------------------
# verify.sql, checked properly.
#
# WHY THIS IS A FUNCTION AND NOT `grep -c FAIL`, WHICH IS WHAT IT WAS
#
# verify.sql is ONE `select ... union all` statement, so an exception anywhere
# in it prints an error and NO ROWS AT ALL. The old check was
#
#     v=$(psql -f supabase/verify.sql 2>&1 | grep -c 'FAIL')
#     [ "$v" = 0 ] && echo ok
#
# and an error message contains no "FAIL", so a report that rendered nothing
# counted as clean. Three checks were reporting ok on empty output.
#
# That was not hypothetical. Two rows in verify.sql called functions that refuse
# a connection with no staff profile -- which is every connection here, and
# every connection from the Supabase SQL editor. They were reached only once a
# bundle had been applied, so the checker went green on exactly the databases it
# was supposed to be watching.
#
# So all three questions are asked: did it error, did it produce the number of
# rows the file contains checks for, and does any row say FAIL.
verify_clean() {                       # verify_clean <db> <label>
  local db="$1" label="$2" out want got errs bad
  out=$(psql -q -d "$db" -f supabase/verify.sql 2>&1)
  want=$(( $(grep -c '^union all' supabase/verify.sql) + 1 ))
  got=$(printf '%s\n' "$out" | sed -n 's/^(\([0-9]\+\) rows\?)$/\1/p' | tail -1)
  errs=$(printf '%s\n' "$out" | grep -c 'ERROR')
  bad=$(printf '%s\n' "$out" | grep -c 'FAIL')
  if [ "$errs" != 0 ]; then
    printf '%-52s FAIL (verify.sql raised, so it printed nothing)\n' "$label"
    printf '%s\n' "$out" | grep -A2 'ERROR' | head -6 | sed 's/^/      /'
    fails=$((fails + 1)); return 1
  fi
  if [ "${got:-0}" != "$want" ]; then
    printf '%-52s FAIL (%s rows, expected %s)\n' "$label" "${got:-0}" "$want"
    fails=$((fails + 1)); return 1
  fi
  if [ "$bad" != 0 ]; then
    printf '%-52s FAIL (%s rows)\n' "$label" "$bad"
    printf '%s\n' "$out" | grep 'FAIL' | head -5 | sed 's/^/      /'
    fails=$((fails + 1)); return 1
  fi
  printf '%-52s ok (%s rows, none failing)\n' "$label" "$got"
}
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
# MATCHED ON THE INVOCATION, NOT THE NAME. This used to grep for the bare
# basename anywhere in ci.yml, so a suite merely MENTIONED in another step's
# comment counted as covered. That is the "the artefact exists, nothing runs it"
# failure the check was written to catch, reproduced inside the check itself.
step "every Edge Function is called, and deployable" python3 scripts/check-edge-functions.py
step "every SQL suite has a CI step that runs it" bash -c '
  fail=0
  for t in supabase/tests/*.sql; do
    b=$(basename "$t")
    grep -qE "^ *run:.*-f +supabase/tests/$b( |$)" .github/workflows/ci.yml || {
      echo "no CI step runs $b"; fail=1; }
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
         check-print-ids.py check-patch-anchors.py; do
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

    verify_clean "$db" "$mode: verify.sql renders and has no FAIL row"

    d=$(psql -q -d "$db" -f supabase/repair/detect.sql 2>&1 | grep -c 'MISSING')
    if [ "$d" = 0 ]; then printf '%-52s ok\n' "$mode: detect.sql has no MISSING row"
    else printf '%-52s FAIL (%s rows)\n' "$mode: detect.sql has no MISSING row" "$d"; fails=$((fails + 1)); fi
  done

  # THE LINE ENDINGS A SCHOOL ACTUALLY HAS.
  #
  # Both installs above feed LF files to the psql CLI. No school does that. A
  # school opens the Supabase SQL editor in a browser and pastes, and what ends
  # up in pg_proc.prosrc is whatever the paste contained -- CRLF, on Windows.
  #
  # A migration that edits a function it did not write has to find its place in
  # that stored text. 0101 found it with position(E'\n  end if;\n' in ...):
  # one line feed, two spaces, `end if;`, one line feed. On an LF database that
  # matches. On a CRLF database it is not there at all, and because the SQL
  # editor runs a pasted file as ONE transaction, the raise took all seven
  # migrations of bundle 12 with it. Twelve bundles, ten CI jobs and this script
  # all said clean, because every one of them was LF end to end.
  echo
  echo "== the same bundles, on a database whose bodies are CRLF =="
  dropdb --if-exists preflight_crlf >/dev/null 2>&1
  createdb preflight_crlf >/dev/null 2>&1
  psql -q -d preflight_crlf -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
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
  rm -rf /tmp/pf-crlf && mkdir -p /tmp/pf-crlf
  for b in supabase/bundles/*.sql; do sed 's/$/\r/' "$b" > "/tmp/pf-crlf/$(basename "$b")"; done
  ok=1
  for b in $(ls /tmp/pf-crlf/*.sql | sort -V); do
    psql -q -d preflight_crlf -v ON_ERROR_STOP=1 --single-transaction -f "$b" >/dev/null 2>/tmp/pf.err || {
      printf '%-52s FAIL\n' "crlf: applying ${b##*/}"; head -4 /tmp/pf.err | sed 's/^/      /'
      fails=$((fails + 1)); ok=0; break
    }
  done
  if [ "$ok" = 1 ]; then
    # The bodies really have to have landed CRLF, or this proves nothing and
    # goes green for the wrong reason.
    stored=$(psql -tA -d preflight_crlf -c "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and position(chr(13) in p.prosrc) > 0" 2>/dev/null)
    if [ "${stored:-0}" -lt 100 ]; then
      printf '%-52s FAIL (%s bodies)\n' "crlf: the bodies are actually stored CRLF" "${stored:-0}"
      fails=$((fails + 1)); ok=0
    else
      printf '%-52s ok (%s bodies)\n' "crlf: bundles apply, bodies stored CRLF" "$stored"
    fi
  fi
  [ "$ok" = 1 ] && verify_clean preflight_crlf "crlf: verify.sql renders and has no FAIL row"

  # WHAT A SCHOOL DOES WHEN IT IS NOT SURE THE PASTE TOOK: paste it again.
  #
  # Bundles that create a type or a table refuse the second paste and roll back
  # whole, which is harmless. What is NOT harmless is a bundle that applies
  # again and leaves a DIFFERENT function behind, because a patch made from a
  # function's own text can append itself twice. That is not theoretical: this
  # check is what found 0042 appending
  # `and school_id = public.current_school_id()` to fn_import_staff's duplicate
  # lookups once per paste, forever.
  #
  # So every body is fingerprinted, every bundle is pasted again, and the
  # fingerprints have to match. A bundle that rolls back is fine; a bundle that
  # succeeds and changes a body is not.
  if [ "$ok" = 1 ]; then
    psql -tA -d preflight_bundles -c "select p.proname||'|'||md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' order by 1" > /tmp/pf-paste1.txt 2>/dev/null
    for b in $(ls supabase/bundles/*.sql | sort -V); do
      psql -q -d preflight_bundles -v ON_ERROR_STOP=1 --single-transaction -f "$b" >/dev/null 2>&1 || true
    done
    psql -tA -d preflight_bundles -c "select p.proname||'|'||md5(p.prosrc) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' order by 1" > /tmp/pf-paste2.txt 2>/dev/null
    if diff -q /tmp/pf-paste1.txt /tmp/pf-paste2.txt >/dev/null; then
      printf '%-52s ok (%s bodies)\n' "re-pasting every bundle changes no function" \
        "$(wc -l < /tmp/pf-paste1.txt | tr -d ' ')"
    else
      printf '%-52s FAIL\n' "re-pasting every bundle changes no function"
      diff /tmp/pf-paste1.txt /tmp/pf-paste2.txt | grep '^[<>]' | head -8 | sed 's/^/      /'
      fails=$((fails + 1))
    fi
  fi

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
    verify_clean preflight_upgrade "upgrade: verify.sql renders, no FAIL row"
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
