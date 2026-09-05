#!/usr/bin/env python3
"""
No school action may depend on a browser dialog.

WHY THIS EXISTS

Twelve places in this app asked for money amounts and audit reasons with
window.prompt, and one confirmed locking a day's register with window.confirm.
Applying a fine, waiving a fine, adjusting a balance, reversing a receipt,
reversing an expense, reversing an income entry, cancelling a bounced challan,
skipping a WhatsApp message, pulling a release, restoring a review, finalising
attendance. Every one of those writes to a school's books.

Four things are wrong with that, in rough order of how badly they bite:

  1. THEY CAN BE TURNED OFF. Chrome offers "prevent this page from creating
     additional dialogs" after the second one in a row, which the adjustment
     flow hits every single time because it asked three questions back to back.
     Once ticked, prompt() returns null and confirm() returns false FOR EVER.
     The calling code reads that as "the user pressed Cancel", so the button
     silently stops working, no error is shown, nothing is logged, and the only
     evidence is a clerk saying "it does nothing". They are also suppressed
     outright in sandboxed frames.

  2. NO CONTEXT. A browser dialog cannot show the child's name, the current
     balance or what the number will do. "Adjustment amount: negative for a
     credit/waiver, positive to add a charge (Rs):" is a manual squeezed into a
     title bar, and it was the only guidance anybody got.

  3. VALIDATION AFTER THE FACT. A one-character reason passed the browser and
     was refused by the database, so the typing was lost and a Postgres error
     came back instead.

  4. THEY BLOCK THE MAIN THREAD and look nothing like the rest of the product,
     on a page a school is being asked to trust with its money.

web/src/components/AskDialog.tsx replaced all thirteen. This stops the next one.

The guard reads the SOURCE, not a rendered page, because the failure is not
visible at runtime until the day a browser decides to suppress the dialog.

Usage:  python3 scripts/check-no-browser-dialogs.py
Exit:   0 = clean, 1 = a browser dialog is back
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'web', 'src')

CALL = re.compile(r'\bwindow\.(prompt|alert|confirm)\s*\(')

# COMMENTS ARE STRIPPED FIRST, and the first version of this guard did not do
# that. It failed on its own replacement: AskDialog.tsx's header explains that it
# replaced `window.prompt()`, at twelve call sites, and the docstring above
# asserted that no prose would ever write the call with its parenthesis. Two
# comments in this repository do, both of them written to record the very fix
# this guard defends. A checker that forbids explaining what it enforces teaches
# people to stop explaining.
BLOCK = re.compile(r'/\*.*?\*/', re.S)


def code_only(text: str) -> str:
    """The file with comments blanked out, line count preserved so the reported
    line number still points at the real line.

    `//` is cut only when it is not part of `://`, so a URL in a string survives
    rather than swallowing the rest of the line."""
    text = BLOCK.sub(lambda m: '\n' * m.group(0).count('\n'), text)
    out = []
    for line in text.split('\n'):
        i = 0
        while True:
            i = line.find('//', i)
            if i < 0:
                break
            if i > 0 and line[i - 1] == ':':
                i += 2
                continue
            line = line[:i]
            break
        out.append(line)
    return '\n'.join(out)

# Nothing is exempt today, and that is the point of writing the dict rather than
# leaving the idea implicit: an exemption is a decision that needs a reason
# beside it, not a pattern somebody quietly widens.
ALLOWED: "dict[str, str]" = {}


def main() -> int:
    bad = []
    for base, _dirs, files in os.walk(SRC):
        for name in files:
            if not name.endswith(('.ts', '.tsx')):
                continue
            path = os.path.join(base, name)
            rel = os.path.relpath(path, ROOT)
            if rel in ALLOWED:
                continue
            with open(path, encoding='utf-8') as fh:
                lines = code_only(fh.read()).split('\n')
            for n, line in enumerate(lines, 1):
                m = CALL.search(line)
                if m:
                    bad.append((rel, n, m.group(1), line.strip()[:90]))

    if not bad:
        print('no window.prompt / alert / confirm in web/src '
              '(use web/src/components/AskDialog.tsx)')
        return 0

    print('A browser dialog is back. These are suppressible: once a browser is')
    print('told to stop showing dialogs from the page, prompt() returns null and')
    print('confirm() returns false for ever, and the button silently stops working.')
    print()
    for rel, n, kind, text in bad:
        print(f'  {rel}:{n}  window.{kind}(')
        print(f'      {text}')
    print()
    print('Use <AskDialog> from web/src/components/AskDialog.tsx. It asks for an')
    print('amount and a reason in one dialog, shows the context a browser cannot,')
    print('validates before the database refuses, and cannot be turned off.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
