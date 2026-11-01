#!/usr/bin/env bash
# =============================================================================
# Does web/src/offline/readRpcs.ts still match the database?
#
# The offline layer answers the RPCs on that list from a saved copy when the
# network fails. That is only safe for a function that cannot write. If a
# migration turns one of them VOLATILE (because it now writes something, an
# audit row, a counter), a screen could be shown "saved" while nothing was
# written. This fails the build the moment the list and the database disagree,
# in either direction.
#
# Usage:  ./supabase/check-read-rpcs.sh
#         (needs PG* env vars pointing at a database with the migrations applied)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp)
cp web/src/offline/readRpcs.ts "$tmp"
if ! ./supabase/gen-read-rpcs.sh > /dev/null; then
  cp "$tmp" web/src/offline/readRpcs.ts
  echo "could not query the database: are PG* env vars set?"
  exit 1
fi
if ! diff -u "$tmp" web/src/offline/readRpcs.ts; then
  cp "$tmp" web/src/offline/readRpcs.ts
  echo
  echo "web/src/offline/readRpcs.ts does not match the database (above: - committed, + database)."
  echo "A function that can now write must never be answered from an offline copy."
  echo "Run ./supabase/gen-read-rpcs.sh against a database with every migration and commit it."
  exit 1
fi
rm -f "$tmp"
echo "every RPC answered from an offline copy is one Postgres guarantees cannot write ($(grep -c "^  '" web/src/offline/readRpcs.ts))"
