#!/usr/bin/env python3
"""Which CI steps does scripts/preflight.sh not reproduce?

Printed at the end of every preflight run, never suppressed.

WHY. preflight.sh has now printed "PREFLIGHT CLEAN" on a commit CI then failed
TWICE.

  The first time it ran every single-line CI command and, without saying so,
  nine of the ten multi-line ones. The tenth was the check that verify.sql and
  detect.sql cover every migration, and it was the one that mattered that day.

  The second time this file was the reason. It only examined steps whose `run:`
  was a `|` block, on the stated assumption that single-line steps are covered
  generically because preflight runs all the guards and all the SQL suites. The
  step that failed was

      run: npm run harness:node20

  one line, not a guard, not a suite, and not run by preflight at all. The
  assumption was never true; it was true of most single-line steps, which is a
  different thing and exactly how an exemption rots.

A checker that does not say what it skipped is claiming more than it checked.
That is the same fault as one that reports a failure as a pass, and this project
has now been bitten by both, twice.

HOW IT DECIDES NOW

Every step, single or multi line. A step counts as covered when either:

  * its command appears verbatim in preflight.sh, or
  * it is one of the two families preflight genuinely runs generically -- an SQL
    suite under supabase/tests/, or a guard under supabase/ or scripts/ -- which
    is checked by pattern against preflight's own loops rather than assumed, or
  * it is named in COVERED below, meaning preflight does the same work by
    another route, with the route stated.

Anything else is printed. Being printed is not a failure: some CI steps cannot
run here. It is a promise that the list is honest.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
CI = (ROOT / '.github/workflows/ci.yml').read_text(encoding='utf-8')
PRE = (ROOT / 'scripts/preflight.sh').read_text(encoding='utf-8')

# Steps preflight performs by a DIFFERENT route than the command in ci.yml, so a
# textual match will never find them. Each entry says how.
COVERED = {
    'Stub the Supabase auth schema':
        'preflight creates its own scratch databases with the same stub inline',
    'Apply all migrations in order':
        'preflight applies every migration to two fresh databases',
    'Bundles match the migrations':
        'preflight runs build-bundles.sh and diffs supabase/bundles/',
    'Bundles apply as single transactions':
        'preflight applies every bundle to a fresh database, and the newest one '
        '--single-transaction onto a database holding the rest',
    'verify.sql and detect.sql cover the same migrations':
        'preflight carries the same loop over supabase/migrations/',
    'Every suite on disk has a step above':
        'preflight carries the same check',
    'Every suite again, in reverse order':
        'preflight runs every suite forward and in reverse',
}

# Partially covered: preflight checks something RELATED but not the same thing.
# Spelled out, because "we test upgrades" and "we test the upgrade that broke a
# school in March" are not the same claim.
PARTIAL = {
    'An EXISTING school can upgrade':
        'preflight applies the NEWEST bundle onto a database holding all the '
        'others, which is the instruction handed to a school today. CI '
        'additionally replays the historical 0037 cutoff and the detect-driven '
        'repair, which this does not.',
}

# preflight names its guards inside `for g in ...` lists and runs the SQL suites
# from a glob, so the FULL command in ci.yml never appears there verbatim. What
# does appear, and what is worth matching on, is the script's own filename.
#
# Matching the basename rather than the whole command is a deliberate weakening
# and worth being explicit about: it proves preflight mentions that exact file,
# not that it invokes it with the same arguments. The alternative is either
# believing a category ("all guards are covered"), which is the assumption that
# let the harness step through, or rewriting preflight to spell out every
# command, which makes adding a guard a two-file change and is how the next one
# gets forgotten.
FILE = re.compile(r'(?:supabase|scripts|web)/(?:[\w./-]*/)?([\w.-]+\.(?:py|sh|sql))')
SUITE_GLOB = 'for t in supabase/tests/*.sql' in PRE


def commands(text: str):
    """(step name, command) for every step with a run:, single or multi line."""
    out = []
    for m in re.finditer(r'-\s+name:\s*(.+?)\n((?:.*\n)*?\s+run:\s*(\|?)[^\n]*\n(?:(?:\s{10,}.*|\s*)\n)*?)', text):
        name = m.group(1).strip()
        block = m.group(2)
        run = re.search(r'\brun:\s*(\|?)(.*)', block)
        if not run:
            continue
        if run.group(1) == '|':
            body = block[run.end():]
            out.append((name, body))
        else:
            out.append((name, run.group(2).strip()))
    return out


def covered(name: str, cmd: str) -> bool:
    if name in COVERED:
        return True
    line = cmd.strip()
    if line and line in PRE:
        return True

    files = FILE.findall(line)
    if files:
        # Every file the step touches has to be accounted for. A step running two
        # scripts where preflight runs one is NOT covered.
        for f in files:
            if f in PRE:
                continue
            if SUITE_GLOB and f'supabase/tests/{f}' in line:
                continue
            return False
        return True
    return False


def main() -> int:
    steps = commands(CI)
    if len(steps) < 20:
        print(f'  BROKEN: only {len(steps)} CI steps parsed, so this list means '
              'nothing. Fix scripts/preflight-gaps.py before trusting a clean run.')
        return 0

    left = [(n, c) for n, c in steps if not covered(n, c)]
    for name, _cmd in left:
        print(f'  {name}')
        if name in PARTIAL:
            print(f'      partially: {PARTIAL[name]}')
    if not left:
        print('  none: every CI step has an equivalent here')

    names = {n for n, _ in steps}
    for m in sorted(set(COVERED) - names):
        print(f'  STALE CLAIM: this file says it covers "{m}", which ci.yml no longer has')
    for m in sorted(set(PARTIAL) - names):
        print(f'  STALE CLAIM: this file describes partial cover of "{m}", which ci.yml no longer has')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
