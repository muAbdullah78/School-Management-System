#!/usr/bin/env python3
"""
Build the paste-able simulation files from supabase/sim/.

WHY THIS SCRIPT EXISTS RATHER THAN "PASTE THE FILES IN ORDER"

The files under supabase/sim/ are written for psql on a throwaway database.
Five things about them are wrong for the Supabase SQL editor, and each fails in
a different and confusing way:

  * `\\set ON_ERROR_STOP on` is a psql meta-command. The editor is not psql and
    reports it as a syntax error on line 1, which reads as "your SQL is broken"
    rather than "that line is not SQL".
  * `begin;` and `commit;` inside a paste. The editor wraps the paste in one
    transaction of its own, so an inner `commit` ends it early and everything
    after it runs outside any transaction.
  * `create temp table ... on commit drop`. With the commits gone the temp
    tables outlive their section and two sections both create `sim_boy`. Each
    create is now preceded by a drop.
  * The role. Run by run.sh each file is its own psql invocation, so each starts
    as the table owner. Pasted back to back, 07 leaves `role = authenticated`
    behind and 08_the_clock.sql inherits it. That one cost thirteen minutes to
    learn: the paste died on "permission denied for table attendance_daily"
    after doing all the work, and rolled it back. Every section now starts with
    `reset role;`.
  * The school is found by NAME in every section, and in the editor that name
    has to be edited once, not eight times. Every occurrence is rewritten to
    read one setting established at the top of each file.

AND THE SPLIT, WHICH IS THE POINT OF THE GROUPS BELOW. As a single pasted
transaction the whole simulation is far slower than the same work split: nothing
commits, so every student_balance() read checks visibility against hundreds of
thousands of uncommitted tuples in its own transaction. Measured twice: the
one-file version was still in year two of three after ten and a half minutes,
which the SQL editor would not survive. Split, each file commits, so the next
reads committed rows and plans against real statistics.

WHAT IS DELIBERATELY LEFT OUT. supabase/sim/10_logins.sql writes auth.users rows
directly. That is fine on a local box and wrong on a real project: Supabase
hashes passwords on its own side through the admin API, and there is no way to
produce a valid hash from SQL. A file that wrote those rows here would create
eight accounts that look real in the Users screen and refuse every password
anybody types. The last file says so instead.

Usage: python3 scripts/build-sim-bundle.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIM = ROOT / "supabase" / "sim"
OUT_DIR = SIM / "paste"
SCHOOL = "Chaudhary Puclix High School Ghauriii"

GROUPS = [
    ("set_the_school_up",
     ["01_foundation.sql", "02_money_and_staff.sql", "03_students.sql"],
     "The school profile, four academic years, 12 classes, 17 sections, 76 "
     "subjects, 7 fee heads with a full fee sheet, 23 staff, and the 120 "
     "children who were already on the roll in February 2024. Seconds."),
    ("two_and_a_half_years",
     ["04_the_years.sql"],
     "The long one: about three minutes. Enquiries and admissions year by "
     "year, monthly challans, collection with real defaulters, late fines, "
     "discounts, expenses, and THREE year-end rollovers."),
    ("the_register",
     ["05_daily_operations.sql"],
     "589 school days of student and staff attendance, finalised for every "
     "day except today, and twenty of those days reopened afterwards and "
     "corrected the way a school corrects one: a father turns up with the "
     "leave application. About a minute."),
    ("tests_and_exams",
     ["06_academics.sql"],
     "663 class tests, 5 exam terms, 380 papers, result cards, teacher "
     "remarks and certificates. Seconds."),
    ("the_drawer",
     ["07_drawer_guardians_outbox.sql"],
     "Guardians, the cash drawer counted daily, payment reversals, "
     "adjustments, voids, defers, deposit refunds, and the outbox worked down "
     "to a realistic backlog. Seconds."),
    ("set_the_clock",
     ["08_the_clock.sql"],
     "Moves 133,000 timestamps onto their real dates, so two years of school "
     "life stops claiming to have been entered this afternoon. Under a minute."),
    ("check_it_worked",
     ["09_check.sql"],
     "Asserts the result is a school somebody would recognise. Instant. This "
     "is the one whose output to read."),
]
PARTS = [f for _, files, _ in GROUPS for f in files]

HEADER = """-- =============================================================================
-- GENERATED FILE. DO NOT EDIT except for the one line marked below.
-- Built from supabase/sim/ by scripts/build-sim-bundle.py
--
-- TWO YEARS OF ONE SCHOOL'S USE. FILE {n} OF {of}: {title}
--
-- {blurb}
--
-- HOW TO RUN THE SET. Paste each file into the Supabase SQL editor and press
-- Run, IN ORDER, waiting for each to finish before starting the next. Exactly
-- like the numbered migration bundles. Each file is one transaction, so if one
-- fails it writes nothing and can be fixed and re-run on its own.
--
-- WHAT THE SET DOES. It finds the school named below and fills it with February
-- 2024 to today: about 220 children on the roll, 589 school days of register,
-- three year-end rollovers, 6,000 challans, 4,600 payments, 663 class tests,
-- 5 exam terms, 715 result cards, a cash drawer counted daily, and today half
-- marked the way a real register is at eleven in the morning. About 370,000
-- rows.
--
-- Every row arrives through the application's OWN functions, with a real
-- signed-in owner's session and Row Level Security on. Raw inserts would fill
-- the tables faster and prove nothing, because it is those functions that keep
-- the ledger balanced and the receipt numbers gapless.
--
-- BEFORE YOU START
--
--   1. IT IS NOT REVERSIBLE BY THESE FILES. To undo it, sign in as the owner
--      and clear the school's data from Settings, which calls
--      fn_reset_school_data. That works only while the school is still on its
--      free trial. Once the trial has ended there is no undo.
--   2. Only run it against a school you are willing to fill with invented
--      data. It writes nothing outside the one tenant named below.
--   3. It creates NO logins. See the note at the end of file {of}.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- THE ONE LINE TO EDIT, and it must be the same in every file of the set: the
-- exact name of the school to fill. It must match
-- Settings -> School Profile -> School name character for character. If it
-- does not, the file stops with "No owner session." and writes nothing.
-- ---------------------------------------------------------------------------
set local "sim.school" = '{school}';

-- Some of these files take minutes, which is longer than the editor's default
-- limit. Only a superuser can lift it, which the SQL editor is.
set local statement_timeout = 0;

-- ---------------------------------------------------------------------------
-- IS THIS DATABASE NEW ENOUGH? Asked here, at the top, rather than found out
-- thirteen minutes into a file.
--
-- The register section reopens a finalised day and corrects it, which is what
-- the corrections report exists to show and which no database could do before
-- migration 0121. On a database that is behind, that call fails with "function
-- does not exist" AFTER the file has done all its work, and because each file
-- is one transaction the whole lot is rolled back with nothing to show for it.
-- ---------------------------------------------------------------------------
do $prereq$
begin
  if to_regprocedure('public.fn_unlock_attendance(uuid,uuid,uuid,date,text)') is null then
    raise exception 'This project is behind the application. Run '
      'supabase/verify.sql, paste every bundle it names in a FAIL row (the '
      'first of them is 27_a_finalised_register_can_be_reopened.sql), then '
      'start this set again.';
  end if;
end $prereq$;
"""

FOOTER = """
-- =============================================================================
-- ABOUT THE LOGINS, WHICH THESE FILES DELIBERATELY DID NOT CREATE
--
-- The 220 children, their families and the 23 staff all exist as records, and
-- none of them can sign in. That is deliberate twice over.
--
-- It is honest. Supabase hashes a password on its own side, through the admin
-- API, and there is no way to produce a valid hash from SQL. A file that wrote
-- auth.users rows here would create accounts that look real on the Users screen
-- and refuse every password anybody types.
--
-- It is also what a real school looks like a month in: most families have no
-- login yet.
--
-- To make some, use the application's own buttons, which go through the Edge
-- Functions that own this job:
--
--   a parent    Students, open a child, "Give this family a login"
--   a teacher   Settings, Users & Roles; or Staff, "Give them a login"
--
-- Both write the password to the school's key ring at the same time, so the
-- office can read it back to somebody who has lost it. That is migration 0116,
-- and it is why a made-up email address is not a problem.
-- =============================================================================
"""


def clean(text: str, name: str) -> str:
    """Turn one sim file into one section of a paste file."""
    kept = []
    for line in text.split("\n"):
        s = line.strip()
        if s.startswith("\\"):
            continue                      # psql meta-command
        if s in ("begin;", "commit;", "rollback;"):
            continue                      # the editor supplies the transaction
        kept.append(line)
    body = "\n".join(kept)

    # The school name once, at the top, instead of once per section.
    body = body.replace("'" + SCHOOL + "'", "current_setting('sim.school')")

    # With the commits gone, `on commit drop` temp tables outlive their section.
    body = re.sub(
        r"create temp table (\w+)",
        lambda m: "drop table if exists " + m.group(1) + ";\ncreate temp table " + m.group(1),
        body,
    )

    rule = "-" * 72
    return (
        "\n\n-- " + rule + "\n-- " + name + "\n-- " + rule + "\n"
        # reset role FIRST: see the docstring.
        "reset role;\n" + body
        # NO ANALYZE ANYWHERE IN HERE, AND THAT IS THE CONCLUSION OF THREE
        # MEASUREMENTS RATHER THAN AN OMISSION.
        #
        # First it was at the START of each section, reasoning that nothing has
        # committed so the planner needs help. Backwards: running it when a
        # table holds 120 rows freezes "this table is empty" into the
        # statistics for the rest of the transaction, and the planner then
        # picks nested loops for three minutes of work while the data grows
        # underneath it. File 2 went from 2.5 minutes to over twenty.
        #
        # Then it was at the END of each section, so only the NEXT file would
        # see it. Better, and still wrong for the same reason one file later:
        # file 1 ends by recording 120 students, file 2 opens with that as
        # truth and took 7m15s.
        #
        # With no ANALYZE at all, Postgres uses its own default estimates,
        # which are far more conservative and produce better plans for a table
        # being filled. That is why run.sh is fast: its database has never been
        # analyzed. One ANALYZE is appended to the LAST file only, where the
        # bulk writing is over and the only thing it can affect is the school's
        # first screen afterwards.
        + ""
    )


def check(text: str, files: list, is_last: bool) -> list:
    """The properties that each way this generator has been wrong would fail."""
    bad = []
    if "\\set" in text:
        bad.append("a psql meta-command survived")
    for tok in ("\nbegin;", "\ncommit;"):
        if tok in text:
            bad.append(tok.strip() + " survived, so the file is not one transaction")
    n = text.count("'" + SCHOOL + "'")
    if n != 1:
        bad.append("the school name appears " + str(n)
                   + " times; it must appear once, on the line the reader edits")
    if "current_setting('sim.school')" not in text:
        bad.append("nothing reads the school setting, so editing it would do nothing")
    if text.count("\nreset role;\n") != len(files):
        bad.append("a section does not reset the role, so it can inherit "
                   "`authenticated` from the section before it and fail to write")
    if "\nanalyze;\n" in text and not is_last:
        bad.append("ANALYZE appears in a file that is not the last one. "
                   "Statistics gathered while a table is small freeze bad plans "
                   "into the rest of a long transaction: measured at 2.5 min -> "
                   "20 min with it at the section start, 7m15s at the end.")
    return bad


def main() -> int:
    missing = [p for p in PARTS if not (SIM / p).exists()]
    if missing:
        print("MISSING SIM PARTS: " + ", ".join(missing), file=sys.stderr)
        return 1

    OUT_DIR.mkdir(exist_ok=True)
    for stale in OUT_DIR.glob("*.sql"):
        stale.unlink()

    total = 0
    for i, (name, files, blurb) in enumerate(GROUPS, start=1):
        head = HEADER.format(n=i, of=len(GROUPS), title=name.replace("_", " "),
                             blurb=blurb, school=SCHOOL)
        chunks = [head] + [clean((SIM / f).read_text(), f) for f in files]
        if i == len(GROUPS):
            # The one ANALYZE in the whole set: the writing is over, so the only
            # thing it can affect is how fast the school's first screen is.
            chunks.append("\n-- Statistics, now that the writing is finished.\nanalyze;\n")
            chunks.append(FOOTER)
        text = "\n".join(chunks)

        problems = check(text, files, i == len(GROUPS))
        if problems:
            print("REFUSING TO WRITE " + name + ":", file=sys.stderr)
            for x in problems:
                print("  " + x, file=sys.stderr)
            return 1

        out = OUT_DIR / (str(i) + "_" + name + ".sql")
        out.write_text(text)
        lines = len(text.split("\n"))
        total += lines
        print("  wrote " + str(out.relative_to(ROOT)) + " (" + str(lines) + " lines)")

    print(str(len(GROUPS)) + " paste files, " + str(total) + " lines total")
    print("  10_logins.sql excluded on purpose: a password hash "
          "cannot be made from SQL")
    return 0


if __name__ == "__main__":
    sys.exit(main())
