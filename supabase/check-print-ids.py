#!/usr/bin/env python3
"""
Every Print button must actually put something on the paper.

WHY THIS EXISTS

web/src/index.css prints by hiding everything and then revealing a NAMED LIST of
ids:

    @media print { body * { visibility: hidden }
                   #receipt, #receipt *, #challan, ... { visibility: visible } }

That is a good pattern and it has one failure mode, which shipped: the parent
portal's Fees tab had a Print button calling window.print() on a page whose
printable carried no id at all. `body * { visibility: hidden }` won and the
printer produced a BLANK SHEET — every time, on every browser. Nothing threw,
nothing logged, the print dialog opened normally, the preview was empty. The only
person who ever found out was a parent who had already paid a shop for the print.

No unit test can see that: the bug is not in the component and not in the
stylesheet, it is in the fact that they were never introduced. So this checks the
two directions that matter.

  1. A FILE THAT CALLS window.print() MUST REACH AN ALLOW-LISTED ID — in itself,
     or in a component it imports (two hops, which covers page → dialog → doc).
     This is the blank-page bug, stated directly.

  2. EVERY ALLOW-LISTED ID MUST STILL BE USED. An id left in the CSS after its
     component is renamed is not harmless: the next person reads the list as the
     inventory of printable surfaces, and it is quietly wrong. Every stale
     allow-list in this repository — bundles stopping at 0039, the challan
     harness nothing ran — rotted the same way.

  3. EVERY printId A CALLER PASSES MUST BE ALLOW-LISTED. DataTable renders
     `<div id={printId}>` and shows its Print button only when that prop is set,
     so the id arrives from the screen using it. `printId="reprot"` renders a div
     with that id, shows the button, prints nothing, and is invisible to the
     compiler. That check is what earns DataTable its exemption from rule 1.

It found the portal (the bug above) and one more the same day: FamilyCollect's
"Print receipt" — at the fee counter, the screen that runs two hundred times a
day — called window.print() on a page with no printable on it either.

Usage:  python3 supabase/check-print-ids.py     (no database, no browser needed)
"""
import os
import re
import sys
from collections import deque

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'web', 'src')
CSS = os.path.join(SRC, 'index.css')
MAX_HOPS = 2

# --- 1. the allow-list, read out of the stylesheet -------------------------
try:
    css = open(CSS, encoding='utf-8').read()
except OSError as e:
    sys.exit(f'REFUSING TO REPORT SUCCESS: cannot read {CSS}: {e}')

m = re.search(r'@media\s+print\s*\{(.*)\n\}', css, re.S)
if not m:
    sys.exit(f'REFUSING TO REPORT SUCCESS: no @media print block in {CSS}. '
             'Either printing was reworked and this check needs rewriting, or '
             'every printable in the app just stopped printing.')
block = m.group(1)
allowed = sorted(set(re.findall(r'#([a-zA-Z][\w-]*)', block)))
if not allowed:
    sys.exit('REFUSING TO REPORT SUCCESS: the print block names no ids at all.')

# --- 2. what every source file declares, prints and imports ---------------
"""
DataTable renders `<div id={printId}>` from a prop and shows its Print button
only when that prop is set, so its own file contains no literal id. Exempted by
name — and in exchange every printId VALUE any caller passes is checked against
the allow-list below, which is the check that actually protects those screens.
"""
PROP_ID_COMPONENTS = {
    os.path.join('web', 'src', 'components', 'DataTable.tsx'):
        'renders id={printId} from a prop; callers supply the id and every '
        'printId value is checked separately',
}

ids, prints, imports, prop_ids = {}, set(), {}, {}
for base, _dirs, files in os.walk(SRC):
    for f in files:
        if not f.endswith(('.tsx', '.ts')):
            continue
        path = os.path.join(base, f)
        rel = os.path.relpath(path, ROOT)
        text = open(path, encoding='utf-8').read()
        # `id="x"` on an element, and the value a caller hands DataTable.
        prop_ids[rel] = set(re.findall(r'\bprintId="([a-zA-Z][\w-]*)"', text))
        ids[rel] = set(re.findall(r'\bid="([a-zA-Z][\w-]*)"', text)) | prop_ids[rel]
        # A call, not a mention: the component that documents the old bug in its
        # header comment must not be reported as committing it.
        if re.search(r'window\.print\(\)', re.sub(r'/\*.*?\*/', '', text, flags=re.S)):
            prints.add(rel)
        deps = set()
        for spec in re.findall(r"""from\s+['"]([^'"]+)['"]""", text):
            if spec.startswith('@/'):
                cand = os.path.join('web', 'src', spec[2:])
            elif spec.startswith('.'):
                cand = os.path.relpath(
                    os.path.normpath(os.path.join(base, spec)), ROOT)
            else:
                continue                      # a package, not our code
            for ext in ('.tsx', '.ts', '/index.tsx', '/index.ts'):
                if os.path.exists(os.path.join(ROOT, cand + ext)):
                    deps.add(cand + ext)
                    break
        imports[rel] = deps

declared = set().union(*ids.values()) if ids else set()

fail = []

# --- 3. every Print button reaches a printable ----------------------------
for f in sorted(prints):
    if f in PROP_ID_COMPONENTS:
        continue
    seen, q, reached = {f}, deque([(f, 0)]), None
    while q and reached is None:
        cur, hop = q.popleft()
        hit = ids.get(cur, set()) & set(allowed)
        if hit:
            reached = (cur, sorted(hit))
            break
        if hop < MAX_HOPS:
            for d in imports.get(cur, ()):
                if d not in seen:
                    seen.add(d)
                    q.append((d, hop + 1))
    if reached is None:
        fail.append(
            f'{f} calls window.print() but neither it nor anything it imports '
            f'carries an id from the print allow-list. It will print a BLANK '
            f'PAGE. Give the printable an id and add that id to the @media '
            f'print block in web/src/index.css.')

# --- 3b. every printId a caller passes is a real printable ----------------
# The exemption above is only sound if this runs. A screen passing
# printId="reprot" would render <div id="reprot">, show a Print button, and
# print nothing — with no typo visible anywhere a compiler looks.
passed = 0
for f, vals in sorted(prop_ids.items()):
    for v in sorted(vals):
        passed += 1
        if v not in allowed:
            fail.append(
                f'{f} passes printId="{v}" and index.css does not reveal #{v} '
                f'for print. That table\'s Print button will print a blank page.')

# --- 4. no allow-listed id has gone stale ---------------------------------
for i in allowed:
    if i not in declared:
        fail.append(
            f'index.css reveals #{i} for print and nothing in web/src carries '
            f'that id. Either the component was renamed — in which case its '
            f'replacement prints blank — or the entry is dead and should go.')

if fail:
    print('Print wiring is broken:\n')
    for line in fail:
        print('  * ' + line)
    print('\n::error::a Print button that produces a blank page')
    sys.exit(1)

print(f'print allow-list: {len(allowed)} id(s) — {", ".join(allowed)}')
print(f'{len(prints) - len(PROP_ID_COMPONENTS)} file(s) call window.print() and each '
      f'reaches a printable within {MAX_HOPS} import hop(s); '
      f'{passed} distinct printId value(s) across the callers all name an '
      f'allow-listed id; '
      f'no allow-list entry is stale')
for f, why in PROP_ID_COMPONENTS.items():
    print(f'  exempt: {f} — {why}')
