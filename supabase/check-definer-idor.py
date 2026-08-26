#!/usr/bin/env python3
# =============================================================================
# The plainest IDOR: a definer function looking up a tenant row by a
# caller-supplied id, with no school filter.
#
# WHY THIS EXISTS
#
# fn_queue_message shipped in 0034 with
#
#     select * into v_f from public.families where id = p_family_id;
#
# inside a SECURITY DEFINER function, where RLS does not apply. School A's owner
# passed School B's family id and got School B's family head name, phone number,
# child's name and exact outstanding balance, written into School A's own
# message_outbox — a table School A is entitled to read, so nothing looked wrong
# afterwards. Enumerable one uuid at a time.
#
# TWO EXISTING GUARDS BOTH PASSED IT, and why is the whole design of this one:
#
#   * check-definer-queries.py hunts inequality comparisons between two table
#     columns — the fn_rollover bug, where "the next class up" had no school
#     filter and a rollover promoted children into another school's classroom.
#     Its header says it is deliberately narrow, because a broad version flagged
#     65 of 157 functions and was wrong about nearly all of them.
#
#   * dashboard.sql assertion 20 asks only whether a function MENTIONS scoping
#     somewhere in its body. fn_queue_message mentions current_school_id() twice
#     — for the template lookup and the school's name — so it passed while three
#     queries below sat wide open. One correct mention exempting several
#     incorrect ones is the exact failure that made check-definer-queries.py
#     necessary, recurring in a shape it does not look at.
#
# So this judges PER STATEMENT, and only the one shape:
#
#     a tenant table, filtered on a uuid PARAMETER of the enclosing function,
#     in a statement with no school_id predicate,
#     where assert_own() was not called on THAT parameter.
#
# assert_own on a DIFFERENT parameter does not count. That distinction is not
# pedantry: fn_rollover called assert_own on two session ids and had eight
# unscoped queries hiding behind those two correct calls.
#
# The codebase already holds to this standard — 33 of the 38 functions that take
# an id call assert_own, and fn_queue_enquiry_message scopes every lookup by hand.
# This makes the standard enforced rather than customary.
#
# Usage:  python3 supabase/check-definer-idor.py
#         (needs PG* env vars pointing at a database with the migrations applied)
# =============================================================================
import os
import re
import subprocess
import sys

# Named exemptions only, each with the reason it is safe. A category-based
# exemption would let the next instance in.
ALLOWED: "dict[str, str]" = {}

# Minimum number of definer functions we expect to inspect. Below this the check
# is measuring nothing, which is the failure mode two of this project's other
# guards have already had.
MIN_FUNCTIONS = 100


def q(sql: str) -> "list[list[str]]":
    """Rows as lists of fields, using control characters as separators.

    Function bodies contain newlines, commas, pipes and quotes, so the ordinary
    psql separators cannot be used — a body would be read as several rows.

    Filtering on `rec.strip()` rather than on the presence of the field
    separator: a SINGLE-column query emits no field separator at all, so the
    obvious `if '\\x01' in rec` dropped every row of the tenant-table query and
    the script reported zero tenant tables. Caught immediately by the
    MIN floor below rather than by silently passing, which is what that floor is
    for.
    """
    r = subprocess.run(
        ['psql', '-tA', '-R', '\x02', '-F', '\x01', '-v', 'ON_ERROR_STOP=1', '-c', sql],
        capture_output=True, text=True, env=dict(os.environ))
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        print('could not query the database — are PG* env vars set?', file=sys.stderr)
        sys.exit(1)
    return [rec.split('\x01') for rec in r.stdout.split('\x02') if rec.strip()]


def main() -> int:
    # Tenant tables from the CATALOGUE, never a hardcoded list — a hardcoded
    # list is how a table added later escapes the guard entirely.
    tenant = {row[0] for row in q("""
        select c.relname
          from pg_class c
          join pg_namespace n on n.oid = c.relnamespace
          join pg_attribute a on a.attrelid = c.oid
         where n.nspname = 'public' and c.relkind = 'r'
           and a.attname = 'school_id' and not a.attisdropped
    """)}
    if len(tenant) < 30:
        print(f'REFUSING TO REPORT SUCCESS: found only {len(tenant)} tenant tables; '
              'expected 30+. The catalogue query is wrong or the schema is not applied.',
              file=sys.stderr)
        return 1

    funcs = q("""
        select p.proname,
               p.prosrc,
               coalesce(array_to_string(p.proargnames, ','), ''),
               has_function_privilege('authenticated', p.oid, 'execute')::text
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.prosecdef and p.prokind = 'f'
         order by p.proname
    """)
    if len(funcs) < MIN_FUNCTIONS:
        print(f'REFUSING TO REPORT SUCCESS: only {len(funcs)} SECURITY DEFINER '
              f'functions found, expected at least {MIN_FUNCTIONS}.', file=sys.stderr)
        return 1

    table_alt = '|'.join(sorted(tenant, key=len, reverse=True))
    problems: "list[str]" = []
    operator_only = 0
    inspected = 0
    statements_checked = 0

    for proname, prosrc, argnames, callable_by_auth in funcs:
        params = [a for a in argnames.split(',') if a.startswith('p_')]
        if not params:
            continue
        inspected += 1

        # An INTERNAL helper that the browser cannot call. Its contract is that
        # its caller scoped the ids — fn__merge_two_families is handed a family
        # id its caller already ran assert_own on, and this script cannot see
        # across a function boundary.
        #
        # The exemption is PAID FOR, not assumed: the check below fails if any
        # fn__ function is callable by `authenticated`. Excusing a function from
        # a guard without asserting what does hold instead is how an exclusion
        # list becomes a hole — and it is exactly how defect 2 in
        # 0070_queue_message_scoping.sql was reachable, since
        # fn__apply_discount_lines carried the fn__ prefix AND a grant to
        # `authenticated` from 0021:286.
        if proname.startswith('fn__') and callable_by_auth != 't':
            continue

        # An OPERATOR-ONLY function. Its first act is to refuse everybody who is
        # not the platform operator, so there is no school user inside it and
        # therefore no cross-tenant boundary for a by-id lookup to cross.
        #
        # fn_platform_void_invoice is the clean example:
        #
        #     if not public.is_platform_admin() then raise ... end if;
        #     select * into v_inv from public.platform_invoices where id = p_invoice_id;
        #
        # There is no school_id to scope that by. platform_invoices is the
        # operator's own books; a school cannot read a row of it through RLS, and
        # asking the operator to supply the school id of an invoice they are
        # looking at would be scoping theatre.
        #
        # THE EXEMPTION IS PAID FOR by being narrower than "mentions
        # is_platform_admin", which would have been satisfied by
        #
        #     if not (public.is_platform_admin() or public.has_role('owner')) then
        #
        # — a function a school owner CAN reach, where every unscoped lookup below
        # is a live cross-tenant read. Two things are required instead:
        #
        #   1. the gate is a bare, unconditional refusal — `if not
        #      public.is_platform_admin() then` immediately followed by `raise`,
        #      with no `or` and no other condition; and
        #   2. NOTHING is read before it. Everything in the body ahead of the gate
        #      is checked for a tenant table, so a lookup hoisted above the guard
        #      — deliberately or by an editor's accident — puts the whole function
        #      back under the full check.
        gate = re.search(
            r'if\s+not\s+public\.is_platform_admin\s*\(\s*\)\s+then\s+raise\b',
            prosrc, re.I)
        if gate and not re.search(
                r'\b(from|join|update|delete\s+from|into)\s+(public\.)?('
                + table_alt + r')\b', prosrc[:gate.start()], re.I):
            operator_only += 1
            continue

        # Which parameters were vouched for, per parameter. Matched on the
        # parameter NAME inside the call, so a check on a DIFFERENT argument
        # gives no credit — fn_rollover called assert_own on two session ids and
        # had eight unscoped queries hiding behind those two correct calls.
        #
        # Three helpers count, because the schema has three ways of saying
        # "prove these ids are mine":
        #   assert_own(table, id)            raises unless id is in this school
        #   fn__assert_my_child(student)     the portal's: own family AND school
        #   fn_may_manage_class(s, c, sec)   all three ids in this school, plus
        #                                    the teacher's own assignment
        VOUCHERS = (r'assert_own', r'assert_my_child', r'fn_may_manage_class')
        vouched = {p for p in params
                   if any(re.search(v + r'\s*\([^)]*\b' + re.escape(p) + r'\b', prosrc)
                          for v in VOUCHERS)}

        # Crude statement split. Good enough because the shape being hunted is a
        # single-statement lookup, and a split that is too eager only makes the
        # check STRICTER (a school_id predicate in a neighbouring clause stops
        # counting), never more permissive.
        for stmt in re.split(r';', prosrc):
            if not re.search(r'\b(from|join|update|delete\s+from|into)\s+(public\.)?(' + table_alt + r')\b',
                             stmt, re.I):
                continue
            statements_checked += 1
            if re.search(r'school_id', stmt, re.I):
                continue          # scoped in this very statement
            for p in params:
                if p in vouched:
                    continue
                # A direct key lookup on a caller-supplied id: `... id = p_x`,
                # `x.id = p_x`, `id in (p_x)`. Not a mere mention — a mention is
                # how the broad version of check-definer-queries.py cried wolf
                # 65 times.
                if re.search(r'\b[a-z_0-9]*\.?id\s*=\s*' + re.escape(p) + r'\b', stmt, re.I):
                    key = f'{proname}({p})'
                    if proname in ALLOWED:
                        continue
                    problems.append(
                        f'{key}  callable_by_authenticated={callable_by_auth}\n'
                        f'      {" ".join(stmt.split())[:200]}')
                    break

    # The assertion that pays for skipping internal helpers above. An fn__
    # function reachable from a browser session is not an internal helper, it is
    # an unguarded entry point — and one of them let a school write a discount
    # line onto another school's invoice.
    leaked_internals = [row[0] for row in q("""
        select p.proname
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname like 'fn\\_\\_%'
           and (has_function_privilege('authenticated', p.oid, 'execute')
             or has_function_privilege('anon', p.oid, 'execute'))
         order by 1
    """)]
    if leaked_internals:
        print('\nINTERNAL fn__ FUNCTION(S) CALLABLE FROM A BROWSER SESSION:',
              file=sys.stderr)
        for name in leaked_internals:
            print(f'  {name}', file=sys.stderr)
        print('\nIn this schema the fn__ prefix means "internal, revoked from '
              'public/anon/authenticated". These are skipped by the per-parameter '
              'check above ON THE ASSUMPTION that only trusted callers reach them, '
              'so a grant here turns that exemption into a hole.\n'
              'fn__apply_discount_lines was exactly this: fn__ prefix, plus a '
              'grant to authenticated from 0021:286, and one school could write a '
              'discount line onto another school\'s invoice. Add\n'
              '  revoke all on function public.<name>(<args>) from public, anon, authenticated;',
              file=sys.stderr)
        return 1

    # Nothing in public may be reachable without a login.
    #
    # 0071 closed this, and then 0073 and 0074 quietly reopened it six times:
    # Postgres grants EXECUTE to PUBLIC on every new function, and the fix
    # 0071 relies on — `alter default privileges revoke execute on functions
    # from public` — only works in its DATABASE-WIDE spelling. The
    # schema-qualified form is silently a no-op, which is how the first version
    # of 0071 left six new functions open to the internet.
    #
    # verify.sql catches it, but verify.sql is something a school runs after an
    # install. This is the check that stops it being committed. Any migration
    # adding a function to a database whose default privileges were set before
    # 0071 must revoke explicitly.
    anon_callable = [row[0] for row in q("""
        select p.proname
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and has_function_privilege('anon', p.oid, 'execute')
         order by 1
    """)]
    if anon_callable:
        print(f'\n{len(anon_callable)} FUNCTION(S) IN public ARE CALLABLE WITHOUT '
              'A LOGIN:', file=sys.stderr)
        for name in anon_callable:
            print(f'  {name}', file=sys.stderr)
        print('\n`anon` is the role a PostgREST request uses when it carries only '
              'the anonymous key, which ships inside the browser bundle and is '
              'therefore public. 0071 closed this surface; a function added since '
              'has reopened it, because Postgres grants EXECUTE to PUBLIC on every '
              'new function.\n'
              'Add to the migration that creates it:\n'
              '  revoke execute on function public.<name>(<arg types>) from public, anon;\n'
              'and grant it to `authenticated` explicitly if the app calls it.',
              file=sys.stderr)
        return 1

    if problems:
        print(f'\n{len(problems)} DEFINER FUNCTION(S) LOOK UP A TENANT ROW BY A '
              'CALLER-SUPPLIED ID WITH NO SCHOOL FILTER:', file=sys.stderr)
        for p in problems:
            print(f'  {p}', file=sys.stderr)
        print('\nSECURITY DEFINER means RLS does not apply, so the function must '
              'scope its own queries. Either add `school_id = current_school_id()` '
              'to the statement, or call public.assert_own(\'<table>\', <that '
              'parameter>) before it. assert_own on a DIFFERENT parameter does not '
              'cover this one.\n'
              'This is the shape that leaked one school\'s family head name, phone '
              'number, child\'s name and outstanding balance to another school '
              'through fn_queue_message. See migrations/0070_queue_message_scoping.sql.',
              file=sys.stderr)
        return 1

    # The operator-only count is printed rather than kept quiet: an exemption
    # nobody can see the size of is an exemption that grows. If this number ever
    # looks large relative to the inspected count, the gate pattern has started
    # matching functions it should not.
    print(f'inspected {inspected} SECURITY DEFINER function(s) with parameters, '
          f'{statements_checked} statement(s) touching one of {len(tenant)} tenant tables')
    print(f'{operator_only} function(s) skipped as operator-only (refuse anyone '
          'but the platform admin before reading anything)')
    print('no definer function looks up a tenant row by a caller-supplied id '
          'without scoping it')
    return 0


if __name__ == '__main__':
    if not os.environ.get('PGDATABASE') and not os.environ.get('PGHOST'):
        print('set PG* env vars first', file=sys.stderr)
    sys.exit(main())
