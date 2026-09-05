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
      # An UNMATCHED glob arrives here verbatim, because this script does not set
      # nullglob and bash passes a pattern that matched nothing through as text.
      # A bundle may legitimately name a range that is not full yet — bundle 6
      # claims 006* before any 0060 exists — so skip the literal pattern rather
      # than dying on `cat: no such file`.
      #
      # Matching on '*' and not on "file missing": a real migration that has been
      # DELETED must still be a hard error, and no filename contains an asterisk.
      case "$f" in *'*'*) continue ;; esac
      echo
      echo "-- ─────────────────────────────────────────────────────────────────────────"
      echo "-- $(basename "$f")"
      echo "-- ─────────────────────────────────────────────────────────────────────────"
      cat "$f"
    done

    # --- The bundle records itself -------------------------------------------
    # 0069 added public.schema_migrations because nothing recorded what a given
    # database had actually had applied — see that file's header for the two
    # times guessing went wrong. A ledger nobody writes to is no better, so
    # every bundle stamps its own contents on the way out.
    #
    # GENERATED, not hand-written, for the reason the coverage check below
    # exists: a list maintained by hand drifts from the list of files, and then
    # the ledger lies about the very thing it was added to make true.
    #
    # to_regprocedure(), never ::regproc. It returns NULL for a missing function
    # where the cast RAISES — and this block MUST be a no-op on a database that
    # has not reached 0069 yet. Bundle 1 is pasted into an empty database where
    # fn_record_migration cannot exist, and a cast there would abort the paste
    # that creates the entire schema.
    echo
    echo "-- ─────────────────────────────────────────────────────────────────────────"
    echo "-- Record what this bundle applied (no-op before 0069 creates the ledger)"
    echo "-- ─────────────────────────────────────────────────────────────────────────"
    echo "do \$ledger\$"
    echo "begin"
    echo "  if to_regprocedure('public.fn_record_migration(text,text,text)') is null then"
    echo "    raise notice 'migration ledger not present yet — nothing recorded';"
    echo "    return;"
    echo "  end if;"
    for f in "$@"; do
      case "$f" in *'*'*) continue ;; esac
      echo "  perform public.fn_record_migration('$(basename "$f")', '$(basename "$out")');"
    done
    echo "end \$ledger\$;"
  } > "$out"
  echo "  wrote $out ($(wc -l < "$out") lines)"
}

# --- Every migration must END with a terminated statement ---------------------
# A bundle CONCATENATES the migrations. A file whose last statement has no
# trailing semicolon still applies on its own, because psql flushes the buffer at
# EOF — but in a bundle its closing $function$ runs straight into the next file's
# CREATE and the whole paste dies with "syntax error at or near CREATE".
#
# That happened: 0051 and 0052 were generated from pg_get_functiondef(), which
# emits no terminator. Both were valid alone and broke bundle 5. Checking here
# means generation fails rather than the school-facing artefact silently
# breaking, which is a better place to find out than CI.
unterminated=()
for f in supabase/migrations/*.sql; do
  last=$( { grep -vE '^[[:space:]]*(--.*)?$' "$f" || true; } | tail -1 )
  case "$last" in
    *\;) ;;
    *) unterminated+=("$(basename "$f") — last code line: ${last}") ;;
  esac
done
if [ ${#unterminated[@]} -gt 0 ]; then
  echo "MIGRATIONS WHOSE LAST STATEMENT IS NOT TERMINATED:"
  printf '  %s\n' "${unterminated[@]}"
  echo
  echo "Each of these applies fine alone and BREAKS the bundle it lands in,"
  echo "because a bundle concatenates the files. Add the missing semicolon."
  exit 1
fi

# Clear the directory first. The coverage check below inspects the bundle FILES
# on disk, so a stale bundle left over from a deleted glob would satisfy it and
# the check would pass while the script no longer generates that bundle at all.
# Confirmed by dropping a glob and watching the guard stay green until the stale
# file was removed by hand.
rm -f supabase/bundles/*.sql

echo "Building bundles:"
emit supabase/bundles/1_core.sql          supabase/migrations/00[0-2]*.sql supabase/migrations/003[01]*.sql
emit supabase/bundles/2_parent_role.sql   supabase/migrations/0032_*.sql
emit supabase/bundles/3_portal.sql        supabase/migrations/003[3-9]*.sql
emit supabase/bundles/4_operations.sql    supabase/migrations/004*.sql
# A FIFTH bundle rather than widening bundle 4's glob: a school that has already
# pasted bundle 4 must not be told to paste it again, because re-running a
# migration fails with "already exists". New work goes in a new bundle.
#
# The glob is 005*, so bundle 5 is "everything from 0050 onwards" and the name
# undersells it — 0053 (staff leaving) rides along with search and birthdays.
# That is deliberate: the filename is what SETUP.md tells schools to paste, so
# renaming it would break every existing set of instructions to save a word.
# When bundle 5 has itself shipped widely, start a sixth rather than widen this.
emit supabase/bundles/5_search.sql        supabase/migrations/005[0-6]*.sql
# A SIXTH bundle, for the same reason there was a fifth: bundle 5 has already
# been pasted into a live database, so it is frozen and its glob was narrowed to
# 005[0-6] — the exact set the MANIFEST records — rather than left as 005*, which
# would have silently swallowed 0057 and broken that school's upgrade path for
# the third time.
#
# NOW FROZEN, AND LATE.
#
# The paragraph that used to sit here said "its line goes into the manifest at
# the moment it is handed to a school, and from then on it is frozen". Bundle 6
# was handed to a school and the line was never added, so between then and now
# the glob 006* silently absorbed 0064, 0065, 0066 and 0067 — the third time a
# shipped bundle has changed underneath somebody, and the exact failure the
# MANIFEST was written to stop.
#
# It is frozen here at 005[7-9] + 006[0-7], which is what the file contains as
# handed over, and its line is in the MANIFEST from this commit. The glob is
# narrowed to a closed range rather than left open, because "remember to freeze
# it later" is what failed twice.
emit supabase/bundles/6_photos_and_records.sql \
     supabase/migrations/005[7-9]*.sql supabase/migrations/006[0-7]*.sql

# A SEVENTH bundle, because bundle 6 is frozen above. 0068 (the licence-nag
# timing fix) and 0069 (the migration ledger) go here.
#
# From this bundle onward the ledger exists, so a paste records itself and the
# question "what does production have?" stops being archaeology. This is the
# bundle that has to be pasted for that to start being true.
#
# NOW FROZEN. Bundle 7 has been pasted into a live project, so from this commit
# its glob is a CLOSED range and its line is in the MANIFEST. The open `008*`
# that used to sit here would have swallowed 0090 and changed a file a school
# had already run — the fourth time that would have happened, and the exact
# failure the MANIFEST exists to stop.
emit supabase/bundles/7_ledger_and_limits.sql \
     supabase/migrations/006[89]*.sql supabase/migrations/007*.sql \
     supabase/migrations/008[0-9]*.sql

# An EIGHTH bundle, because bundle 7 is frozen above.
#
# 0090 is a repair: 0067's backfill walked `subscriptions` and wrote a row keyed
# to `schools`, so one subscription whose school no longer existed took the whole
# of bundle 6 down with it — eleven migrations discarded to recount a number.
# This bundle restates 0067's machinery so a database that hit that gets it, puts
# back the foreign key that should have made the orphan impossible, and sweeps
# the internal-helper grants.
#
# NOW FROZEN, on the day it was pasted. Its glob was `009*`, which would have
# swallowed 0091 and changed a file that had already been run — the fifth time.
# Freezing it the moment it ships is the only version of this rule that has ever
# worked; "remember to freeze it later" has failed every time it was tried.
emit supabase/bundles/8_counter_repair.sql \
     supabase/migrations/0090*.sql

# A NINTH bundle, because bundle 8 is frozen above.
#
# 0091 finishes what 0090 could not see. The subscriptions -> schools foreign key
# was present the whole time and NOT VALID: it refused every new orphan and had
# never checked the rows already there, so the diagnostic reported an orphan and
# "ok, the constraint is there" in the same output, two answers that cannot both
# be true of an enforced constraint.
#
# NOW FROZEN, and it took a sixth occurrence of the same mistake to get here.
# Its glob was `0091*.sql 009[2-9]*.sql`, and there was no MANIFEST line to stop
# it, so when 0093 was written the glob quietly swallowed it into a file that
# had ALREADY BEEN PASTED into a live database. A bundle is one transaction: a
# school re-running the changed file to pick up 0093 would re-run 0091 and 0092
# as well, and any statement in those that is not re-runnable rolls the whole
# thing back, 0093 included. That is precisely how bundle 3 cost a real school
# fifteen migrations.
#
# Every bundle from here gets its glob pinned to exactly what it shipped with,
# and a MANIFEST line, on the same day.
emit supabase/bundles/9_validate_constraints.sql \
     supabase/migrations/0091*.sql supabase/migrations/0092*.sql

# A TENTH bundle, because bundle 9 is frozen above.
#
# 0093 is the review system: the table, the eligibility rules, the two public
# views the website reads with no login, and the operator's narrow power to hide
# one for abuse. Nothing in it touches an existing table, so a school that never
# runs it loses reviews and nothing else.
emit supabase/bundles/10_reviews.sql \
     supabase/migrations/0093*.sql

# 0094 is deletion: the rules for when a record may be removed and when it may
# only be archived, and the exact list of what is standing in the way when it
# may not. 0095 is the other half of the same complaint: a login that was never
# attached to a staff record appeared on NO screen, because the roster reads the
# staff table, so creating a teacher login left the roster saying "No staff yet". Before it, nothing in this product could be deleted at all, so a
# name typed in wrong stayed on the roster for ever. It adds functions only and
# alters no existing table, so applying it changes nothing until somebody
# presses Delete.
emit supabase/bundles/11_deletion_and_logins.sql \
     supabase/migrations/0094*.sql supabase/migrations/0095*.sql \
     supabase/migrations/0096*.sql supabase/migrations/0097*.sql

# 0098 and 0099 are the same complaint twice: the application answered one
# question with several numbers. "What are we owed" came back as Rs 8,350,
# Rs 8,100 or Rs 8,062.50 depending on which screen was open, and "how many
# children are here" as three counts, two of which were wrong in opposite
# directions. Both add functions and rewrite existing ones; neither alters a
# table, so applying them changes what the screens SAY and nothing that is
# stored.
emit supabase/bundles/12_one_number.sql \
     supabase/migrations/0098*.sql supabase/migrations/0099*.sql

# --- SHIPPED BUNDLES ARE FROZEN ----------------------------------------------
# This is the check that was missing, and its absence cost a real school fifteen
# migrations.
#
# Bundle 3's glob is 003[3-9]*. When it shipped it matched {0033, 0034}. As
# migrations 0035-0039 were written the SAME glob silently swallowed them, so the
# file a school had already pasted changed underneath them. Re-running it fails on
# 0033's "column family_id already exists", and because a bundle is ONE
# transaction the whole thing rolls back — 0035-0039 never arrive. Bundle 4 then
# cannot apply either, because it needs fee_structures.effective_from from 0035.
#
# The comment above bundle 5 already said "New work goes in a new bundle". A glob
# is not a promise. This manifest is.
MANIFEST=supabase/bundles/MANIFEST
if [ -f "$MANIFEST" ]; then
  fail=0
  while IFS='|' read -r bundle files; do
    [ -z "${bundle:-}" ] && continue
    now=$(grep -oE '^-- [0-9]{4}_[A-Za-z0-9_]+\.sql$' "$bundle" 2>/dev/null \
            | sed 's/^-- //' | tr '\n' ' ' | sed 's/ $//')
    if [ "$now" != "$files" ]; then
      echo "FROZEN BUNDLE CHANGED: $bundle"
      echo "  manifest: $files"
      echo "  now:      $now"
      fail=1
    fi
  done < "$MANIFEST"
  if [ "$fail" = 1 ]; then
    echo
    echo "A bundle a school has already pasted must never change. Put the new"
    echo "migrations in a NEW bundle and add a line to $MANIFEST."
    exit 1
  fi
  echo "  frozen bundles unchanged (per $MANIFEST)"
fi

# --- Every migration must be in exactly one bundle ---------------------------
# Without this, adding 0047 silently produces an install that is one migration
# behind and CI stays green. Compares by FILENAME, which each bundle stamps in
# its own section header.
# `|| true` inside the substitution is load-bearing. This script runs under
# `set -euo pipefail`, and grep exits 1 when it finds nothing — which is exactly
# the condition being detected. Without it, the script died SILENTLY on the
# first uncovered migration: exit 1, no message, the guard reporting nothing at
# all on the one case it exists for. Found by tracing it, not by reading it.
missing=()
for f in supabase/migrations/*.sql; do
  b=$(basename "$f")
  hits=$( { grep -l -F -x -- "-- $b" supabase/bundles/*.sql 2>/dev/null || true; } | wc -l )
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
