#!/usr/bin/env bash
# Does 0069's baseline list still match the migrations on disk?
#
# 0069 seeds public.schema_migrations for a database that already has the schema
# but no ledger. It cannot derive the filenames — a database cannot see the repo
# — so the list is written out in full inside the migration.
#
# A hand-written list of filenames drifts. If it drifts, the ledger reports a
# database as complete while omitting migrations it has, which makes it lie about
# the exact thing it exists to make true: an operator reading "69 of 69 applied"
# would skip a repair the database actually needs. That is worse than no ledger,
# because it is confidently wrong.
#
# So: every migration up to and including the one that OWNS the baseline must
# appear in the list, and nothing else may.
#
# Run: bash supabase/check-ledger-baseline.sh
set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE=supabase/migrations/0069_migration_ledger.sql
OWNER=0069_migration_ledger.sql

if [ ! -f "$BASELINE" ]; then
  echo "MISSING: $BASELINE"
  exit 1
fi

# Filenames quoted inside the v_files array. Bounded to the array by taking only
# the do-block that declares it, so a filename mentioned in a comment elsewhere
# in the file cannot count as being in the list.
listed=$(sed -n '/v_files   text\[\] := array\[/,/\];/p' "$BASELINE" \
           | grep -oE "'[0-9]{4}_[A-Za-z0-9_]+\.sql'" | tr -d "'" | sort)

# Every migration up to and including the baseline's own file. Later migrations
# are deliberately NOT in the list: they had not been written when the baseline
# was defined, and a database being adopted cannot have them.
ondisk=$(cd supabase/migrations && ls *.sql | awk -v o="$OWNER" '$0 <= o' | sort)

missing=$(comm -13 <(echo "$listed") <(echo "$ondisk"))
extra=$(comm -23 <(echo "$listed") <(echo "$ondisk"))

fail=0
if [ -n "$missing" ]; then
  echo "MIGRATIONS MISSING FROM 0069's BASELINE LIST:"
  echo "$missing" | sed 's/^/  /'
  echo
  echo "A database adopted by 0069 would be recorded as complete while these"
  echo "were never recorded. Add them to v_files in $BASELINE."
  fail=1
fi
if [ -n "$extra" ]; then
  echo "NAMES IN 0069's BASELINE LIST THAT ARE NOT MIGRATIONS:"
  echo "$extra" | sed 's/^/  /'
  echo
  echo "The ledger would claim a file was applied that does not exist."
  fail=1
fi
[ "$fail" = 0 ] || exit 1

echo "ok: 0069's baseline lists exactly the $(echo "$ondisk" | wc -l | tr -d ' ') migrations up to $OWNER"

# --- And every bundle must record exactly its own migrations ------------------
# build-bundles.sh generates the recording block, so this cannot drift by hand —
# but it CAN drift if the generator is edited, and the failure is silent: the
# bundle applies perfectly and the ledger is simply missing rows. Nothing else
# would notice.
fail=0
for b in supabase/bundles/*.sql; do
  files=$(grep -oE '^-- [0-9]{4}_[A-Za-z0-9_]+\.sql$' "$b" | sed 's/^-- //' | sort)
  recorded=$(grep -oE "fn_record_migration\('[0-9]{4}_[A-Za-z0-9_]+\.sql'" "$b" \
               | sed "s/.*('//;s/'//" | sort)
  if [ "$files" != "$recorded" ]; then
    echo "BUNDLE DOES NOT RECORD ITS OWN CONTENTS: $b"
    diff <(echo "$files") <(echo "$recorded") | sed 's/^/  /' || true
    fail=1
  fi
done
[ "$fail" = 0 ] || {
  echo
  echo "Re-run supabase/build-bundles.sh."
  exit 1
}
echo "ok: every bundle records exactly the migrations it carries"
