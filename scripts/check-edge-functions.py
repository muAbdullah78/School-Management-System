#!/usr/bin/env python3
"""Every Edge Function must be invoked, deployable, and told about.

WHY THIS EXISTS

A real school ran with two of the three Edge Functions deployed for ten days.
Nothing reported it. The cause was not the operator forgetting: docs/SETUP.md
listed three functions in a table, and then the numbered step under it said

    Name it exactly `signup-school`, then repeat for `create-teacher`.

and the command-line block deployed the same two. Somebody following the
instructions correctly deployed two of three. `create-school-owner` was added to
the project ten days after that page was written and only the table was updated.

The way that failure shows up is not an error message. A school added from the
operator console has nobody who can sign in to it, and in the console it looks
exactly like an ordinary trialing customer, so it sits unused until somebody
says nobody ever sent them a password.

So three questions are asked of the files, and all three are the kind a person
cannot be relied on to re-ask:

  1. does every function the app invokes actually exist in this project?
     An invoke of a function nobody wrote is a screen that fails at runtime.
  2. is every function that exists invoked by something? A function nobody
     calls is either dead or a screen was never wired up, and this repository
     has recorded both.
  3. does every function appear in the DEPLOY STEPS of docs/SETUP.md, not
     merely in a table on the same page? The table was right and the steps
     were wrong, which is why matching on the whole file would have passed.

Exit 0 when clean, 1 with what is missing otherwise.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FUNCS = ROOT / 'supabase' / 'functions'
SETUP = ROOT / 'docs' / 'SETUP.md'
CLIENT = [ROOT / 'web' / 'src', ROOT / 'desktop']

INVOKE = re.compile(r"""functions\.invoke\(\s*['"]([a-z0-9-]+)['"]""")

# The lines that actually TELL somebody to deploy something: a CLI command, or
# the dashboard step that names the function to type. Deliberately not the whole
# file: a name mentioned in a prose table is not an instruction, and treating it
# as one is the exact hole this check closes.
DEPLOY = re.compile(r'^\s*(?:supabase functions deploy\s+([a-z0-9-]+)'
                    r'|\d+\.\s+Name it.*)$', re.M)


def invoked():
    found = {}
    for root in CLIENT:
        if not root.is_dir():
            continue
        for path in root.rglob('*'):
            if path.suffix not in ('.ts', '.tsx') or not path.is_file():
                continue
            for name in INVOKE.findall(path.read_text()):
                found.setdefault(name, []).append(
                    str(path.relative_to(ROOT)))
    return found


def deploy_instructions():
    """Every function name that appears in a deploy instruction."""
    if not SETUP.is_file():
        return None
    text = SETUP.read_text()
    names = set()
    for line in text.splitlines():
        if 'supabase functions deploy' in line:
            m = re.search(r'deploy\s+([a-z0-9-]+)', line)
            if m:
                names.add(m.group(1))
        # The dashboard step: "Name it **exactly** one of `a`, `b`, `c`."
        if re.match(r'\s*\d+\.\s+Name it', line):
            names.update(re.findall(r'`([a-z0-9-]+)`', line))
    return names


def main():
    if not FUNCS.is_dir():
        print('check-edge-functions: run me from the repository root',
              file=sys.stderr)
        return 1

    on_disk = sorted(p.name for p in FUNCS.iterdir()
                     if p.is_dir() and (p / 'index.ts').is_file())
    called = invoked()
    told = deploy_instructions()
    fails = 0

    if told is None:
        print('check-edge-functions: docs/SETUP.md is missing, so nothing '
              'tells an operator to deploy anything')
        return 1

    for name in sorted(called):
        if name not in on_disk:
            print(f'INVOKED BUT NOT WRITTEN: the app calls "{name}" and '
                  f'supabase/functions/{name}/index.ts does not exist')
            for where in called[name]:
                print(f'      called from {where}')
            fails += 1

    for name in on_disk:
        if name not in called:
            print(f'WRITTEN BUT NEVER CALLED: supabase/functions/{name} is '
                  'invoked by nothing in the app')
            fails += 1
        if name not in told:
            print(f'NOT IN THE DEPLOY STEPS: docs/SETUP.md never tells anybody '
                  f'to deploy "{name}"')
            print('      A name in a table is not an instruction. Add it to '
                  'the numbered step and to the command-line block.')
            fails += 1

    if fails:
        print(f'\ncheck-edge-functions: {fails} problem(s). A school ran for '
              'ten days with two of three functions deployed because the '
              'deploy steps named two and the table named three.')
        return 1

    print('check-edge-functions: ok ('
          f'{len(on_disk)} functions, each invoked by the app and named in the '
          'deploy steps)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
