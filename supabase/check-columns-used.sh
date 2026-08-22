#!/usr/bin/env bash
# =============================================================================
# Is every column actually used by something?
#
# The column-level twin of check-reachable.sh, and it exists because that one
# cannot see the worst bug of this kind we have had:
#
#   profiles.active was WRITTEN by the Settings screen ("Deactivate") and read
#   by NOTHING — not current_school_id(), not has_role(), not one RLS policy. A
#   school that dismissed a clerk, clicked Deactivate and believed access was
#   cut was simply wrong. That clerk kept the fee counter until the login was
#   deleted in Supabase by hand.
#
# A column nothing reads is a promise the software does not keep. A column
# nothing writes is a feature that was designed and never built. Both look
# complete in the schema.
#
# WHAT COUNTS AS USED
#
# The column name appears as a whole word in: any function body, any RLS policy,
# any view, any index expression, any constraint, or anywhere under web/src.
#
# DELIBERATELY LOOSE. Column names are short, common words — `name`, `status`,
# `amount` — so matching the bare word will call a column "used" on a
# coincidence. That bias is the right way round: this check should never cry
# wolf, only catch the unambiguous cases. `photo_url` and `bise_reg_no` have
# nowhere to hide.
#
# Usage:  ./supabase/check-columns-used.sh
#         (needs PG* env vars pointing at a database with the migrations applied)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

# Columns known to be unused, each with what it would take to use it. This is a
# BASELINE, not an amnesty: it stops the check failing on debt that already
# existed, while any NEW unused column fails the build. Removing a line from
# here should mean the column got wired up — see docs/PARITY.md.
KNOWN="
assessments.weightage
attendance_daily.correction_reason
enrollments.bise_reg_no
enrollments.stream
exam_subjects.practical_max
fee_heads.is_refundable
mark_entries.correction_reason
result_cards.generated_at
school_settings.logo_url
staff.left_on
students.photo_url
subjects.is_practical
subjects.stream
"

psql -tA -v ON_ERROR_STOP=1 > /tmp/cols_unused.txt <<'SQL'
with cols as (
  select c.relname as tbl, a.attname as col
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  where n.nspname = 'public' and c.relkind = 'r'
    -- Plumbing every table carries; checking it would be noise.
    and a.attname not in
      ('id','school_id','created_at','updated_at','created_by','deleted_at')
)
select tbl || '.' || col from cols x
where not exists (
        select 1 from pg_proc p join pg_namespace pn on pn.oid = p.pronamespace
        where pn.nspname = 'public' and p.prosrc ~ ('\y' || x.col || '\y'))
  and not exists (
        select 1 from pg_policy pol
        where coalesce(pg_get_expr(pol.polqual, pol.polrelid), '') ~ ('\y' || x.col || '\y')
           or coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '') ~ ('\y' || x.col || '\y'))
  and not exists (
        select 1 from pg_views v
        where v.schemaname = 'public' and v.definition ~ ('\y' || x.col || '\y'))
  and not exists (
        select 1 from pg_index i where pg_get_indexdef(i.indexrelid) ~ ('\y' || x.col || '\y'))
  and not exists (
        select 1 from pg_constraint k where pg_get_constraintdef(k.oid) ~ ('\y' || x.col || '\y'))
order by 1;
SQL
if [ $? -ne 0 ]; then
  echo "could not query the database — are PG* env vars set?"
  exit 1
fi

new=()
known_still=()
checked=0

while read -r tc; do
  [ -z "$tc" ] && continue
  checked=$((checked + 1))
  col="${tc#*.}"
  # Used anywhere in the app?
  if grep -rqw "$col" web/src supabase/functions 2>/dev/null; then
    continue
  fi
  if printf '%s' "$KNOWN" | grep -qx -- "$tc"; then
    known_still+=("$tc")
  else
    new+=("$tc")
  fi
done < /tmp/cols_unused.txt

echo "checked $checked column(s) with no in-database reference"

if [ ${#known_still[@]} -gt 0 ]; then
  echo
  echo "Known unused, still unwired (${#known_still[@]}) — see docs/PARITY.md:"
  printf '  %s\n' "${known_still[@]}"
fi

if [ ${#new[@]} -gt 0 ]; then
  echo
  echo "NEW UNUSED COLUMNS:"
  printf '  %s\n' "${new[@]}"
  echo
  echo "A column nothing reads is a promise the software does not keep; a column"
  echo "nothing writes is a feature designed and never built. Wire it up, drop it,"
  echo "or add it to KNOWN in this script and to docs/PARITY.md with the reason."
  exit 1
fi

echo "no NEW unused columns"
