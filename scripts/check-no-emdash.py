#!/usr/bin/env python3
"""No em dash may reach a surface a school reads.

WHY THIS EXISTS

The em dash is banned in this project's writing. It is also the single easiest
character to reintroduce, because every model and every word processor inserts
it automatically, and because it looks correct. So the rule needs a check rather
than a habit.

WHAT IS IN SCOPE, AND WHY IT IS NOT EVERYTHING

Counted before writing this: site/ had 39, web/src/ has about 930 across 121 of
144 files, and supabase/ has about 2,900. Almost all of those are in CODE
COMMENTS, which no school ever reads.

Claiming a repo-wide sweep in one pass would either be a lie or a mechanical
edit of three thousand comment lines with no review, which is how a real defect
gets hidden inside a diff nobody can read. So the scope here is the surfaces a
school actually reads, where the rule earns its keep:

  * everything in site/ and site-src/, which is pure published copy and the
    templates it is built from
  * the four authentication pages, which are the highest-intent screens in the
    product and the place a wrong character is read most carefully
  * the desktop shell's connect screen, which is the first thing a school sees
    on its office computer, and the shell's README beside it

The rest of web/src and supabase remains a known, separate, mechanical job. It
is recorded in docs/STATUS.md rather than pretended away. Extend SCOPE below one
directory at a time as each is swept, so this check only ever asserts what is
actually true.

THE HOLE IN THAT REASONING, AND WHERE IT IS NOW CLOSED. "Almost all of those are
in code comments" was true and not sufficient: supabase/ also holds every
`raise exception` message in the product, and those are the sentences the
software says out loud when it refuses. A clerk voiding a paid challan was
shown one for as long as this check had been passing.

Those cannot be checked from here. A static script cannot tell which migration
holds a function's latest definition, and a message rewritten by a later
migration does not matter. So that half of the rule is asserted in
supabase/verify.sql, against the live database, where "does any stored function
say this to a user" has a real answer; migration 0120 repunctuated the 27 that
existed and 0122 the 57 that 0120's rule was too narrow to see (0120 asked only
about `raise exception`, and what people actually read is what the software says
when it WORKS: message templates sent to parents, and the placeholder dash in
every empty report cell). If you widen SCOPE to supabase/ one day, those two
verify rows are the thing that has been holding the line in the meantime, not
this file.

AND THE HOLE IN *THAT*, WHICH IS WHY SQL_SAYS EXISTS BELOW. verify.sql asserts
the rule against every stored function and then broke it 97 times in its own
output: 'FAIL - re-run bundle 7' and its ninety-six siblings were em dashes, and
that table is read by exactly the person who has just been told something is
wrong with their database. The checker cannot simply scan those files, because
their COMMENTS are full of em dashes and always will be. So SQL_SAYS scans only
the single-quoted string LITERALS, which is the property that matters: not "does
this file contain the character" but "does the software SAY it".

WHAT SQL_SAYS DELIBERATELY DOES NOT COVER, and this is a limit rather than an
oversight:

  * supabase/migrations/ and supabase/bundles/. A bundle a school has pasted
    must never change (supabase/build-bundles.sh enforces that), and a bundle is
    generated from the migrations, so those files are immutable history. 181 of
    their literals carry a dash. The remedy for those is a patch migration, and
    0120 IS that patch migration; the verify.sql row is what proves it landed.
  * supabase/repair/. Same text, in the copies a school stuck mid-bundle-3
    pastes. Left alone on purpose: detect.sql sends a school to those files and
    THEN through the remaining bundles in order, so 0120 runs afterwards and
    repunctuates whatever they installed. Editing 64 literals in eleven files
    that must apply cleanly to a broken database, to fix nothing a school would
    ever see, is churn with a real downside.
  * supabase/tests/. Assertion names, read by whoever is running the suite.
    Nobody's school is in there.

Usage: python3 scripts/check-no-emdash.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SCOPE = [
    "site",
    # The SOURCE as well as the built output. site/ is generated from these, so
    # a rule enforced only on the output is a rule that fails on the next build
    # rather than on the edit that broke it.
    "site-src",
    # THE WHOLE APPLICATION, not the four auth screens it used to be.
    #
    # There were 885 em dashes across 118 files in here, including the line a
    # school reads while uploading a photograph. Listing individual files meant
    # every new screen started outside the rule, which is how it got to 885.
    "web/src",
    # The desktop shell's connect screen and its README. Two files, and the
    # first is the very first thing a school sees on its office computer.
    "desktop/ui/index.html",
    "desktop/README.md",
    # Served at app.theschoolmanager.site/robots.txt, so a person can read it.
    "web/public/robots.txt",
]

# The SQL a school pastes into the Supabase editor and then READS THE OUTPUT OF.
# Scanned for dashes inside string literals only: see the docstring. Both of
# these are hand-maintained operator scripts, not frozen history, so the fix for
# a hit here is to edit the line.
SQL_SAYS = [
    "supabase/verify.sql",
    "supabase/reset.sql",
    "supabase/repair/detect.sql",
]

# U+2014 em dash, and U+2013 en dash used as a dash rather than in a range.
# The en dash is allowed between digits (a page range, a score) and refused
# anywhere else, because "9 – 11" as prose punctuation is the same defect
# wearing a narrower glyph.
EM = "—"
EN = "–"

SKIP_SUFFIX = {".png", ".jpg", ".jpeg", ".ico", ".woff", ".woff2", ".pdf", ".zip"}


def files():
    for entry in SCOPE:
        p = ROOT / entry
        if p.is_file():
            yield p
        elif p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file() and f.suffix.lower() not in SKIP_SUFFIX:
                    yield f


def sql_literals(text):
    """Yield (offset, literal) for every single-quoted SQL string in `text`.

    Three things it has to get right, each of which produced a wrong answer on
    the way here:

      * `--` comments are skipped FIRST. Not for speed: a comment containing an
        apostrophe ("the school\'s own") would otherwise open a literal that
        swallows the next four hundred lines, and the scan would report nothing
        at all while looking like it worked.
      * `$$` and `$tag$` markers are stepped OVER rather than skipped past.
        Skipping the whole dollar-quoted block would skip every function body,
        which is where `raise exception` lives, so the check would pass on the
        one class of string it exists for.
      * '' inside a literal is an escaped quote, not the end of one.
    """
    i, n = 0, len(text)
    while i < n:
        if text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        if text[i] == "$":
            m = re.match(r"\$[A-Za-z_]*\$", text[i:])
            if m:
                i += len(m.group(0))
                continue
        if text[i] == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            yield i, text[i:j + 1]
            i = j + 1
            continue
        i += 1


def main() -> int:
    hits = []
    scanned = 0
    for f in files():
        try:
            text = f.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        scanned += 1
        for n, line in enumerate(text.splitlines(), 1):
            if EM in line:
                hits.append((f, n, "em dash", line.strip()[:96]))
            if EN in line:
                i = line.index(EN)
                before = line[i - 1] if i > 0 else ""
                after = line[i + 1] if i + 1 < len(line) else ""
                if not (before.isdigit() and after.isdigit()):
                    hits.append((f, n, "en dash as punctuation", line.strip()[:96]))

    # The SQL scripts, literals only.
    sql_scanned = 0
    for entry in SQL_SAYS:
        f = ROOT / entry
        if not f.is_file():
            print("REFUSING TO REPORT SUCCESS: " + entry + " is in SQL_SAYS and is "
                  "not on disk. Fix the list rather than leaving it unchecked.",
                  file=sys.stderr)
            return 1
        text = f.read_text(encoding="utf-8")
        sql_scanned += 1
        for off, lit in sql_literals(text):
            if EM in lit or EN in lit:
                n = text.count("\n", 0, off) + 1
                kind = "em dash" if EM in lit else "en dash"
                hits.append((f, n, kind + " in something the script SAYS",
                             lit.replace("\n", " ")[:96]))

    if not scanned:
        print("REFUSING TO REPORT SUCCESS: the scope matched no files at all.", file=sys.stderr)
        print("SCOPE in this script has drifted from the tree.", file=sys.stderr)
        return 1

    if hits:
        print(f"Em dashes on a surface a school reads ({len(hits)}):\n")
        for f, n, kind, snippet in hits:
            print(f"  {f.relative_to(ROOT)}:{n}  [{kind}]")
            print(f"      {snippet}\n")
        print("Replace with a comma, a colon or a full stop. House rule, no exceptions.")
        return 1

    print(f"no em dashes in {scanned} published files ({len(SCOPE)} scope entries) "
          f"or in the literals of {sql_scanned} operator SQL scripts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
