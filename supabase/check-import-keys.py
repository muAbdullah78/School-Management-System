#!/usr/bin/env python3
# =============================================================================
# Lookups on a PER-SCHOOL business key with no school filter.
#
# WHY THIS EXISTS
#
# gr_no, admission_no, employee_no, roll_no, receipt_no and voucher_no are all
# per-school counters. Every school on the platform has a GR 0001. A query that
# resolves or de-duplicates on one of them without a school filter, inside a
# SECURITY DEFINER function where RLS never applies, is reading every school's
# rows.
#
# This has now happened three times in this repo, in three separate importers:
#
#   * 0042 fixed fn_import_staff — a school could not add a teacher because
#     another school had already used that employee number, and a teacher who
#     worked at two schools could never be added to the second because their
#     CNIC was "taken".
#   * 0056 fixed fn_import_students — "GR 0001 already exists" because ANOTHER
#     school had a GR 0001, so a school could not complete its first bulk
#     import, and the rejection rate grew with every school that joined.
#   * 0056 also fixed fn_import_opening_balances — SELECT INTO took the first
#     row, so a row could resolve to another school's child and then fail with
#     "Student is not enrolled in the selected session" about a pupil who is.
#     The import report also printed the resolved name, so it could show another
#     school's pupil back to the importer.
#
# 0042 diagnosed the class correctly and fixed one of the three. That is the
# argument for a tripwire rather than another careful sweep: the sweep happened,
# it was right, and two instances still shipped.
#
# WHAT IT DOES NOT COVER
#
# Lookups by `id`. A uuid is globally unique, so `where id = p_x` cannot cross a
# tenant boundary by accident — though it can still be a permission bug, which
# assert_own is for. This checks only the human-facing keys that repeat between
# schools.
#
# Usage:  python3 supabase/check-import-keys.py
#         (needs PG* env vars pointing at a database with the migrations applied)
# =============================================================================
import os
import re
import subprocess
import sys

# Keys that are NOT unique across schools.
KEYS = [
    "gr_no", "admission_no", "employee_no", "roll_no", "receipt_no",
    "voucher_no", "b_form", "cnic", "full_name", "father_name",
]

TABLES = """
students staff families invoices payments enrollments classes sections fee_heads
subjects exam_terms expenses other_income enquiries staff_checkin_codes
academic_sessions guardians
""".split()

# Reviewed exceptions as (function, matched text). Empty is the target state.
KNOWN: "set[tuple[str, str]]" = set()

TBL = re.compile(r"\b(?:from|join|update|into)\s+public\.(" + "|".join(TABLES) + r")\b", re.I)
KEY = re.compile(r"\b(?:lower\()?(?:[a-z_0-9]+\.)?(" + "|".join(KEYS) + r")\)?\s*=", re.I)
SCOPE = re.compile(r"school_id", re.I)

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
        print(f"REFUSING TO REPORT SUCCESS: only {len(records)} SECURITY DEFINER "
              "functions found — the query did not really run")
        return 1

    bad = []
    for rec in records:
        name, body = rec.split("\x01", 1)
        name = name.strip()
        lines = body.splitlines()
        for i, line in enumerate(lines):
            if not KEY.search(line):
                continue
            # Is this line part of a query over a tenant table?
            if not TBL.search("\n".join(lines[max(0, i - 5):i + 1])):
                continue
            if SCOPE.search("\n".join(lines[max(0, i - 5):i + 4])):
                continue
            if (name, line.strip()) in KNOWN:
                continue
            bad.append((name, i + 1, line.strip()))

    print(f"checked {len(records)} SECURITY DEFINER function(s)")
    if not bad:
        print("no unscoped lookup on a per-school business key")
        return 0

    print("\nUNSCOPED PER-SCHOOL KEY LOOKUPS:\n")
    for name, ln, txt in bad:
        print(f"  {name}  L{ln}:  {txt[:110]}")
    print()
    print("gr_no, admission_no, employee_no, roll_no, receipt_no and voucher_no are")
    print("PER-SCHOOL counters — every school has a GR 0001. Add a school filter, or")
    print("add a reviewed exception to KNOWN in this script WITH the reason.")
    print("\nThis class has shipped three times: 0042 (staff import) and 0056")
    print("(student import, opening-balance import).")
    return 1


if __name__ == "__main__":
    sys.exit(main())
