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
# stored. 0100 finishes what 0097 started: the attendance percentage now exists
# in exactly one function instead of four correct copies, because all four were
# correct on the day they were written and two of them later were not. 0101
# makes the four functions that take a list of rows refuse a key they do not
# read, instead of dropping it: two of them were losing a practical mark or an
# absence flag in silence. 0102 is the same fault in the cash drawer: two
# functions moved cash without telling the till, so a clerk who reversed a
# receipt and took an admission fee could not close their drawer without
# explaining a shortfall the software had created. 0103 is the last of the same
# family: a refundable deposit is the family's money, and it appeared on the
# balance sheet as a liability and on no page the family could open. 0104 is the
# parent-side twin of 0095: a parent login whose family link was never written
# appeared on no screen at all, so the parent saw an empty portal with their own
# name on it and the office had nothing to look at.
#
# NOW FROZEN. Bundle 12 has been pasted into a live school, so its glob stays
# the closed list below and its line stays in the MANIFEST. New work goes in
# bundle 13. This one shipped with a closed list from the start, which is the
# first time in this repository that has been true of a bundle at the moment it
# was handed over.
emit supabase/bundles/12_one_number.sql \
     supabase/migrations/0098*.sql supabase/migrations/0099*.sql \
     supabase/migrations/0100*.sql supabase/migrations/0101*.sql \
     supabase/migrations/0102*.sql supabase/migrations/0103*.sql \
     supabase/migrations/0104*.sql

# A THIRTEENTH bundle, because bundle 12 is frozen above.
#
# 0105 is the parent's half of the attendance number. A day marked `Leave`
# counts against the percentage exactly as absence does, which is right -- the
# figure has to answer "how much of the year was this child here" to carry the
# 75% board-exam rule -- but neither surface a parent looks at ever said so. The
# school granted fifteen days and then sent home a card reading 88.9% with no
# explanation, and the clerk at the counter had nothing printed to settle it
# with. Both parent surfaces now carry the leave figure.
emit supabase/bundles/13_the_leave_the_school_approved.sql \
     supabase/migrations/0105*.sql

# A FOURTEENTH bundle. Bundle 13 has been pasted into a live school, so it is
# frozen above and this is where new work goes.
#
# 0106 closes two holes that both cost money and neither of which anybody in a
# school would ever report. The console's "+14d trial" button added a fortnight
# per press, with no confirmation and no ceiling, against a function whose own
# comment warned that an unbounded extend button becomes a free tier. And the
# parent portal, being a separate route outside the browser's licence gate,
# answered in full for a school that had stopped paying: fees, attendance and
# results, for every family, indefinitely. The office is deliberately NOT locked
# out of its own records, which is 0026's rule and stays.
emit supabase/bundles/14_the_unpaid_school.sql \
     supabase/migrations/0106*.sql supabase/migrations/0107*.sql

# A FIFTEENTH bundle. Bundle 14 has been pasted into a live school, so it is
# frozen above and this is where new work goes.
#
# 0108 is the other half of 0106. Closing an unpaid school changed what the word
# "cancelled" means, and the operator console was never told: it still printed
# 0079's sentence promising that a cancelled or archived school's staff can sign
# in, read, print and export, which stopped being true the day 0106 shipped. It
# also had no way to undo a cancellation at all, on a dialog whose own heading
# offers the things you can do to a school SHORT of destroying it, so the one
# irreversible control on that screen was the cheapest one to press by mistake.
emit supabase/bundles/15_the_one_way_door.sql \
     supabase/migrations/0108*.sql

# A SIXTEENTH bundle. 15 is frozen above.
#
# 0109 is the correction to 0108's own sweep. That migration enumerated every
# action name in this schema with a grep whose character class had no dot in it,
# so the three call sites in 0094 - student.deleted, staff.deleted,
# login.deleted - matched nothing and were never seen. The console printed them
# raw. The naming was hiding the larger fault: all three are called by the
# SCHOOL'S OWN OFFICE and written into the table whose reader is titled "what we
# have done to this school", so a principal deleting a duplicate pupil appeared
# in the vendor's audit feed as something the vendor had done.
#
# 0110 rides with it because the two were found together: making 0109 change a
# return type stopped bundle 7 re-applying, and that turned out to be the only
# thing putting fn_may_mark_subject back after bundle 6's rewrite loop had
# converted the gate for entering marks into one that admits the readonly role.
# 0109 was rewritten to be purely additive; 0110 closes the hole underneath,
# which luck had been covering.
emit supabase/bundles/16_who_actually_did_it.sql \
     supabase/migrations/0109*.sql supabase/migrations/0110*.sql

# A SEVENTEENTH bundle. 16 is frozen above.
#
# 0111 is the commercial change: new bands, new prices, and a THIRD term to buy
# between "monthly, I will think about it" and "a year up front". It is also a
# correctness fix, because the price of N months was computed in two places -
# fn__plan_price and a TypeScript copy of its ladder in the operator console -
# which agreed only for as long as the ladder had two steps.
emit supabase/bundles/17_the_price_of_a_term.sql \
     supabase/migrations/0111*.sql

# AN EIGHTEENTH bundle. 17 is frozen above.
#
# 0112 records HOW a school will pay and which term it chose, so the renewal
# machine has something to act on. No gateway integration: there is no merchant
# account yet, and a card adapter written against documentation and never run is
# not something to put near a customer's money. What works end to end is the
# manual path, which is what most Pakistani schools will use for years - credit
# cards are held by 0.22 percent of adults and debit cards by 7.7 percent.
#
# The card NUMBER cannot be stored by this schema. The gateway token lives in
# its own table with RLS on and no policies, so no application role can read it
# whatever a later migration grants.
emit supabase/bundles/18_a_way_to_pay.sql \
     supabase/migrations/0112*.sql

# A NINETEENTH bundle. 18 is frozen above.
#
# 0113 is the runner. Every renewal invoice in this product existed because
# somebody opened the console and pressed a button, so the failure mode was not
# a bug but a Tuesday: the list is not opened, a school's period ends with no
# invoice ever raised, and it lapses into grace and locks having never been
# asked for money. It raises invoices and does NOT take money - that separation
# survives the arrival of a card gateway, and it means an outage at the gateway
# cannot stop bills going out.
emit supabase/bundles/19_the_renewal_run.sql \
     supabase/migrations/0113*.sql

# A TWENTIETH bundle. 19 is frozen above.
#
# 0114 gives a school its own way out, and closes a hole 0112 opened. 0112 added
# cancel_at_period_end so cancelling would keep a school running to the end of
# what it paid for; fn_effective_status knew nothing about the flag, so once the
# period passed the school fell into the ordinary ladder and read 'grace'. Grace
# exists for a payment in flight and a cancelled school has none, so pressing
# Cancel would have bought a free fortnight every time.
emit supabase/bundles/20_leaving_and_coming_back.sql \
     supabase/migrations/0114*.sql

# A TWENTY-FIRST bundle. 20 is frozen above.
#
# 0115 is the one that stopped two real schools from ever getting in. The signup
# created the school, the trial and the login and then attached no profile,
# because the auth service writes app metadata in a second statement and the
# trigger that reads it fired only on the first. Their owners were shown the
# operator's own gate. This makes the trigger fire on both, moves the decision
# somewhere the repair path can share it, and sweeps up the logins already
# stranded.
emit supabase/bundles/21_a_login_with_no_school.sql \
     supabase/migrations/0115*.sql

# A TWENTY-SECOND bundle. 21 is frozen above.
#
# 0116 is about the addresses a school hands out. It invents most of them, so
# names collide across schools and "Forgot password" posts a reset link into a
# mailbox nobody owns. Two answers: ask whether an address is free BEFORE
# filling in the form, and keep the password the office chose so it can tell
# somebody again. The key ring is sealed harder than anything else in this
# schema, and verify.sql checks the seal rather than the table.
emit supabase/bundles/22_the_school_keeps_the_keys.sql \
     supabase/migrations/0116*.sql

# A TWENTY-THIRD bundle. 22 is frozen above.
#
# 0117 goes with the sign-in rebuild. One page served an operator console, a
# school back office and a parent portal, and 0115's replacement for its wall
# said the same thing about the two different ways of having no school: nothing
# ever attached this login, or somebody closed it. Only a definer function can
# tell those apart, because a closed login reads no profile at all by design.
emit supabase/bundles/23_which_door_you_came_through.sql \
     supabase/migrations/0117*.sql

# A TWENTY-FOURTH bundle. 23 is frozen above, and it has been pasted.
#
# 0118 is the first bundle in this project that is purely about speed, and the
# reason it needed a migration rather than a note is that the cost is invisible
# for the first year. student_balance() joins four tables and two of them had no
# index on the column it joins by; measured at a five-year school it is 10.13 ms
# a call against 1.76 ms, and at a one-year school there is no difference at all.
# So the schools that would feel it are the ones that have been paying longest,
# and nobody would ever connect the two. Same shape of gap on the audit log:
# 33,016 buffers to show a screen of 200 rows, against 471.
#
# Found by simulating two years of one school's use (supabase/sim/) rather than
# by reading the schema, which is the only way a cost like this shows up.
emit supabase/bundles/24_a_balance_should_not_read_the_whole_ledger.sql \
     supabase/migrations/0118*.sql

# A TWENTY-FIFTH bundle. 24 is not frozen yet, but keeping one migration to a
# bundle here costs nothing and means a school that has already pasted 24 does
# not have to be told to paste it again.
#
# 0119 is data a school loses by pressing one button in the natural order. The
# office presses Year Rollover on 1 April because the teachers need the new
# class lists; fn_rollover marks the finished year's enrollments `promoted`;
# and both fn_generate_result_cards and fn_result_readiness selected pupils
# with `e.status = 'active'`. So from that moment last year's result cards
# cannot be produced, the generator reports nothing and readiness reports no
# problem. The marks are all still there.
emit supabase/bundles/25_last_year_still_gets_its_result_cards.sql \
     supabase/migrations/0119*.sql

# A TWENTY-SIXTH bundle.
#
# 0120 is the em dash rule, applied to the one place under supabase/ where it
# was never a comment: the sentences the software says out loud when it
# refuses. 27 of them, each repunctuated by hand, because the dash was doing
# three different jobs and a global swap would have produced "That invoice is
# voided: allocate the payment elsewhere", which nobody would write.
emit supabase/bundles/26_the_em_dash_a_clerk_reads.sql \
     supabase/migrations/0120*.sql

# A TWENTY-SEVENTH bundle.
#
# 0121 is the one finding from the two-year simulation that a school could not
# have worked around. A class teacher marks a child absent by mistake and
# presses Finalize; fn_finalize_attendance sets is_locked, fn_mark_attendance
# skips a locked row, and NOTHING in the schema at any privilege level cleared
# that flag. Reproduced as the owner, on their own school, with a reason: the
# register did not change.
#
# It matters more than a wrong mark. The attendance percentage on the result
# card is computed from attendance_daily, so the wrong figure is printed and
# sent home every term, and the least privileged user in the product was the
# one who could create a state the owner could not undo.
emit supabase/bundles/27_a_finalised_register_can_be_reopened.sql \
     supabase/migrations/0121*.sql

# A TWENTY-EIGHTH bundle.
#
# 0122 is 0120 finished. 0120 swept the em dash out of every `raise exception`
# message and left every other string alone, which turned out to be the half
# that people actually read: six message templates sent to PARENTS by SMS
# ("Fee received. Thank you — {school}."), the missing-value placeholder in
# thirteen report and search functions, and twenty-seven sentences the software
# says while working rather than while refusing.
#
# It repairs the data too. fn__default_message_templates runs once, at signup,
# so patching the function does nothing for a school that already exists: their
# message_templates rows, and any message queued and not yet sent, are
# repunctuated by the exact fragment only, so a template a school has edited
# for itself keeps its own wording.
emit supabase/bundles/28_the_em_dash_a_parent_receives.sql \
     supabase/migrations/0122*.sql

# A TWENTY-NINTH bundle.
#
# 0123 was reported by a school: two screens showed two different names for it,
# Settings said one thing and the operator console another. There are two name
# columns, schools.name and school_settings.name, and public.schools carries
# only SELECT policies, so a signed-in user could never change the first one by
# any route. The moment a school edited its own name the two diverged for good,
# and the school was then billed under a name it had not chosen.
#
# Fixed as a trigger rather than a new RPC, because an RPC fixes the two screens
# that exist and leaves the next one free to diverge again. The backfill heals
# the schools already carrying two names, skipping the "Your School" placeholder
# so a real name is never overwritten by it.
emit supabase/bundles/29_a_school_has_one_name.sql \
     supabase/migrations/0123*.sql

# A THIRTIETH bundle.
#
# 0124 is the second half of what the same school reported. They signed up
# twice with one email, the second attempt was correctly refused, and it left a
# school behind that nobody could open and they could not delete.
#
# signup-school already tried to roll the school back, with
# `from('schools').delete()`, and that statement could never once have worked: a
# trigger creates the school_settings row the instant the school is inserted,
# school_settings.school_id is ON DELETE NO ACTION, and a signup writes rows in
# six tables. Every attempt died on a foreign key violation whose result nobody
# read, so the friendly "that email already has an account" was returned and the
# school stayed.
#
# fn_signup_rollback walks every table with a foreign key to schools, derived
# from the catalogue rather than a list, and refuses anything with a login, a
# pupil, a payment or an invoice against it. THE EDGE FUNCTION MUST BE
# REDEPLOYED for new signups to use it; this bundle is what makes the function
# exist for it to call.
emit supabase/bundles/30_a_failed_signup_leaves_nothing_behind.sql \
     supabase/migrations/0124*.sql

# A THIRTY-FIRST bundle, and bundle 29 is NOT reopened to fix what it shipped,
# because a school has already pasted it.
#
# 0125 closes two functions a browser could execute: fn__mirror_school_name,
# which 0123 added four hours earlier with `revoke ... from public, anon` and no
# `authenticated`, and fn_record_migration, open since 0069, which writes the
# ledger that verify.sql and detect.sql read to answer "what is installed here".
#
# THE REASON NEITHER WAS CAUGHT is worth more than the fix. A real Supabase
# project grants FUNCTIONS to authenticated by default privilege, so a new
# function carries an explicit grant and revoking PUBLIC leaves it. Both
# harnesses in this repository granted TABLES only, so every function they
# created carried no such grant, and all four guards that assert "no fn__ helper
# is reachable from a browser" passed on a database where they could not fail. A
# school found it by running verify.sql. Both harnesses are fixed in the same
# commit, and preflight now refuses to report on a database that cannot express
# the defect at all.
emit supabase/bundles/31_the_harness_could_not_see_a_function_grant.sql \
     supabase/migrations/0125*.sql

# A THIRTY-SECOND bundle. 0126 is the largest single thing this project has
# ever done to a school's storage, and it is one measurement:
#
#   audit_log                      214,787 rows      479 MB
#   the whole rest of the database                    92 MB
#
# 206,809 of those rows were the register and the mark sheet, copied. The audit
# trigger wrote a full row for every attendance mark (where `after` IS the row
# and the actor IS its marked_by, checked on all 112,082 of them) and another
# for every pupil when the day was finalised (where the only key that differed
# was `is_locked`, on all 94,727 of them). So the trigger now skips exactly
# those two cases on exactly three tables, fn_finalize_attendance and
# fn_lock_assessment each write ONE row saying what happened, and the rows
# already written are folded into those and removed. Measured after:
#
#   audit_log      11 MB      the database      103 MB
#
# 468 MB back on one school, which is the difference between one school over
# the free tier's 500 MB and four schools inside it. Money is untouched: the
# next entity down the list is payments at 4,845 rows, and no money or
# permission table is named anywhere in the rule.
#
# THE READER MUST RUN ONE MORE THING BY HAND. A delete marks rows dead and does
# not shrink the file, so after this bundle:  vacuum full public.audit_log;
# on its own, because VACUUM cannot run inside a transaction and a pasted file
# is one.
emit supabase/bundles/32_the_register_was_written_twice.sql \
     supabase/migrations/0126*.sql

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
