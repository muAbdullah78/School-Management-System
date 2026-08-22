#!/usr/bin/env python3
# =============================================================================
# Per-QUERY tenant scoping inside SECURITY DEFINER functions.
#
# WHY THIS EXISTS
#
# dashboard.sql assertion 20 already checks that every SECURITY DEFINER function
# reading a tenant table MENTIONS scoping somewhere in its body. That guard is
# worth having and it is not enough: fn_rollover called assert_own on two
# session ids and had eight unscoped queries behind that one mention. One
# correct check exempted eight incorrect ones.
#
# What it cost: fn_rollover chose "the next class up" with
#
#     select id from public.classes c2
#     where c2.active and c2.level_order > c.level_order
#     order by c2.level_order limit 1
#
# and so, on a live multi-tenant deployment, a school's year-end rollover
# promoted its children into ANOTHER SCHOOL'S classroom. Five consecutive runs,
# every time, in the ordinary two-schools-same-ladder case.
#
# WHAT THIS LOOKS FOR
#
# The distinguishing feature of that bug, and the thing a whole-function check
# cannot see. Tenant scope CHAINS through identity:
#
#     join public.invoices i on i.id = al.invoice_id      -- chains: al is scoped
#     where i.student_id in (select id from base)         -- chains: base is scoped
#
# and it does NOT chain through a value comparison:
#
#     where c2.level_order > c.level_order                -- chains NOTHING
#
# So: find correlated predicates that compare two table columns with an
# INEQUALITY, where neither side is an `id`, inside a subquery over a tenant
# table with no school_id nearby. Every such site either carries its own school
# filter or is a bug.
#
# Deliberately narrow. A broad version of this check flagged 65 of 157 functions
# and every one of the top candidates was a false positive — correlated
# subqueries anchored to a scoped outer row, which this script cannot see
# because the anchor is an outer alias rather than a parameter. A guard that
# cries wolf 65 times gets ignored, and then it protects nothing.
#
# Usage:  python3 supabase/check-definer-queries.py
#         (needs PG* env vars pointing at a database with the migrations applied)
# =============================================================================
import os
import re
import subprocess
import sys

TENANT = """
academic_sessions adjustments assessments attendance_daily campuses classes
discounts enrollments exam_subjects exam_terms expenses expense_categories
families fee_heads fee_structures guardians invoices invoice_lines mark_entries
message_outbox message_templates other_income payment_allocations payments
result_cards sections shifts staff staff_attendance staff_checkin_codes
student_fee_items student_links students subjects teacher_assignments
till_sessions enquiries enquiry_followups exam_remarks school_settings
""".split()

# Reviewed exceptions, WITH the reason. Empty is the target state.
KNOWN: "set[tuple[str, str]]" = set()

INEQ = re.compile(
    r"\b([a-z_0-9]+)\.([a-z_]+)\s*(<|>|<=|>=|<>|!=)\s*([a-z_0-9]+)\.([a-z_]+)", re.I)
SCOPE = re.compile(r"school_id", re.I)
TABLE_RE = re.compile(r"\b(?:from|join)\s+public\.(" + "|".join(TENANT) + r")\b", re.I)

SQL = ("select p.proname, pg_get_functiondef(p.oid) "
       "from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
       "where n.nspname = 'public' and p.prosecdef order by 1;")


def main() -> int:
    run = subprocess.run(
        ["psql", "-tA", "-R", "\x02", "-F", "\x01", "-v", "ON_ERROR_STOP=1", "-c", SQL],
        capture_output=True, text=True, env=dict(os.environ))
    if run.returncode != 0:
        sys.stderr.write(run.stderr)
        print("could not query the database — are PG* env vars set?")
        return 1

    records = [r for r in run.stdout.split("\x02") if "\x01" in r]
    if len(records) < 50:
        # A near-empty result would make this check silently vacuous, which is
        # the failure mode two of this project's other guards already had.
        print(f"REFUSING TO REPORT SUCCESS: only {len(records)} SECURITY DEFINER "
              "functions found — the query did not really run")
        return 1

    bad = []
    for rec in records:
        name, body = rec.split("\x01", 1)
        name = name.strip()
        lines = body.splitlines()
        for i, line in enumerate(lines):
            for m in INEQ.finditer(line):
                _, acol, _, _, bcol = m.groups()
                if "id" in (acol, bcol):
                    continue
                if not TABLE_RE.search("\n".join(lines[max(0, i - 6):i + 1])):
                    continue
                if SCOPE.search("\n".join(lines[max(0, i - 6):i + 4])):
                    continue
                if (name, m.group(0)) in KNOWN:
                    continue
                bad.append((name, i + 1, m.group(0),
                            "\n".join("        " + l.strip()
                                      for l in lines[max(0, i - 4):i + 3] if l.strip())))

    print(f"checked {len(records)} SECURITY DEFINER function(s)")
    if not bad:
        print("no unscoped value-correlated subquery over a tenant table")
        return 0

    print("\nUNSCOPED VALUE-CORRELATED SUBQUERIES:\n")
    for name, ln, pred, ctx in bad:
        print(f"  {name}  L{ln}:  {pred}")
        print(ctx)
        print()
    print("Tenant scope chains through identity (x.id = y.something) and NOT")
    print("through a value comparison. A subquery correlated only by a value is")
    print("reading every school's rows. Add a school filter, or add a reviewed")
    print("exception to KNOWN in this script WITH the reason.")
    print("\nThis is the shape that made fn_rollover promote children into other")
    print("schools' classrooms. See migration 0055.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
