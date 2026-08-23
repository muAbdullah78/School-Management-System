#!/usr/bin/env python3
"""
`readonly` must never be able to write. Ask the catalogue, not the diff.

WHY THIS EXISTS

0059 made `readonly` a real observer: it reads everything a staff member can read
and writes nothing. The read half is carried by one helper —

    may_view(variadic roles) := has_role(variadic roles) or has_role('readonly')

— and the whole guarantee rests on that helper never reaching a write. It is one
`replace()` away from doing so: somebody widening a policy, or copying a read
function into a write one, and `readonly` silently gains the ability to change a
child's record. Nothing in a code review reliably catches that, because the
change looks like the twenty-odd correct ones around it.

So this asks the live catalogue three questions:

  1. Does any INSERT / UPDATE / DELETE / ALL policy mention `may_view` or
     `readonly`?
  2. Does any VOLATILE function mention `may_view` or `readonly`?
  3. Is `may_view` actually still in use, in enough places to be the mechanism
     it claims to be?

Question 3 is the one that stops this check going quietly vacuous. A migration
that dropped `may_view` and reverted every read gate to `has_role` would pass
questions 1 and 2 perfectly — by having nothing left to find. Same trick as
check-definer-queries.py.

EXEMPTIONS, and why there are two

`handle_new_user` is VOLATILE and mentions 'readonly' because it CHOOSES that
role as the fallback for an invited account. That is the point of the function,
not a leak.

`fn_family_sheet` is VOLATILE only because of how it was written, and it mentions
readonly in a read gate. It is exempt by name rather than by rule, because a rule
that let any VOLATILE function name readonly would defeat the whole check.

Usage:  ./supabase/check-readonly-writes.py
        (needs PG* env vars pointing at a database with the migrations applied)
"""
import os
import subprocess
import sys

# Named exemptions only. Each one is a decision, not a category.
ALLOWED_VOLATILE = {
    'handle_new_user':
        "chooses 'readonly' as the fallback role for an invited account — "
        "that is what the function is for",
    'fn_family_sheet':
        "a read gate that happens to sit in a VOLATILE function; it selects and "
        "returns, it does not write",
}

# Below this, the check is not measuring anything. 0059 rewrote 27 read gates and
# 19 SELECT policies, so 30 is a floor with room for legitimate churn.
MIN_USES = 30


def q(sql: str) -> list[str]:
    r = subprocess.run(['psql', '-tA', '-v', 'ON_ERROR_STOP=1', '-c', sql],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr.strip(), file=sys.stderr)
        print('could not query the database — are PG* env vars set?', file=sys.stderr)
        sys.exit(1)
    return [ln for ln in r.stdout.strip().split('\n') if ln]


def main() -> int:
    problems: list[str] = []

    # ---- 1. Write policies ---------------------------------------------------
    # polcmd: 'r' SELECT, 'a' INSERT, 'w' UPDATE, 'd' DELETE, '*' ALL.
    # Anything that is not 'r' can write, and an ALL policy covers SELECT too so
    # it cannot be treated as a read.
    rows = q("""
        select c.relname || '.' || pol.polname || ' (' || pol.polcmd::text || ')'
          from pg_policy pol
          join pg_class c on c.oid = pol.polrelid
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public'
           and pol.polcmd <> 'r'
           and (coalesce(pg_get_expr(pol.polqual, pol.polrelid), '')
             || coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), ''))
               ~ '(may_view|readonly)'
         order by 1
    """)
    for r in rows:
        problems.append(f'WRITE POLICY grants an observer: {r}')

    # ---- 2. Volatile functions ----------------------------------------------
    rows = q("""
        select p.proname
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.provolatile = 'v'
           and p.prosrc ~ '(may_view|readonly)'
         order by 1
    """)
    for name in rows:
        if name in ALLOWED_VOLATILE:
            print(f'  allowed: {name} — {ALLOWED_VOLATILE[name]}')
            continue
        problems.append(
            f'VOLATILE function mentions may_view/readonly: {name} — '
            'a volatile function can write')

    # ---- 3. No read gate left behind — EXACT, not a threshold ---------------
    # A count threshold was the first version of this and it is not good enough.
    # On the upgrade path, re-applying bundle 5 after 0059 restores SEVEN
    # has_role read gates from migrations 0050-0056; a `>= 30` check passes
    # happily on the remaining forty while those seven screens silently return
    # zero rows to an observer again. Only naming the stragglers sees a PARTIAL
    # revert. Proven by running the upgrade job, not reasoned about.
    stragglers = q("""
        select p.proname
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.prosecdef and p.provolatile in ('s','i')
           and p.prosrc like '%has_role(%'
           and p.proname not in ('fn_may_manage_class', 'fn_may_write_school_file',
                                 'may_view')
         order by 1
    """)
    if stragglers:
        print(f'\n{len(stragglers)} READ GATE(S) STILL ON has_role:', file=sys.stderr)
        for name in stragglers:
            print(f'  {name}', file=sys.stderr)
        print('\nEach of these is a screen that returns zero rows to a `readonly` '
              'login — the defect 0059 removed. If a bundle or migration was '
              're-applied out of order, re-run migrations/0059_readonly_boundary.sql: '
              'its rewrite is idempotent.', file=sys.stderr)
        return 1

    uses = int(q("""
        select (
          (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prosrc like '%may_view(%')
        + (select count(*) from pg_policy pol
             join pg_class c on c.oid = pol.polrelid
             join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public'
              and coalesce(pg_get_expr(pol.polqual, pol.polrelid), '') like '%may_view(%')
        )::text
    """)[0])

    # Kept as a floor as well as the exact check above: if somebody deleted
    # may_view AND every read gate that used it, the exact check would find
    # nothing to complain about by having nothing left to look at.
    if uses < MIN_USES:
        print(f'\nmay_view is used in only {uses} place(s), expected at least {MIN_USES}.',
              file=sys.stderr)
        print('The read gates were removed rather than reverted, so the exact check '
              'above found nothing. `readonly` now reads nothing at all.',
              file=sys.stderr)
        return 1

    # ---- 4. The helper itself must be STABLE --------------------------------
    vol = q("""
        select p.provolatile
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'may_view'
    """)
    if not vol:
        print('\nmay_view does not exist. Run migrations/0059_readonly_boundary.sql.',
              file=sys.stderr)
        return 1
    if vol[0] not in ('s', 'i'):
        problems.append('may_view is VOLATILE — it must be STABLE, or it can be '
                        'called from a write path without this check noticing')

    if problems:
        print('\nAN OBSERVER CAN WRITE:', file=sys.stderr)
        for p in problems:
            print(f'  {p}', file=sys.stderr)
        print('\n`readonly` exists to look at everything and change nothing. A write '
              'path that consults may_view — or names readonly directly — breaks that '
              'silently, because RLS lets a permitted UPDATE through without anything '
              'looking different. See docs/READONLY-DESIGN.md.', file=sys.stderr)
        return 1

    print(f'checked every write policy and every VOLATILE function; '
          f'may_view is used in {uses} read gate(s)')
    print('an observer can read, and cannot write anywhere')
    return 0


if __name__ == '__main__':
    if not os.environ.get('PGDATABASE') and not os.environ.get('PGHOST'):
        print('set PG* env vars first', file=sys.stderr)
    sys.exit(main())
