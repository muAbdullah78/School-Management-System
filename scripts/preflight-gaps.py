#!/usr/bin/env python3
"""Which multi-line CI steps does scripts/preflight.sh not reproduce?

Printed at the end of every preflight run, never suppressed.

WHY. The first version of preflight.sh printed "PREFLIGHT CLEAN" on a commit
that CI then failed. It ran every single-line CI command and, without saying so,
nine of the ten multi-line ones. The tenth was the check that verify.sql and
detect.sql cover every migration, and it was the one that mattered that day.

A checker that does not say what it skipped is claiming more than it checked.
That is the same fault as one that reports a failure as a pass, and this project
has now been bitten by both.

Single-line steps are not listed: preflight runs the guards and the SQL suites
generically, so a new one is covered the day it is added.
"""
import pathlib
import re

COVERED = {
    'Stub the Supabase auth schema',
    'Apply all migrations in order',
    'Bundles match the migrations',
    'Bundles apply as single transactions',
    'verify.sql and detect.sql cover the same migrations',
    'Every suite on disk has a step above',
    'Every suite again, in reverse order',
}

ROOT = pathlib.Path(__file__).resolve().parent.parent
text = (ROOT / '.github/workflows/ci.yml').read_text(encoding='utf-8')
steps = re.findall(r'-\s+name:\s*(.+)\n(?:.*\n)*?\s+run:\s*(\|?)', text)
multi = [n.strip() for n, bar in steps if bar == '|']

# A name in COVERED that no longer exists in ci.yml means the step was renamed
# or removed, and this file is now claiming to cover something imaginary.
stale = COVERED - set(multi)
# Partially covered: preflight checks something RELATED but not the same thing.
# Listed with the difference spelled out, because "we test upgrades" and "we
# test the upgrade that broke a school in March" are not the same claim.
PARTIAL = {
    'An EXISTING school can upgrade':
        'preflight applies the NEWEST bundle onto a database holding all the '
        'others, which is the instruction handed to a school today. CI '
        'additionally replays the historical 0037 cutoff and the detect-driven '
        'repair, which this does not.',
}

left = [m for m in multi if m not in COVERED]

for m in left:
    note = PARTIAL.get(m)
    print(f'  {m}')
    if note:
        print(f'      partially: {note}')
if not left:
    print('  none: every multi-line CI step has an equivalent here')
for m in sorted(stale):
    print(f'  STALE CLAIM: this file says it covers "{m}", which ci.yml no longer has')
