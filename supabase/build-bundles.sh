#!/usr/bin/env bash
# Regenerate supabase/bundles/ from supabase/migrations/.
#
# Loading 35 files by hand into the Supabase SQL Editor is where setups go
# wrong: it is easy to lose your place, and re-running a file you already ran
# fails with a confusing "already exists" error. These bundles reduce it to
# three pastes.
#
# WHY THREE AND NOT ONE: the SQL Editor runs each paste as ONE transaction, and
# Postgres forbids USING a new enum value in the transaction that added it.
# 0032 adds 'parent' to user_role and 0033 onwards compare against it, so the
# split has to fall exactly there. Do not merge the bundles.
#
# Run after adding or renaming any migration. CI fails if the committed
# bundles do not match the migrations.
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
