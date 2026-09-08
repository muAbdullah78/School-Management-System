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
    # ONE FILE PER ACADEMIC YEAR, AND NOT FOR TIDINESS.
    #
    # These were one file, and a school pasting it got
    #
    #     Error: Failed to fetch (api.supabase.com)
    #
    # which is not a SQL error at all: it is the browser losing a request that
    # ran too long. `set local statement_timeout = 0` at the top of every file
    # lifts the DATABASE's limit and cannot touch the dashboard API's own, and
    # all four years in one request takes about four and a half minutes.
    #
    # Split, the same work takes 76 SECONDS INSTEAD OF 262, because each year
    # commits and the next one plans against real statistics rather than
    # against hundreds of thousands of uncommitted rows. That is the ANALYZE
    # finding in FINDINGS.md arriving from the other direction.
    #
    # Each year is independent and safe to paste twice: it draws its children
    # from its own fixed slice of the name pool, and it skips itself if this
    # session already carries monthly challans.
    ("year_2023_2024",
     ["04_the_years.sql"],
     "February and March 2024: the first two months, six admissions, and the "
     "year-end rollover that carries the whole school into 2024-2025. "
     "Seconds.",
     "2023-2024"),
    ("year_2024_2025",
     ["04_the_years.sql"],
     "A full year: 45 admissions out of 135 enquiries, twelve months of "
     "challans and collection, fines, discounts, expenses, leavers, and the "
     "rollover into 2025-2026. Half a minute.",
     "2024-2025"),
    ("year_2025_2026",
     ["04_the_years.sql"],
     "The biggest year: 50 admissions, twelve months of billing against a "
     "roll that has grown twice, and the rollover into the current year. "
     "About half a minute.",
     "2025-2026"),
    ("year_2026_2027",
     ["04_the_years.sql"],
     "The current year, as far as today and no further: this April onwards, "
     "with the months still to come left unbilled the way a real school's "
     "are. Twenty seconds.",
     "2026-2027"),
    # THE REGISTER, ALSO ONE FILE PER YEAR, and for the same reason as the
    # years above: whole, it took 84 seconds on a fast local disk, which made
    # it the longest file in the set and the next one certain to lose its
    # request on a shared instance.
    #
    # Sections 2 to 4 of 05_daily_operations.sql are NOT per-year (the staff
    # register is per member of staff per day, and the corrections pass has to
    # wait until every day is finalised), so they carry a guard that runs them
    # in the LAST of these four files only.
    ("register_2023_2024",
     ["05_daily_operations.sql"],
     "February and March 2024 of the register, section by section, day by "
     "day, finalised. Seconds.",
     "2023-2024"),
    ("register_2024_2025",
     ["05_daily_operations.sql"],
     "The 2024-2025 register: every school day of it, for a roll that grew "
     "through the year. Half a minute.",
     "2024-2025"),
    ("register_2025_2026",
     ["05_daily_operations.sql"],
     "The 2025-2026 register, the biggest of the four. Half a minute.",
     "2025-2026"),
    ("register_2026_2027",
     ["05_daily_operations.sql"],
     "This year's register up to today, with today deliberately left "
     "unfinalised the way a real one is at eleven in the morning. Then the "
     "staff register, the gate codes, and twenty finalised days reopened and "
     "corrected the way a school corrects one: a father turns up with the "
     "leave application. Under a minute.",
     "2026-2027"),
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
# A group is (name, files, blurb) or (name, files, blurb, academic_year).
GROUPS = [g if len(g) == 4 else (g[0], g[1], g[2], None) for g in GROUPS]
PARTS = sorted({f for _, files, _, _ in GROUPS for f in files})

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
{year_line}
-- Some of these files take minutes, which is longer than the editor's default
-- limit. Only a superuser can lift it, which the SQL editor is.
set local statement_timeout = 0;

-- ---------------------------------------------------------------------------
-- CAN THIS FILE DO ANYTHING AT ALL? Four questions, asked here at the top
-- rather than found out four minutes into a file, and each one answered with
-- WHAT IS ACTUALLY THERE rather than with the fact that something is wrong.
--
-- THE FIRST VERSION OF THIS ASKED ONLY THE FIRST QUESTION, and the file then
-- died on the school name with
--
--     ERROR: No owner session. Is the school name exactly right?
--
-- seven times in a row. That message names the right suspect and then leaves
-- the reader with nowhere to go: the name is in Settings, truncated in the
-- sidebar, and the difference is usually a trailing space or one letter. A
-- diagnostic that can read the answer and does not print it is not a
-- diagnostic. So this one lists the school names it can see.
-- ---------------------------------------------------------------------------
do $prereq$
declare
  -- NOT btrim'd: see question 3. `nullif` on the raw value only asks whether
  -- anything arrived at all.
  v_name   text := coalesce(current_setting('sim.school', true), '');
  v_school uuid;
  v_near   integer;   -- schools whose name differs only in case or spacing
  v_owners integer;
  v_all    text;
begin
  -- 1. Is the schema new enough? The register section reopens a finalised day
  --    and corrects it, which no database could do before migration 0121.
  if to_regprocedure('public.fn_unlock_attendance(uuid,uuid,uuid,date,text)') is null then
    raise exception 'This project is behind the application. Run '
      'supabase/verify.sql, paste every bundle it names in a FAIL row (the '
      'first of them is 27_a_finalised_register_can_be_reopened.sql), then '
      'start this set again.';
  end if;

  -- 2. Did the school name survive as far as this statement? `set local` only
  --    holds for the transaction, and pressing Run on a pasted file makes the
  --    whole file one transaction. Run a SELECTION of it and the setting is
  --    gone by the time anything reads it, and every later error then blames
  --    the school name instead of the way it was run. Outside a transaction
  --    `set local` does not fail: it warns, and reads back EMPTY.
  if btrim(v_name) = '' then
    raise exception 'The school name never arrived: "sim.school" is empty here. '
      'Paste and run the WHOLE file in one go rather than a selection of it, '
      'because the line that sets the name only holds for as long as the file '
      'runs as one batch.';
  end if;

  -- 3. Is there a school of that name? And if not, SAY WHAT THERE IS, and fix
  --    it where the answer is not in doubt.
  --
  --    THE COMPARISON HERE IS EXACTLY THE ONE THE REST OF THE FILE USES: plain
  --    equality on schools.name. An earlier version trimmed the setting before
  --    comparing, which made this check PASS on a name the body then failed on,
  --    and a check that disagrees with the code it guards is worse than no
  --    check. So instead of loosening the comparison, this loosens the SEARCH
  --    and then corrects the setting, which every later statement reads.
  --
  --    IT SEARCHES BOTH NAME COLUMNS, and that is not belt and braces: it is
  --    the defect migration 0123 fixes. school_settings.name is the only one a
  --    school can edit, schools.name is the one this file matches on, and until
  --    0123 nothing kept them in step. So a school reading its own name off its
  --    own screen and pasting it in here would be pasting the OTHER column, and
  --    every file in the set refused. That is exactly how it was reported.
  select id into v_school from public.schools where name = v_name;

  if v_school is null then
    -- The name the school sees on its own screens, which is the one a reader
    -- copies. Matched exactly first, before any fuzziness.
    select s.id, s.name into v_school, v_all
      from public.schools s
      join public.school_settings st on st.school_id = s.id
     where st.name = v_name;

    if v_school is not null then
      raise notice 'That is the name on this school''s own screens. In the '
        'database it is still stored as "%", which is what the console and its '
        'invoices show: two names for one school, which '
        'supabase/bundles/29_a_school_has_one_name.sql puts right. Continuing '
        'with the stored one.', v_all;
      perform set_config('sim.school', v_all, true);
      v_name := v_all;
    else
      -- One near miss and no ambiguity, across either column: almost always a
      -- trailing space, which is invisible in Settings and in the sidebar, or a
      -- capital letter. Fix it and say so loudly enough that nobody could think
      -- a different school was filled by accident.
      select count(*), min(s.name) into v_near, v_all
        from public.schools s
        left join public.school_settings st on st.school_id = s.id
       where lower(btrim(s.name))  = lower(btrim(v_name))
          or lower(btrim(st.name)) = lower(btrim(v_name));

      if v_near = 1 then
        raise notice 'The name given was "%" and this school is stored as "%". '
          'Same school, so continuing with the stored spelling.', v_name, v_all;
        perform set_config('sim.school', v_all, true);
        v_name := v_all;
      else
        -- BOTH names per school, because the whole difficulty here is that a
        -- school has two and can only see one of them.
        select string_agg('"' || s.name || '"'
                 || case when st.name is distinct from s.name
                           then ' (its own screens say "' || st.name || '")'
                         else '' end, ', ' order by s.name)
          into v_all
          from public.schools s
          left join public.school_settings st on st.school_id = s.id;
        raise exception 'No school is named "%". This project holds %. Copy the '
          'one you want, character for character including any spaces, into the '
          '"sim.school" line at the top of every file in this set.',
          v_name, coalesce(v_all, 'no schools at all');
      end if;
    end if;
    select id into v_school from public.schools where name = v_name;
  end if;

  -- 4. Is there an owner to act as? Every row in this set is written through
  --    the application's own functions with a real signed-in owner's session,
  --    so without one there is nobody to be. Kept separate from question 3 on
  --    purpose: the two were one message before, and "is the school name
  --    right?" is unanswerable advice when the name was right all along.
  select count(*) into v_owners from public.profiles
   where school_id = v_school and role = 'owner' and active;
  if v_owners = 0 then
    raise exception 'The school "%" exists but has no active owner login, and '
      'this set writes as its owner. Sign in as the school and check Settings, '
      'Users & Roles.', v_name;
  end if;

  raise notice 'Filling "%", which has an owner to write as. This whole file is '
    'one transaction: if it stops, it writes nothing.', v_name;
end $prereq$;
"""

# Filled into the header of the four per-year files. 04_the_years.sql runs one
# academic year when this is set and all four when it is not, so one source file
# serves both this split and a psql run that wants the lot in one go.
YEAR_LINE = """
-- WHICH ACADEMIC YEAR THIS FILE IS. Do not change it, and run the four year
-- files IN ORDER: each one ends by rolling the whole school forward into the
-- next, and there is nothing for the next file to bill until it has.
set local "sim.year" = '{year}';
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


def check(text: str, files: list, is_last: bool, year=None) -> list:
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
    if year is not None:
        # AN EXECUTABLE LINE, not a substring anywhere in the file. The first
        # version of this asked whether the text `set local "sim.year" = '...'`
        # appeared, and a COMMENTED-OUT copy of that line satisfies it: the
        # guard passed on a file that would have run all four years and timed
        # out. Same trap as every other check in this repository, and it caught
        # me while writing a check about it.
        sets_year = [ln for ln in text.split("\n")
                     if ln.lstrip().startswith('set local "sim.year"')
                     and ("'" + year + "'") in ln]
        if not sets_year:
            bad.append("no executable line sets sim.year to " + year
                       + ", so this file would run every year at once and time"
                       + " out in the SQL editor the way the unsplit one did")
        if "current_setting('sim.year', true)" not in text:
            bad.append("nothing reads the year setting, so the split does nothing")
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
    for i, (name, files, blurb, year) in enumerate(GROUPS, start=1):
        head = HEADER.format(n=i, of=len(GROUPS), title=name.replace("_", " "),
                             blurb=blurb, school=SCHOOL,
                             year_line=YEAR_LINE.format(year=year) if year else "")
        chunks = [head] + [clean((SIM / f).read_text(), f) for f in files]
        if i == len(GROUPS):
            # The one ANALYZE in the whole set: the writing is over, so the only
            # thing it can affect is how fast the school's first screen is.
            chunks.append("\n-- Statistics, now that the writing is finished.\nanalyze;\n")
            chunks.append(FOOTER)
        text = "\n".join(chunks)

        problems = check(text, files, i == len(GROUPS), year)
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
