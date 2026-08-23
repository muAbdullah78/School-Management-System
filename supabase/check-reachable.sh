#!/usr/bin/env bash
# =============================================================================
# Can anything actually REACH every function the app is allowed to call?
#
# WHY THIS EXISTS
#
# The most common defect in this codebase has never been wrong logic. It has
# been correct logic that nothing could reach. All of these shipped, passed CI,
# and did nothing at all:
#
#   * fn_link_parent            zero callers — the only writer of
#                               profiles.family_id, so every parent portal read
#                               threw "Not a parent account"
#   * fn_family_for             zero callers — siblings never shared a family, so
#                               family billing had never worked in production
#   * fn_find_by_voucher        zero callers — a printed challan could not be
#                               scanned
#   * message_templates.enabled no writer — the WhatsApp toggle was decorative
#   * profiles.active           no reader — "Deactivate" did nothing
#   * result_cards.published_at never selected — no result could reach a parent
#   * fn_reverse_other_income   zero callers — a mistyped income entry could
#                               never be corrected, in an append-only ledger
#
# Every one was found by hand, late, one at a time, usually while building
# something else. This finds them by asking the database, every CI run.
#
# WHAT COUNTS AS REACHABLE
#
# A function granted to `authenticated` is reachable if ANY of these mention it:
#
#   * another function's body        * a trigger (pg_trigger.tgfoid)
#   * an RLS policy (USING or CHECK) * a column default
#   * a check constraint             * an index expression
#   * a view definition              * web/src or supabase/functions
#
# That last one is the point: a function whose only purpose is to be called by
# the app, which the app does not call, is dead weight pretending to be a
# feature.
#
# Usage:  ./supabase/check-reachable.sh
#         (needs PG* env vars pointing at a database with the migrations applied)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

# Deliberate exceptions, WITH the reason. Anything here is reviewed, not
# forgotten. Keep this list short — if it is growing, the rule is being
# worked around rather than followed.
declare -A ALLOWED=(
  # Called by the Edge Functions' service-role client, which authenticates
  # outside this repo's supabase/functions sources, or by the Supabase auth
  # signup hook. Verified by hand; see docs/SETUP.md.
  [fn_provision_school]="called by the signup Edge Function via service_role"
  [fn_provision_school_settings]="called by fn_provision_school"
  [fn_provision_expense_categories]="called by fn_provision_school"
  [fn_provision_message_templates]="called by fn_provision_school"
  # The two storage-policy helpers from 0057. On a real Supabase project the
  # four policies on storage.objects reference them, so they ARE reached — but
  # there is no storage schema in CI, so nothing here can see that reference.
  # They are exercised directly by supabase/tests/photos.sql, which builds a
  # faithful storage.objects stub and installs the same policies against it.
  [fn_may_read_school_file]="referenced by the storage.objects policies; tested in tests/photos.sql"
  [fn_may_write_school_file]="referenced by the storage.objects policies; tested in tests/photos.sql"
)

# The redirect and the heredoc marker must be the LAST thing on this line:
# anything after `<<'SQL'` on a continuation line gets eaten as heredoc content.
psql -tA -v ON_ERROR_STOP=1 > /tmp/reachable_db.txt <<'SQL'
with cands as (
  select p.oid, p.proname
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and has_function_privilege('authenticated', p.oid, 'EXECUTE')
),
refs as (
  select c.proname,
    exists (select 1 from pg_proc x join pg_namespace xn on xn.oid = x.pronamespace
             where xn.nspname = 'public' and x.oid <> c.oid
               and x.prosrc ~ ('\y' || c.proname || '\s*\(')) as by_fn,
    exists (select 1 from pg_trigger t where t.tgfoid = c.oid) as by_trigger,
    exists (select 1 from pg_policy pol
             where coalesce(pg_get_expr(pol.polqual, pol.polrelid), '')
                     ~ ('\y' || c.proname || '\y')
                or coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '')
                     ~ ('\y' || c.proname || '\y')) as by_policy,
    exists (select 1 from pg_attrdef d
             where pg_get_expr(d.adbin, d.adrelid) ~ ('\y' || c.proname || '\s*\(')) as by_default,
    exists (select 1 from pg_constraint k
             where k.contype = 'c'
               and pg_get_constraintdef(k.oid) ~ ('\y' || c.proname || '\s*\(')) as by_check,
    exists (select 1 from pg_index i
             where pg_get_indexdef(i.indexrelid) ~ ('\y' || c.proname || '\s*\(')) as by_index,
    exists (select 1 from pg_views v
             where v.schemaname = 'public'
               and v.definition ~ ('\y' || c.proname || '\s*\(')) as by_view
  from cands c
)
select proname from refs
where not (by_fn or by_trigger or by_policy or by_default or by_check or by_index or by_view)
order by proname;
SQL
if [ $? -ne 0 ]; then
  echo "could not query the database — are PG* env vars set?"
  exit 1
fi

dead=()
checked=0
while read -r fn; do
  [ -z "$fn" ] && continue
  checked=$((checked + 1))
  # Reachable from the app, an Edge Function, or a test?
  if grep -rlq "\b${fn}\b" web/src supabase/functions 2>/dev/null; then
    continue
  fi
  if [ -n "${ALLOWED[$fn]:-}" ]; then
    echo "  allowed: $fn — ${ALLOWED[$fn]}"
    continue
  fi
  dead+=("$fn")
done < /tmp/reachable_db.txt

echo "checked $checked function(s) with no in-database reference"

if [ ${#dead[@]} -gt 0 ]; then
  echo
  echo "GRANTED TO authenticated BUT REACHABLE FROM NOWHERE:"
  printf '  %s\n' "${dead[@]}"
  echo
  echo "Each of these is either a feature with no way to use it, or dead code"
  echo "that 'authenticated' can nonetheless EXECUTE. Wire it up, drop it, or"
  echo "add it to ALLOWED in this script with the reason."
  exit 1
fi

echo "every function the app may call is reachable from somewhere"
