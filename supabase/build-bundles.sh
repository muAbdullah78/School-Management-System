#!/usr/bin/env bash
# Regenerate supabase/bundles/ from supabase/migrations/.
#
# Loading four dozen files by hand into the Supabase SQL Editor is where setups
# go wrong: it is easy to lose your place, and re-running a file you already ran
# fails with a confusing "already exists" error. These bundles reduce it to
# four pastes.
#
# WHY THREE AND NOT ONE: the SQL Editor runs each paste as ONE transaction, and
# Postgres forbids USING a new enum value in the transaction that added it.
# 0032 adds 'parent' to user_role and 0033 onwards compare against it, so the
# split has to fall exactly there. Do not merge the bundles.
#
# Run after adding or renaming any migration. CI fails if the committed bundles
# do not match the migrations.
#
# THE GAP THIS SCRIPT USED TO HAVE
#
# The globs below stopped at 0039, so migrations 0040-0046 were in NO bundle.
# CI did not notice, because its check only regenerates the bundles and diffs
# them — with 0040+ outside every glob, the regenerated output matched the
# committed output perfectly and the check stayed green. A school installing
# from the bundles got a database seven migrations behind the app, and every
# screen calling a function from those migrations failed at runtime.
#
# So the coverage assertion at the bottom of this script is not decoration: it
# is the thing that makes the diff check mean anything. Every migration must
# land in exactly one bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

emit() {                       # emit <output> <first-file-glob-index> <files...>
  local out="$1"; shift
  {
    echo "-- ============================================================================="
    echo "-- GENERATED FILE — DO NOT EDIT."
    echo "-- Built from supabase/migrations/ by supabase/build-bundles.sh"
    echo "--"
    echo "-- Paste this whole file into the Supabase SQL Editor and press Run."
    echo "-- Run the bundles in order, one at a time, waiting for each to finish."
    echo "-- ============================================================================="
    echo
    for f in "$@"; do
      echo
      echo "-- ─────────────────────────────────────────────────────────────────────────"
      echo "-- $(basename "$f")"
      echo "-- ─────────────────────────────────────────────────────────────────────────"
      cat "$f"
    done
  } > "$out"
  echo "  wrote $out ($(wc -l < "$out") lines)"
}

echo "Building bundles:"
emit supabase/bundles/1_core.sql          supabase/migrations/00[0-2]*.sql supabase/migrations/003[01]*.sql
emit supabase/bundles/2_parent_role.sql   supabase/migrations/0032_*.sql
emit supabase/bundles/3_portal.sql        supabase/migrations/003[3-9]*.sql
emit supabase/bundles/4_operations.sql    supabase/migrations/004*.sql

# --- Every migration must be in exactly one bundle ---------------------------
# Without this, adding 0047 silently produces an install that is one migration
# behind and CI stays green. Compares by FILENAME, which each bundle stamps in
# its own section header.
missing=()
for f in supabase/migrations/*.sql; do
  b=$(basename "$f")
  hits=$(grep -l -F -x -- "-- $b" supabase/bundles/*.sql 2>/dev/null | wc -l)
  if [ "$hits" -ne 1 ]; then
    missing+=("$b (in $hits bundles, expected 1)")
  fi
done

if [ ${#missing[@]} -gt 0 ]; then
  echo
  echo "MIGRATIONS NOT IN EXACTLY ONE BUNDLE:"
  printf '  %s\n' "${missing[@]}"
  echo
  echo "A school installs from supabase/bundles/. A migration outside every bundle"
  echo "never reaches a real database, and the app calls functions that do not exist."
  echo "Add a glob above to cover it."
  exit 1
fi
echo "  every one of $(ls supabase/migrations/*.sql | wc -l) migrations is in exactly one bundle"
