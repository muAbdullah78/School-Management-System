#!/usr/bin/env python3
"""
Does docs/PARITY.md still tell the truth?

WHY THIS EXISTS

PARITY.md is the competitor-feature inventory: 87 rows, each with a status. It
has gone stale twice, both times in the direction that costs the most.

  * First it listed as `missing` several things that had been built, including
    the printable challan and bulk fee payment. A checklist that is wrong that
    way sends the next person to rebuild what exists.
  * Then a pass re-checked twelve rows and wrote down, honestly, that the other
    seventy-five had not been checked. The honest note stayed for months. The
    unchecked rows stayed wrong — eight of them, including two WhatsApp
    templates that were seeded into every school and queued by nothing, a
    parent-account screen that had shipped nine migrations earlier, and a
    student roster the file described as "a list of 50 with no columns" while
    another row of the same file said it was a paged sortable table.

Nobody was careless. The problem is structural: a status is a claim about the
code, and a claim about the code in a Markdown file is not checked by anything.

WHAT IT CHECKS

Each row carries evidence in the ```parity-evidence block at the foot of
PARITY.md, and this script verifies every line of it against the repository:

    file:PATH     that file exists
    sql:SYMBOL    that symbol appears in supabase/migrations/
    app:SYMBOL    that symbol appears in web/src/
    nofile:PATH   that file does NOT exist
    nosql:SYMBOL  that symbol does NOT appear in supabase/migrations/
    noapp:SYMBOL  that symbol does NOT appear in web/src/
    why:TEXT      free text, checked for being non-empty

    have / done  need at least one positive check
    missing      needs at least one NEGATIVE check
    partial      needs at least one of each
    excluded     needs a why: and at least one negative

THE NEGATIVE CHECKS ARE THE POINT. Every time this file has been wrong, it was
wrong about something that had been built. A guard that only verified the `have`
rows would have passed all eight stale rows. `missing` therefore has to name the
thing that would exist if it were built, and that thing has to be absent.

`partial` needs both because `partial` means half built, and a row that names
only the built half is a place to hide.

Also checked, because a guard with a hole in the middle is worse than none:

  * every status row in sections 1-11 has an evidence line;
  * every evidence line matches a row (so a renamed row cannot leave its
    evidence behind, quietly still passing);
  * no duplicate keys.

Usage:  python3 scripts/check-parity.py
Exit:   0 = every row's evidence holds, 1 = something is wrong
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PARITY = os.path.join(ROOT, 'docs', 'PARITY.md')

STATUSES = ('have', 'done', 'partial', 'missing', 'excluded')
POSITIVE = ('file', 'sql', 'app')
NEGATIVE = ('nofile', 'nosql', 'noapp')


def rows_from_tables(text):
    """Every status row in a numbered section, as (key, status, line_no).

    Restricted to sections whose heading starts with a number — `## 1. Admission
    Management` and its siblings. The narrative sections further down contain
    tables of their own (the record of what this file used to say, the columns
    nothing used) and those are prose, not the inventory.
    """
    out = []
    section = None
    for n, line in enumerate(text.split('\n'), 1):
        if line.startswith('## '):
            section = line[3:].strip()
        if not line.startswith('|'):
            continue
        if section is None or not re.match(r'^\d+\.', section):
            continue
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if len(cells) < 2:
            continue
        # separator row
        if cells[0] and set(cells[0]) <= set('-: '):
            continue
        joined = ' '.join(cells)
        m = re.search(r'`(' + '|'.join(STATUSES) + r')`', joined)
        if not m:
            continue
        key = re.sub(r'[*`]', '', cells[0]).strip()
        out.append((key, m.group(1), n))
    return out


def evidence_block(text):
    """The parity-evidence fence, as {key: [(kind, target), ...]}."""
    m = re.search(r'```parity-evidence\n(.*?)```', text, re.S)
    if not m:
        return None, 'docs/PARITY.md has no ```parity-evidence block'
    out = {}
    dupes = []
    for raw in m.group(1).split('\n'):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        parts = [p.strip() for p in line.split('|')]
        key = parts[0]
        if key in out:
            dupes.append(key)
        checks = []
        for p in parts[1:]:
            if ':' not in p:
                return None, f'evidence for "{key}" has a term with no kind: {p!r}'
            kind, target = p.split(':', 1)
            checks.append((kind.strip(), target.strip()))
        out[key] = checks
    if dupes:
        return None, 'duplicate evidence keys: ' + ', '.join(sorted(set(dupes)))
    return out, None


def grep(pattern, path):
    """Is this literal string anywhere under path? Fixed-string, not regex."""
    r = subprocess.run(
        ['grep', '-rqF', '--', pattern, path],
        cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0


def check_term(kind, target):
    """(ok, complaint). complaint is what to print when ok is False."""
    if kind == 'file':
        return (os.path.isfile(os.path.join(ROOT, target)),
                f'file:{target} does not exist')
    if kind == 'nofile':
        return (not os.path.isfile(os.path.join(ROOT, target)),
                f'nofile:{target} EXISTS — the row says it is not built')
    if kind == 'sql':
        return (grep(target, 'supabase/migrations'),
                f'sql:{target} is in no migration')
    if kind == 'nosql':
        return (not grep(target, 'supabase/migrations'),
                f'nosql:{target} IS in a migration — the row says it is not built')
    if kind == 'app':
        return (grep(target, 'web/src'),
                f'app:{target} appears nowhere in web/src — nothing reaches it')
    if kind == 'noapp':
        return (not grep(target, 'web/src'),
                f'noapp:{target} IS in web/src — the row says it is not built')
    if kind == 'why':
        return (bool(target), 'why: is empty')
    return (False, f'unknown evidence kind {kind!r}')


def main():
    text = open(PARITY, encoding='utf-8').read()
    rows = rows_from_tables(text)
    ev, err = evidence_block(text)
    if err:
        print('FAIL:', err)
        return 1

    problems = []

    keys = [k for k, _, _ in rows]
    dup = {k for k in keys if keys.count(k) > 1}
    if dup:
        # Two rows with the same first cell cannot both be evidenced. Real case:
        # "Staff Birthdays" and "Student Birthdays" are one screen but two rows,
        # and they are named differently for exactly this reason.
        problems.append('two rows share a key, so evidence cannot address them '
                        'separately: ' + ', '.join(sorted(dup)))

    missing_ev = [k for k in keys if k not in ev]
    if missing_ev:
        problems.append(
            'these rows have NO evidence line, so their status is only a claim:\n    '
            + '\n    '.join(missing_ev))

    orphans = [k for k in ev if k not in keys]
    if orphans:
        problems.append(
            'these evidence lines match no row — a row was reworded or removed '
            'and its evidence was left behind, still passing:\n    '
            + '\n    '.join(orphans))

    for key, status, line_no in rows:
        checks = ev.get(key)
        if checks is None:
            continue
        kinds = {k for k, _ in checks}

        if status in ('have', 'done') and not (kinds & set(POSITIVE)):
            problems.append(
                f'{key} (line {line_no}) is `{status}` with no positive evidence — '
                'name the file, function or caller that makes it true')
        if status == 'missing' and not (kinds & set(NEGATIVE)):
            problems.append(
                f'{key} (line {line_no}) is `missing` with no negative evidence. '
                'This is the check that matters: every time this file has been '
                'wrong, it was wrong about something that HAD been built. Name '
                'what would exist if it were, with nofile:/nosql:/noapp:')
        if status == 'partial':
            if not (kinds & set(POSITIVE)):
                problems.append(f'{key} (line {line_no}) is `partial` with no '
                                'evidence of the half that EXISTS')
            if not (kinds & set(NEGATIVE)):
                problems.append(f'{key} (line {line_no}) is `partial` with no '
                                'evidence of the half that does NOT exist. '
                                '`partial` without that is a place to hide')
        if status == 'excluded':
            if 'why' not in kinds:
                problems.append(f'{key} (line {line_no}) is `excluded` with no why:')
            if not (kinds & set(NEGATIVE)):
                problems.append(f'{key} (line {line_no}) is `excluded` with no '
                                'evidence that it is actually absent')

        for kind, target in checks:
            ok, complaint = check_term(kind, target)
            if not ok:
                problems.append(f'{key} (line {line_no}, `{status}`): {complaint}')

    if problems:
        print('docs/PARITY.md does not match the repository:\n')
        for p in problems:
            print('  * ' + p)
        print(f'\n{len(problems)} problem(s). Either the code moved and the row '
              'is now wrong, or the row was reworded and its evidence needs '
              'revisiting. Both are worth looking at — that is the whole point '
              'of this check.')
        return 1

    counts = {}
    for _, st, _ in rows:
        counts[st] = counts.get(st, 0) + 1
    summary = ', '.join(f'{counts[k]} {k}' for k in STATUSES if k in counts)
    print(f'docs/PARITY.md: all {len(rows)} rows evidenced and verified '
          f'({summary})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
