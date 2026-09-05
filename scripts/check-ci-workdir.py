#!/usr/bin/env python3
"""
A CI step that runs from the wrong directory fails on the file, not the fault.

WHY THIS EXISTS

The "Web build & tests" job sets

    defaults:
      run:
        working-directory: web

so every step in it starts in web/. Steps that check the whole repository
therefore declare `working-directory: .` one at a time, and there are nine of
them doing exactly that.

A tenth was added without it:

    - name: No school action depends on a browser dialog
      run: python3 scripts/check-no-browser-dialogs.py

which resolved to web/scripts/check-no-browser-dialogs.py and died with

    python3: can't open file '.../web/scripts/check-no-browser-dialogs.py':
    [Errno 2] No such file or directory

The guard itself was correct and had been negative tested. It simply never ran,
and the job went red on a missing file rather than on anything about the code.

WHY NEITHER PREFLIGHT NOR THE GAP REPORT COULD SEE IT

scripts/preflight.sh runs the same command from the repository root, where it
works. scripts/preflight-gaps.py compares the command TEXT and found it present
in preflight, so it counted the step as covered. Both were right about the
command and blind to where it would run. That is a property of the workflow
file, so it needs a check that reads the workflow file.

WHAT IT CHECKS

For every job that sets a default working directory, every step whose `run`
names a path that exists at the repository root but NOT under that directory
must declare a `working-directory` of its own. That is the exact condition, and
it flags nothing else: a step that only runs npm scripts, or names a path that
exists in both places, is left alone.

Usage:  python3 scripts/check-ci-workdir.py
Exit:   0 = every step will find its files, 1 = one will not
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS = os.path.join(ROOT, '.github', 'workflows')

# A path-looking token in a shell command: at least one slash, and an extension
# or a known directory prefix. Deliberately narrow. A false positive here would
# demand `working-directory` on a step that does not need it, and a guard that
# cries wolf is one people learn to edit around.
PATH_TOKEN = re.compile(r'(?<![\w./-])((?:supabase|scripts|web|site|site-src|docs)/[\w./-]+)')


def steps_of(text: str):
    """(job default working directory, step name, its working-directory, its run).

    Parsed with indentation rules rather than a YAML library: the runner has no
    pyyaml, and adding a dependency to a guard is how the guard stops running.
    """
    out = []
    job_wd = None
    step_name = None
    step_wd = None
    step_run = []
    in_run_block = False
    run_indent = 0

    def flush():
        if step_name is not None:
            out.append((job_wd, step_name, step_wd, '\n'.join(step_run)))

    for line in text.split('\n'):
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())

        if in_run_block:
            if stripped and indent <= run_indent:
                in_run_block = False
            else:
                step_run.append(stripped)
                continue

        # A job header sits at four spaces ("  jobname:" is two, its keys four).
        m = re.match(r'^  (\w[\w-]*):\s*$', line)
        if m:
            flush()
            job_wd = None
            step_name = None
            step_wd = None
            step_run = []
            continue

        m = re.match(r'^\s+working-directory:\s*(\S+)\s*$', line)
        if m:
            if step_name is None:
                job_wd = m.group(1).strip('"\'')
            else:
                step_wd = m.group(1).strip('"\'')
            continue

        m = re.match(r'^\s+-\s+name:\s*(.+?)\s*$', line)
        if m:
            flush()
            step_name = m.group(1)
            step_wd = None
            step_run = []
            continue

        m = re.match(r'^(\s+)run:\s*(\|?)(.*)$', line)
        if m:
            if m.group(2) == '|':
                in_run_block = True
                run_indent = len(m.group(1))
            else:
                step_run.append(m.group(3).strip())
            continue

    flush()
    return out


# The floor. This project has had two guards that silently measured nothing --
# a link checker whose extraction broke and reported zero tenant tables, and a
# bundle glob that matched no files -- so a parser that suddenly finds no
# workflow steps must say so rather than print a pass.
MIN_STEPS = 40


def main() -> int:
    bad = []
    checked = 0
    parsed = 0
    for name in sorted(os.listdir(WORKFLOWS)):
        if not name.endswith(('.yml', '.yaml')):
            continue
        path = os.path.join(WORKFLOWS, name)
        text = open(path, encoding='utf-8').read()
        for job_wd, step, step_wd, run in steps_of(text):
            parsed += 1
            if not job_wd or job_wd == '.' or step_wd:
                continue
            checked += 1
            for token in set(PATH_TOKEN.findall(run)):
                at_root = os.path.exists(os.path.join(ROOT, token))
                under = os.path.exists(os.path.join(ROOT, job_wd, token))
                if at_root and not under:
                    bad.append((name, step, job_wd, token))

    if parsed < MIN_STEPS:
        print(f'FAIL: only {parsed} workflow step(s) parsed, below the floor of '
              f'{MIN_STEPS}. The parser has stopped seeing the file, so a pass '
              'here would mean nothing. Fix scripts/check-ci-workdir.py.')
        return 1

    if not bad:
        print(f'every CI step finds its files ({parsed} step(s) parsed, {checked} '
              'inheriting a default working directory)')
        return 0

    print('A CI step will run from the wrong directory and fail on a missing file:')
    print()
    for wf, step, wd, token in bad:
        print(f'  {wf}: "{step}"')
        print(f'      runs from {wd}/, and {token} does not exist there')
    print()
    print('Add `working-directory: .` to the step, next to its `run:`. Nine steps')
    print('in this workflow already do; the tenth did not, and CI went red on a')
    print('missing file rather than on anything about the code.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
