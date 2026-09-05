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

Usage: python3 scripts/check-no-emdash.py
"""
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

    print(f"no em dashes in {scanned} published files ({len(SCOPE)} scope entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
