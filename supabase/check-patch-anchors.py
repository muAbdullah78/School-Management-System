#!/usr/bin/env python3
"""A migration that edits somebody else's function may not anchor on whitespace.

WHY THIS EXISTS

0101 added one `perform` to four functions that are 60 to 114 lines long. It did
not retype them -- retyping a body to add a statement is how a stack of earlier
fixes gets silently reverted, which this repository has recorded happening twice
-- so it read each definition from the catalogue and inserted the statement.
It found the insertion point with

    position(E'\\n  end if;\\n' in substr(v_src, v_at))

That applied on every database built in this repository and failed on the first
real school:

    ERROR: 0101: could not find the end of fn_enter_marks's permission gate.

Because the Supabase SQL editor runs a pasted file as ONE transaction, that
single raise rolled back all seven migrations in bundle 12. The fee total, the
headcount, the attendance rule, the till, the family's deposit and the parent
login were all lost to a whitespace assumption in the seventh.

WHY THAT ANCHOR AND NOT THE OTHERS

Twenty-two migrations edit a function they did not write, and twenty-one of them
were fine. The difference is what the pattern was made of.

  * `E'\\n'` is an escape-string literal. It is ONE LINE FEED, always, whatever
    the file it was typed in looks like. A stored function body whose lines end
    CRLF -- which is what a body created by pasting a CRLF file into a browser
    SQL editor contains -- has \\r\\n, and an LF needle is simply not in it.
  * a newline typed INSIDE a string that spans two lines of the migration file
    is whatever that file's line endings are. Paste a CRLF file and the pattern
    is CRLF too, so it matches a CRLF body. It works, and it works by accident:
    the pattern and the target agree only because they arrived by the same
    route. A school that applies some bundles with the psql CLI and pastes a
    later one in the browser breaks the agreement.
  * `\\s`, `\\s+`, `\\s*` in a regex match a space, a tab, a line feed and a
    carriage return alike, so they cannot be wrong about any of this.

So: a needle or pattern matched against a function definition may not contain a
newline in ANY form. Use `\\s+` where the source has a line break, or anchor on
a single line, or call public.fn__patch_after_gate, which is tested against five
spellings of the same gate in supabase/tests/patch_anchors.sql.

Exit 0 when clean, 1 with the offending lines otherwise.
"""
import pathlib
import re
import sys

MIGRATIONS = pathlib.Path('supabase/migrations')

# The calls whose NEEDLE is matched against text. For each, which argument is
# the needle: position() is special-cased because its needle comes before ` in `.
NEEDLE_ARG = {
    'replace': 1,          # replace(subject, from, to)
    'regexp_replace': 1,   # regexp_replace(subject, pattern, replacement[, flags])
    'regexp_match': 1,
    'regexp_matches': 1,
    'regexp_count': 1,
    'regexp_instr': 1,
    'regexp_like': 1,
    'strpos': 1,           # strpos(haystack, needle)
    'split_part': 1,
}
CALL = re.compile(r'\b(position|' + '|'.join(NEEDLE_ARG) + r')\s*\(')

# The three ways a pattern can carry a line ending, and why each is wrong.
E_NEWLINE = re.compile(r'\\[nr]')
CHR_NEWLINE = re.compile(r'\bchr\s*\(\s*1[03]\s*\)')
WHY_E = ("an E'...' escape is always a bare line feed, so it cannot match a "
         "body whose lines end CRLF")
WHY_CHR = ('chr(10)/chr(13) is one exact line ending, and a stored body may '
           'carry the other')
WHY_LITERAL = ("a newline typed inside the pattern is whatever this file's "
               'line endings are, so it matches only a body that arrived by '
               'the same route')

def newline_in_pattern(sql, lo, hi):
    """Why this pattern carries a line ending, or None.

    Only the CONTENT of the pattern counts. An earlier version tested the raw
    slice between two commas, which begins with the newline and indentation the
    migration was formatted with, so every multi-line call was reported and the
    real ones were lost in the noise. A pattern spread over several lines with
    `||` is fine; a pattern with a newline INSIDE a literal is not.
    """
    arg = sql[lo:hi]
    # chr(10)/chr(13) in the code part of the argument.
    lit = spans(arg)
    code = ''.join(arg[a:b] for a, b in
                   [(0, lit[0][0]) if lit else (0, len(arg))]
                   + [(lit[i][1], lit[i + 1][0]) for i in range(len(lit) - 1)]
                   + ([(lit[-1][1], len(arg))] if lit else []))
    if CHR_NEWLINE.search(code):
        return WHY_CHR
    for a, b in lit:
        text = arg[a:b]
        if text.startswith('--'):
            continue                      # a comment about the pattern is not the pattern
        if text.startswith('$'):
            if '\n' in text:
                return WHY_LITERAL
            continue
        body = text
        is_e = a > 0 and arg[a - 1] in 'eE'
        if is_e and E_NEWLINE.search(body):
            return WHY_E
        if '\n' in body:
            return WHY_LITERAL
    return None


def spans(sql):
    """Yield (start, end) of every string literal and comment, so a scan can
    skip them. Handles '' escaping, E'\\'' escaping, dollar quoting and -- to
    end of line. Block comments do not appear in these files and are not
    special-cased; if one is added this returns them as code, which is loud
    rather than silent."""
    out, i, n = [], 0, len(sql)
    while i < n:
        c = sql[i]
        if c == '-' and sql.startswith('--', i):
            j = sql.find('\n', i)
            j = n if j < 0 else j
            out.append((i, j))
            i = j
        elif c == '$':
            # A dollar-quoted block is CODE, not a string: every one of these
            # rewrites lives inside `do $patch$ ... $patch$`, and an earlier
            # version of this file treated that as one big literal and so found
            # nothing at all anywhere. Only the delimiters are skipped; the scan
            # continues inside.
            m = re.match(r'\$[A-Za-z_]*\$', sql[i:])
            if m:
                out.append((i, i + len(m.group(0))))
                i += len(m.group(0))
            else:
                i += 1
        elif c == "'":
            esc = i > 0 and sql[i - 1] in 'eE' and not re.match(r'\w', sql[i - 2] if i > 1 else ' ')
            j = i + 1
            while j < n:
                if sql[j] == '\\' and esc:
                    j += 2
                    continue
                if sql[j] == "'":
                    if j + 1 < n and sql[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            out.append((i, j))
            i = j
        else:
            i += 1
    return out


def code_only(sql, lo, hi, skip):
    """True when the position is not inside a string or comment."""
    return not any(a <= lo < b for a, b in skip)


def close_paren(sql, open_at, skip):
    depth, i, n = 0, open_at, len(sql)
    while i < n:
        if any(a <= i < b for a, b in skip):
            i = next(b for a, b in skip if a <= i < b)
            continue
        if sql[i] == '(':
            depth += 1
        elif sql[i] == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def top_level_split(sql, lo, hi, skip, sep=','):
    """Split the argument list between lo and hi on top-level separators."""
    parts, depth, start, i = [], 0, lo, lo
    while i < hi:
        inside = next((b for a, b in skip if a <= i < b), None)
        if inside is not None:
            i = min(inside, hi)
            continue
        c = sql[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
        elif depth == 0 and sql.startswith(sep, i):
            parts.append((start, i))
            i += len(sep)
            start = i
            continue
        i += 1
    parts.append((start, hi))
    return parts


def check(path):
    sql = path.read_text()
    if 'pg_get_functiondef' not in sql:
        return []
    skip = spans(sql)
    bad = []
    for m in CALL.finditer(sql):
        if not code_only(sql, m.start(), m.end(), skip):
            continue
        name = m.group(1)
        op = m.end() - 1
        cp = close_paren(sql, op, skip)
        if cp < 0:
            continue
        if name == 'position':
            # position(needle in haystack) -- and ` in ` may itself be inside a
            # string, which top_level_split already skips.
            parts = top_level_split(sql, op + 1, cp, skip, ' in ')
            if len(parts) < 2:
                continue
            needle = parts[0]
        else:
            parts = top_level_split(sql, op + 1, cp, skip)
            idx = NEEDLE_ARG[name]
            if len(parts) <= idx:
                continue
            needle = parts[idx]
        why = newline_in_pattern(sql, needle[0], needle[1])
        if why:
            line = sql.count('\n', 0, needle[0]) + 1
            snippet = sql[needle[0]:needle[1]].strip().splitlines()[0][:70]
            bad.append((line, name, why, snippet))
    return bad


def main():
    if not MIGRATIONS.is_dir():
        print('check-patch-anchors: run me from the repository root', file=sys.stderr)
        return 1
    fails = 0
    for path in sorted(MIGRATIONS.glob('*.sql')):
        for line, name, why, snippet in check(path):
            print(f'{path}:{line}: {name}() is matched against a function '
                  f'definition and its pattern carries a newline.')
            print(f'      {why}.')
            print(f'      {snippet}')
            print('      Use \\s+ for the line break, anchor on a single line, '
                  'or call public.fn__patch_after_gate.')
            fails += 1
    if fails:
        print(f'\ncheck-patch-anchors: {fails} whitespace-dependent anchor(s). '
              'This is the flaw that cost bundle 12 seven migrations on a live '
              'school; see supabase/tests/patch_anchors.sql.')
        return 1
    n = sum(1 for p in MIGRATIONS.glob('*.sql')
            if 'pg_get_functiondef' in p.read_text())
    print(f'check-patch-anchors: ok ({n} migrations edit a function they did '
          'not write; none anchor on whitespace)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
