#!/usr/bin/env python3
# =============================================================================
# The files a vendor pastes into the Supabase SQL editor must survive being
# pasted into the Supabase SQL editor.
#
# WHAT HAPPENED
#
# The vendor ran supabase/verify.sql, which is the file whose entire job is to
# be pasted into that editor, and got:
#
#     Error: Failed to run sql query: ERROR: 42P01: relation "the" does not exist
#
# There is no table called "the". Line 689 read:
#
#     -- decision now lives; the NEGATIVE one must hold in both,
#
# Something between the clipboard and the server cut the file at that
# semicolon, and handed Postgres a statement beginning "the NEGATIVE one must
# hold in both," — so Postgres did what it is asked and looked for a relation
# called "the".
#
# WHAT THIS CHECKS, AND WHAT IT DELIBERATELY DOES NOT
#
# A semicolon inside a `--` comment, at the top level of the file (not inside a
# $$ ... $$ body). Those are the ones that end a statement in a client that
# splits on semicolons without tracking comments, and they are free to remove
# because a comment changes nothing.
#
# NOT semicolons inside string literals, and that is a correction rather than an
# omission. The first attempt at this rewrote those too and turned a passing
# verify row into a FAIL, because some of those strings are not prose: verify.sql
# matches function bodies with patterns like `prosrc ~ '... ;'`, and a semicolon
# inside one of those is load bearing.
#
# NOT the bundles either. Every bundle has shipped and been pasted successfully,
# including ones carrying fifty of these inside function bodies, so the evidence
# is that the editor copes with them there. They are also generated from the
# migrations, and rewriting a RAISE message to satisfy a guard would change a
# sentence a school reads and break the tests that match on it. If a bundle ever
# does fail this way, the fix belongs in that bundle's migration, not here.
#
# Usage:  python3 scripts/check-pasteable.py
# =============================================================================
import re
import sys

# The three files a human is told to paste by hand. Bundles are excluded above,
# with the reason.
FILES = [
    'supabase/verify.sql',
    'supabase/repair/detect.sql',
    'supabase/reset.sql',
]


def offenders(path):
    """Semicolons in a top-level `--` comment, with their line numbers."""
    try:
        raw = open(path, encoding='utf-8').read()
    except OSError as e:
        return None, f'{path}: {e}'
    hits = []
    i, n, line = 0, len(raw), 1
    state, dollar = 'code', None
    while i < n:
        c = raw[i]
        if c == '\n':
            line += 1
        if state == 'dollar':
            if raw.startswith(dollar, i):
                i += len(dollar)
                state, dollar = 'code', None
                continue
            i += 1
            continue
        if state == 'comment':
            if c == '\n':
                state = 'code'
            elif c == ';':
                hits.append((line, raw[max(0, i - 46):i + 46].replace('\n', ' ').strip()))
            i += 1
            continue
        if state == 'string':
            if c == "'":
                if raw[i + 1:i + 2] == "'":
                    i += 2
                    continue
                state = 'code'
            i += 1
            continue
        m = re.match(r'\$[A-Za-z_]*\$', raw[i:])
        if m:
            dollar = m.group(0)
            state = 'dollar'
            i += len(dollar)
            continue
        if raw.startswith('--', i):
            state = 'comment'
            i += 2
            continue
        if c == "'":
            state = 'string'
            i += 1
            continue
        i += 1
    return hits, None


def main():
    bad = 0
    for path in FILES:
        hits, err = offenders(path)
        if err:
            print('FAIL:', err)
            return 1
        if hits:
            bad += len(hits)
            print(f'{path}: {len(hits)} semicolon(s) inside a comment')
            for line, ctx in hits[:6]:
                print(f'    line {line}: ...{ctx}...')
            if len(hits) > 6:
                print(f'    ... and {len(hits) - 6} more')
    if bad:
        print()
        print('A semicolon inside a comment ends the statement in any client that')
        print('splits on semicolons without tracking comments, and the text after it')
        print('is then parsed as SQL. Use a comma. Not a full stop with a capital:')
        print('that turned "supabase/tests/orphan_data.sql" into "Supabase/tests/..."')
        print('inside a comment telling somebody which file to open.')
        return 1
    print(f'check-pasteable: ok ({len(FILES)} hand-pasted file(s), no semicolon '
          'inside a comment)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
