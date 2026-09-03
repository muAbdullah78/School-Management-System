#!/usr/bin/env python3
"""
Build site/guide.html from the template plus the captured screenshots.

WHY A BUILD STEP AND NOT A HAND-WRITTEN FILE

The guide has to carry its screenshots inside it: it is sent to schools as one
file, and a guide whose pictures are separate arrives with broken images the
first time somebody forwards it. So every PNG is embedded as a data URI, and
nobody can hand-maintain 1.5MB of base64.

More importantly, this makes the guide REPRODUCIBLE. Change a screen, re-run the
harness and this script, and the guide's pictures follow. The alternative, a
document with pasted images, starts drifting from the software the day it is
written, and a manual that shows a screen the school cannot find is worse than no
manual.

    cd web && npm run build && npm run harness   # render the screens to HTML
    cd .. && node scripts/shot-guide.mjs         # photograph them
    python3 scripts/build-guide.py               # embed and write site/guide.html

Missing images are a hard error, not a gap: a guide with a caption and no picture
under it reads as a fault in the reader's own device.
"""
import base64
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / 'docs' / 'guide' / 'guide.template.html'
IMG_DIR = ROOT / 'scratch' / 'guide-img'
OUT = ROOT / 'site' / 'guide.html'

# The artifact ceiling is 16MB and base64 adds about a third. Warn well below it,
# because the failure at the limit is a publish that is refused after the work.
WARN_BYTES = 8 * 1024 * 1024


def main() -> int:
    if not TEMPLATE.exists():
        print(f'missing template: {TEMPLATE}', file=sys.stderr)
        return 1
    html = TEMPLATE.read_text(encoding='utf-8')

    wanted = re.findall(r'\{\{IMG:([a-z0-9-]+)\}\}', html)
    if not wanted:
        print('the template asks for no images, which is almost certainly wrong',
              file=sys.stderr)
        return 1

    missing = [n for n in dict.fromkeys(wanted)
               if not (IMG_DIR / f'{n}.png').exists()]
    if missing:
        print('these screenshots have not been captured:', file=sys.stderr)
        for n in missing:
            print(f'  {n}.png', file=sys.stderr)
        print(f'\nRun the harness and the capture script first. Looked in {IMG_DIR}.',
              file=sys.stderr)
        return 1

    total = 0
    for name in dict.fromkeys(wanted):
        raw = (IMG_DIR / f'{name}.png').read_bytes()
        total += len(raw)
        uri = 'data:image/png;base64,' + base64.b64encode(raw).decode('ascii')
        html = html.replace(f'{{{{IMG:{name}}}}}', uri)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(html, encoding='utf-8')
    size = OUT.stat().st_size
    print(f'wrote {OUT.relative_to(ROOT)}: {size // 1024} KB '
          f'({len(set(wanted))} screenshot(s), {total // 1024} KB before base64)')
    if size > WARN_BYTES:
        print(f'WARNING: {size // 1024 // 1024} MB. The artifact limit is 16MB, '
              'shrink the screenshots before adding more.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
