#!/usr/bin/env bash
# Run CI's own "Sanity checks" step against $PGDATABASE.
#
# WHY THIS FILE EXISTS, AND IT COST A RED CI.
#
# That step is a long inline SQL block in .github/workflows/ci.yml: it admits a
# pupil, bills a class, applies a fine, adjusts, waives, grants a discount,
# bills again, and asserts the running balance after every one. It is a caller
# of a dozen fee functions and nothing was checking it. preflight-gaps.py had
# always printed it as "not covered", honestly, and it sat there.
#
# Then 0138 changed fn_add_discount to take a CHILD rather than an enrolment.
# Every SQL suite passed, every guard passed, preflight said CLEAN, and CI went
# red on one line inside that block still passing an enrolment id.
#
# EXTRACTED FROM ci.yml, NEVER COPIED. A second copy of a hundred and ninety
# lines of assertions drifts from the first, and a drifted copy that passes
# here while CI fails is worse than not running it at all.
#
# Run: PGDATABASE=<a fully migrated db> bash scripts/ci-sanity.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

python3 - "$OUT" <<'PY'
import re, sys
out = sys.argv[1]
s = open('.github/workflows/ci.yml').read()
i = s.find('      - name: Sanity checks')
if i < 0:
    sys.stderr.write('scripts/ci-sanity.sh: no "Sanity checks" step in ci.yml. '
                     'If it was renamed, rename it here too rather than deleting '
                     'this guard.\n')
    sys.exit(2)
m = re.search(r'\n      - name: ', s[i + 10:])
step = s[i:i + 10 + m.start()] if m else s[i:]
k = step.index('run: |')
body = step[k + len('run: |'):]
# The block is indented ten spaces inside the YAML. Strip exactly that, so a
# heredoc terminator inside it still starts at column zero.
open(out, 'w').write(
    '\n'.join(ln[10:] if ln.startswith(' ' * 10) else ln for ln in body.split('\n')))
PY

bash "$OUT"
