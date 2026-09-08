#!/usr/bin/env python3
"""RAISE's only placeholder is a bare `%`. `%s` garbles the message.

WHY THIS EXISTS. plpgsql's RAISE substitutes each argument at a bare `%`; it
has no `%s`, `%d`, `%I` or `%L`. Those belong to format(). Write one by habit
and the `%` still consumes the argument and the letter is left behind in the
sentence:

    raise exception 'The %s plan is priced by arrangement', v_name;
    ERROR:  The Custom (601+ students - contact us)s plan is priced by arrangement

It is silent until the moment somebody actually hits the error, which is the
moment they most need the sentence to read cleanly. Two of these were in this
repository and neither had ever been printed.

WHAT IT CHECKS. Only the FORMAT STRING of a RAISE, which is the run of
single-quoted literals before the first top-level comma. `format('%s', x)`
passed as an argument to RAISE is correct and is not flagged, which is why the
arguments are not scanned.

Run: python3 scripts/check-raise-format.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCAN = ["supabase/migrations", "supabase/tests", "supabase/sim", "supabase/repair"]

# FROZEN, AND THE REASON MATTERS. 0056 shipped inside a bundle a school has
# already pasted, and supabase/bundles/MANIFEST exists to stop a shipped bundle
# changing underneath them. So this one is recorded rather than fixed: its
# message only appears if 0056 itself refuses to apply, on a database where it
# applied cleanly long ago.
FROZEN = {
    ("supabase/migrations/0056_importer_scoping.sql", "%s matches neither"),
}

BAD = re.compile(r"%[sdIL]")


def format_string(stmt: str) -> str:
    """The literals before the first top-level comma, concatenated."""
    out, i, depth, n = [], 0, 0, len(stmt)
    while i < n:
        c = stmt[i]
        if c == "'":
            j = i + 1
            while j < n:
                if stmt[j] == "'":
                    if j + 1 < n and stmt[j + 1] == "'":   # '' is an escaped quote
                        j += 2
                        continue
                    break
                j += 1
            out.append(stmt[i + 1:j].replace("''", "'"))
            i = j + 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == "," and depth == 0:
            break
        i += 1
    return "".join(out)


def statements(text: str):
    """Each RAISE statement's text, from the keyword to its semicolon."""
    # Comments first: a `--` line can hold anything and is not code. Block
    # comments are not used in this repository's SQL.
    stripped = "\n".join(re.sub(r"--.*$", "", ln) for ln in text.split("\n"))
    for m in re.finditer(r"\braise\s+(?:exception|notice|warning|info|log|debug)\b",
                         stripped, re.I):
        end = stripped.find(";", m.end())
        yield stripped[m.end():end if end != -1 else len(stripped)]


def main() -> int:
    bad = []
    checked = 0
    for d in SCAN:
        for f in sorted((ROOT / d).glob("*.sql")):
            rel = f.relative_to(ROOT).as_posix()
            text = f.read_text()
            for stmt in statements(text):
                checked += 1
                fmt = format_string(stmt)
                m = BAD.search(fmt)
                if not m:
                    continue
                if any(rel == fr and needle in fmt for fr, needle in FROZEN):
                    continue
                bad.append((rel, m.group(0), fmt[:90].replace("\n", " ")))

    if bad:
        print("RAISE takes a bare % and not a printf placeholder:\n")
        for rel, tok, snippet in bad:
            print(f"  {rel}")
            print(f"    {tok} in: {snippet}")
        print("\nRAISE substitutes each argument at a bare `%`. `%s` still consumes")
        print("the argument and leaves the letter in the sentence, so the message")
        print("is garbled exactly when somebody needs to read it. Use `%`, or move")
        print("the formatting into format(), which does take %s.")
        return 1

    print(f"no printf placeholders in {checked} RAISE format strings "
          f"({len(FROZEN)} frozen exception)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
