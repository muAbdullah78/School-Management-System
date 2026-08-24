#!/bin/bash
# =============================================================================
# CAN A SIGNED-IN USER ACTUALLY WRITE THE TABLES?
#
# A CHECK constraint's function runs with the privileges of whoever is writing
# the row — not the table's owner, not the function's owner. A constraint that
# calls a function `authenticated` cannot execute makes the table completely
# unwritable by every signed-in user, and the error says "permission denied for
# function ..." rather than anything about the table.
#
# THIS HAPPENED. 0057 added a CHECK on students.photo_path, staff.photo_path and
# school_settings.logo_path calling fn_photo_path_ok, then revoked that function
# from PUBLIC — which is the grant Postgres gives new functions by default and
# was the only reason it worked — without granting it to authenticated. The
# result:
#
#   set local role authenticated;
#   insert into public.students (...) values (...);
#   ERROR:  permission denied for function fn_photo_path_ok
#
# Admitting a child. Adding a teacher. Saving the school's own address. Three
# tables, and the three most ordinary operations in the system.
#
# Nothing caught it because every suite writes those tables AS THE TABLE OWNER,
# and the owner bypasses both RLS and function-privilege checks. The constraint
# itself was well tested — from a position where the privilege question cannot
# arise.
#
# So this asks the question the tests could not: for every CHECK constraint in
# `public`, can `authenticated` execute the functions it names?
#
# Needs PGHOST/PGPORT/PGUSER/PGDATABASE pointing at a migrated database.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

psql -tA -v ON_ERROR_STOP=1 > /tmp/constraint_fns.txt <<'SQL'
with cons as (
  select con.oid, con.conname, rel.relname as tbl, pg_get_constraintdef(con.oid) as def
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace n on n.oid = rel.relnamespace
  where n.nspname = 'public' and con.contype = 'c' and rel.relkind = 'r'
),
fns as (
  select p.oid, p.proname
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
)
select c.tbl || '|' || c.conname || '|' || f.proname || '|'
       || case when has_function_privilege('authenticated', f.oid, 'EXECUTE')
               then 'ok' else 'DENIED' end
  from cons c
  join fns f on c.def like '%' || f.proname || '(%'
 group by c.tbl, c.conname, f.proname, f.oid
 order by 1;
SQL
if [ $? -ne 0 ]; then
  echo "could not query the database — are PG* env vars set?"
  exit 1
fi

checked=0
denied=()
while IFS='|' read -r tbl con fn verdict; do
  [ -z "${tbl:-}" ] && continue
  checked=$((checked + 1))
  if [ "$verdict" = "DENIED" ]; then
    denied+=("$tbl.$con calls $fn(), which authenticated cannot execute")
  fi
done < /tmp/constraint_fns.txt

if [ "${#denied[@]}" -gt 0 ]; then
  echo
  echo "TABLES A SIGNED-IN USER CANNOT WRITE AT ALL:"
  for d in "${denied[@]}"; do echo "  $d"; done
  echo
  echo "A CHECK constraint's function runs as the WRITING user. Grant it:"
  echo "  grant execute on function public.<fn>(<args>) to authenticated;"
  echo
  echo "Do not 'fix' this by dropping the constraint — the constraint is the"
  echo "point. And do not assume a passing test suite disagrees: suites that"
  echo "write as the table owner bypass this check entirely."
  exit 1
fi

echo "checked $checked constraint(s) that call a public function"
echo "every table with a function-backed CHECK is writable by a signed-in user"
