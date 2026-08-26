#!/usr/bin/env bash
# =============================================================================
# Does every RPC the app calls actually exist, with the parameters it passes?
#
# WHY THIS EXISTS
#
# CI applies the migrations and runs the SQL suites, and the web job typechecks
# and builds. Neither one looks at the SEAM between them: `sb.rpc('fn_x', {...})`
# is an untyped string and an untyped object, so a renamed function or a changed
# parameter name compiles, deploys, and fails the first time a school opens the
# screen.
#
# That is not hypothetical. Both of these shipped and were caught by hand:
#
#   * publishResults passed `p_term_id`; the function takes `p_exam_term_id`.
#   * A test called fn_record_expense with its arguments in the wrong order.
#
# A migration can rename a parameter and every check will stay green.
#
# WHAT IT DOES
#
# Extracts every `.rpc('name', { p_x: ..., p_y: ... })` from web/src/lib/db.ts,
# then for each one asks the database whether a function of that name exists and
# whether every parameter passed is one the function actually accepts.
#
# Deliberately one-directional: it flags parameters the app sends that the
# function does not have, NOT parameters the function has that the app omits —
# those are usually defaults, which is legitimate.
#
# Usage:  ./supabase/check-rpc-contract.sh
#         (needs PG* env vars pointing at a database with the migrations applied)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

DB_FILE=web/src/lib/db.ts
[ -f "$DB_FILE" ] || { echo "cannot find $DB_FILE"; exit 1; }

# --- what the database offers -------------------------------------------------
# name<TAB>comma-separated parameter names
# name<TAB>params<TAB>can `authenticated` execute it
#
# The third column exists because of fn_exam_marksheet. The app has called it
# from db.ts:1388 since 0015 and it never had a grant to `authenticated` — it
# worked only because Postgres grants EXECUTE to PUBLIC on every new function by
# default. So the app's whole RPC surface was resting partly on a default nobody
# had decided on, and the day that default is tightened the marksheet screen
# breaks at runtime on the first school that opens it. Exactly the seam this
# script exists for.
psql -tAF$'\t' -c "
  select p.proname,
         coalesce(string_agg(a.name, ',' order by a.ord), ''),
         -- NO ::text here. psql renders a boolean as t/f, but ::text renders
         -- it as true/false, and the comparison below is against 't'. The first
         -- version had the cast and therefore reported all 137 RPCs as
         -- unexecutable — a guard that cries wolf gets ignored, and then it
         -- protects nothing. Caught by looking at /tmp/rpc_db.tsv, not at the
         -- output.
         bool_or(has_function_privilege('authenticated', p.oid, 'execute'))
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  left join lateral (
    select unnest(p.proargnames) as name,
           generate_subscripts(p.proargnames, 1) as ord
  ) a on true
  where n.nspname = 'public'
  group by p.proname, p.oid;
" > /tmp/rpc_db.tsv || { echo "could not query the database — are PG* env vars set?"; exit 1; }

# --- what the app calls -------------------------------------------------------
# One line per call: name<TAB>param<TAB>param...
python3 - "$DB_FILE" > /tmp/rpc_app.tsv <<'PY'
import re, sys

src = open(sys.argv[1]).read()
out = []

for m in re.finditer(r"\.rpc\(\s*'([a-z0-9_]+)'\s*(,)?", src):
    name = m.group(1)
    params = []
    if m.group(2):
        # Walk from the comma to the matching close paren of the .rpc( call so
        # nested braces and objects do not truncate the argument.
        i = m.end()
        depth = 1  # we are inside .rpc(
        arg = []
        while i < len(src) and depth > 0:
            c = src[i]
            if c in '([{':
                depth += 1
            elif c in ')]}':
                depth -= 1
                if depth == 0:
                    break
            arg.append(c)
            i += 1
        blob = ''.join(arg)
        # Only top-level keys of the first object literal are parameters.
        first = blob.find('{')
        if first != -1:
            d = 0
            keys = []
            j = first
            while j < len(blob):
                c = blob[j]
                if c == '{':
                    d += 1
                elif c == '}':
                    d -= 1
                    if d == 0:
                        break
                elif d == 1:
                    k = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:", blob[j:])
                    if k:
                        keys.append(k.group(1))
                        j += k.end() - 1
                j += 1
            params = keys
    out.append('\t'.join([name] + params))

for line in sorted(set(out)):
    print(line)
PY

# --- compare -----------------------------------------------------------------
fail=0
checked=0
missing_fns=()
bad_params=()
not_executable=()

while IFS=$'\t' read -r -a parts; do
  fn="${parts[0]}"
  checked=$((checked + 1))

  db_line=$(grep -P "^${fn}\t" /tmp/rpc_db.tsv | head -1 || true)
  if [ -z "$db_line" ]; then
    missing_fns+=("$fn")
    fail=1
    continue
  fi

  db_params=$(printf '%s' "$db_line" | cut -f2)

  # Can a signed-in user actually CALL it? A function that exists with the right
  # parameters but no grant fails at runtime with "permission denied for
  # function", which looks nothing like a missing function and sends whoever
  # debugs it looking in the wrong place.
  if [ "$(printf '%s' "$db_line" | cut -f3)" != "t" ]; then
    not_executable+=("$fn")
    fail=1
  fi

  for ((i = 1; i < ${#parts[@]}; i++)); do
    p="${parts[$i]}"
    [ -z "$p" ] && continue
    if ! printf '%s' ",$db_params," | grep -q ",$p,"; then
      bad_params+=("$fn passes '$p' — accepts: ${db_params:-（none）}")
      fail=1
    fi
  done
done < /tmp/rpc_app.tsv

echo "checked $checked RPC call sites in $DB_FILE"

if [ ${#missing_fns[@]} -gt 0 ]; then
  echo
  echo "FUNCTIONS THE APP CALLS THAT DO NOT EXIST:"
  printf '  %s\n' "${missing_fns[@]}"
fi

if [ ${#bad_params[@]} -gt 0 ]; then
  echo
  echo "PARAMETERS THE APP PASSES THAT THE FUNCTION DOES NOT ACCEPT:"
  printf '  %s\n' "${bad_params[@]}"
fi

if [ ${#not_executable[@]} -gt 0 ]; then
  echo
  echo "FUNCTIONS THE APP CALLS THAT \`authenticated\` CANNOT EXECUTE:"
  printf '  %s\n' "${not_executable[@]}"
  echo
  echo "Add: grant execute on function public.<name>(<arg types>) to authenticated;"
  echo "Do NOT rely on the PUBLIC default — 0071 revokes it, because it also"
  echo "handed every function to the unauthenticated anon role."
fi

if [ $fail -eq 0 ]; then
  echo "every RPC call matches a real function and real parameter names"
else
  echo
  echo "These would fail at RUNTIME, on the first school that opens the screen."
  exit 1
fi
