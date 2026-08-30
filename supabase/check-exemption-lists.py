#!/usr/bin/env python3
"""
Do verify.sql and detect.sql still agree about who is exempt?

WHY THIS EXISTS

0059 established one rule: no STABLE SECURITY DEFINER function may gate a READ
on has_role, because that is what made the observer role show empty tables on
seven screens it was offered. A handful of functions are exempt by name, each
for a stated reason — they authorise a WRITE, or they are access management
rather than a school record.

That rule is checked in three places, because the three have different jobs and
none can import from another:

  * supabase/verify.sql              pasted into a live SQL Editor
  * supabase/repair/detect.sql       pasted into a live SQL Editor
  * supabase/check-readonly-writes.py  runs in CI against a database

The exemption list drifted. 0074 added fn_support_visits and 0085 added
fn_may_mark_subject; both went into verify.sql and neither into detect.sql. The
result was detect.sql reporting

    0059_readonly_boundary | no read gate left on has_role | MISSING

on a database where 0059 was correctly applied — and a school being told to
re-run a migration that changes nothing, twice, before anybody worked out that
the checker was wrong rather than the database.

That is worse than a missing check. A checker that cries wolf teaches the person
reading it to ignore it, and the next time it is right.

WHAT IT COMPARES

The exemption list is written the same way in both SQL files: a `proname not in
(...)` immediately after the `prosrc like '%has_role(%'` line that selects the
functions to complain about. This extracts both and requires them to be equal as
SETS — order and formatting are free, membership is not.

Deliberately NOT compared against check-readonly-writes.py's ALLOWED_VOLATILE:
that list answers a different question (which VOLATILE functions may name
`readonly`), and forcing two different rules to share one list is how an
exemption ends up covering something nobody meant it to.

Usage:  python3 supabase/check-exemption-lists.py
Exit:   0 = the two lists match, 1 = they have drifted
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = {
    'supabase/verify.sql': None,
    'supabase/repair/detect.sql': None,
}

# The anchor is the line that SELECTS the offenders. Everything between it and
# the closing paren of `not in (...)` is the exemption list.
ANCHOR = r"prosrc like '%has_role\(%'"


def extract(path):
    """(set_of_names, error). Comments are stripped first, so a function named
    inside a `--` explanation is never mistaken for an entry."""
    text = open(os.path.join(ROOT, path), encoding='utf-8').read()

    m = re.search(ANCHOR, text)
    if not m:
        return None, (f'{path}: no "{ANCHOR}" line — the 0059 check has been '
                      'rewritten or removed, and this guard can no longer see it')
    if len(re.findall(ANCHOR, text)) > 1:
        return None, (f'{path}: more than one "{ANCHOR}" line. This guard would '
                      'compare an arbitrary one of them; give it a single check '
                      'to read, or teach it which')

    rest = text[m.end():]
    n = rest.find('not in (')
    if n < 0:
        return None, f'{path}: no "not in (" after the has_role line'
    rest = rest[n + len('not in ('):]

    # Take everything up to the paren that closes the list, ignoring comments so
    # a name mentioned in a reason does not become an entry.
    depth = 0
    out = []
    for line in rest.split('\n'):
        code = re.sub(r'--.*$', '', line)
        for ch in code:
            if ch == '(':
                depth += 1
            elif ch == ')':
                if depth == 0:
                    out.append(code[:code.index(')')] if ')' in code else code)
                    return set(re.findall(r"'([a-z_]+)'", '\n'.join(out))), None
                depth -= 1
        out.append(code)
    return None, f'{path}: the "not in (" list is never closed'


def main():
    lists = {}
    for path in FILES:
        names, err = extract(path)
        if err:
            print('FAIL:', err)
            return 1
        if not names:
            print(f'FAIL: {path}: the exemption list came back empty, which '
                  'means the extraction is broken rather than that nothing is '
                  'exempt — may_view is always in it')
            return 1
        lists[path] = names

    (a_path, a), (b_path, b) = lists.items()
    if a == b:
        print(f'0059 exemption list matches across {len(lists)} files '
              f'({len(a)} entries: {", ".join(sorted(a))})')
        return 0

    print('The 0059 exemption list has drifted. One rule, two files, two '
          'answers — and the file that is behind reports MISSING on a database '
          'that is correct.\n')
    only_a = sorted(a - b)
    only_b = sorted(b - a)
    if only_a:
        print(f'  in {a_path} but NOT in {b_path}:')
        for n in only_a:
            print(f'    {n}')
    if only_b:
        print(f'  in {b_path} but NOT in {a_path}:')
        for n in only_b:
            print(f'    {n}')
    print('\nDecide which is right — an exemption is a decision, not a typo — '
          'then make both files say it.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
