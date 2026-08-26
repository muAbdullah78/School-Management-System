#!/usr/bin/env python3
# =============================================================================
# NOTHING MAY DECIDE AUTHORISATION FROM raw_user_meta_data.
#
# WHY THIS EXISTS
#
# handle_new_user() read a new login's SCHOOL and ROLE from
# new.raw_user_meta_data. That field is whatever the browser sends to
# auth.signUp({options:{data:{...}}}) using the PUBLIC anon key. 'principal' and
# 'accountant' were both on its accepted-role list, and an accepted role was
# created ACTIVE.
#
# Two strangers signed up naming a victim school and became an active accountant
# and an active principal in it. Every signed-in user already knows their own
# school_id, so any parent could make themselves principal of their own school.
#
# The fix moved authorisation onto raw_app_meta_data, which only the service role
# can write, and onto public.user_invites, which an owner or principal creates.
#
# This guard exists because that fix is one line away from being undone, and the
# undoing would look harmless in review: `raw_user_meta_data->>'role'` reads
# exactly like `raw_app_meta_data->>'role'`.
#
# WHAT IS ALLOWED
#
# raw_user_meta_data may still be read for DISPLAY values — full_name is the
# only one today. A forged display name is a cosmetic nuisance. A forged role is
# a tenant breach. The allow-list below is keys, not functions, so a new
# function reading full_name passes and a new function reading 'role' fails.
#
# Usage:  python3 supabase/check-metadata-trust.py
#         (needs PG* env vars pointing at a database with the migrations applied)
# =============================================================================
import os
import re
import subprocess
import sys

# Keys that may be read from the UNTRUSTED field. Display only.
DISPLAY_ONLY = {"full_name"}

# Anything matching this in a function body is a read of the untrusted field.
READ = re.compile(r"raw_user_meta_data\s*(?:->>|->)\s*'([a-z_]+)'", re.I)

SQL = (
    "select p.proname, pg_get_functiondef(p.oid) "
    "from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
    "where n.nspname = 'public' "
    # prokind='f' excludes aggregates and window functions. pg_get_functiondef
    # RAISES on an aggregate ("array_agg is an aggregate function"), which made
    # the first version of this guard exit 1 with a connection-looking error —
    # a guard that cannot run is a guard that protects nothing.
    "  and p.prokind = 'f' "
    "  and p.prosrc ilike '%raw_user_meta_data%' "
    "order by 1;"
)


def main() -> int:
    run = subprocess.run(
        ["psql", "-tA", "-R", "\x02", "-F", "\x01", "-v", "ON_ERROR_STOP=1", "-c", SQL],
        capture_output=True, text=True, env=dict(os.environ))
    if run.returncode != 0:
        sys.stderr.write(run.stderr)
        print("could not query the database — are PG* env vars set?")
        return 1

    records = [r for r in run.stdout.split("\x02") if "\x01" in r]

    bad = []
    seen_display = 0
    for rec in records:
        name, body = rec.split("\x01", 1)
        name = name.strip()
        for m in READ.finditer(body):
            key = m.group(1).lower()
            if key in DISPLAY_ONLY:
                seen_display += 1
                continue
            bad.append((name, key))

    # handle_new_user MUST read the trusted field. If it stops doing so, either
    # the whole mechanism was replaced (say so deliberately) or somebody deleted
    # the fix — and a guard that only checks for the bad pattern would call an
    # empty function healthy.
    trusted = subprocess.run(
        ["psql", "-tA", "-v", "ON_ERROR_STOP=1", "-c",
         "select coalesce((select prosrc from pg_proc p "
         "  join pg_namespace n on n.oid = p.pronamespace "
         " where n.nspname='public' and p.proname='handle_new_user'), '')"],
        capture_output=True, text=True, env=dict(os.environ)).stdout

    problems = 0
    if bad:
        problems = 1
        print("AUTHORISATION READ FROM CLIENT-CONTROLLED METADATA:\n")
        for name, key in sorted(set(bad)):
            print(f"  {name} reads raw_user_meta_data->>'{key}'")
        print("""
raw_user_meta_data is written by the browser at auth.signUp. A value read from
it is a claim by the person signing up, not a fact.

Use raw_app_meta_data (service role only) or public.user_invites instead. If the
key really is a harmless display value, add it to DISPLAY_ONLY in this script
with the reason.""")

    if "raw_app_meta_data" not in trusted:
        problems = 1
        print("\nhandle_new_user DOES NOT READ raw_app_meta_data.\n"
              "That is the trusted channel the Edge Functions provision through.\n"
              "Either the function was gutted, or the mechanism changed without\n"
              "this guard being updated. Both need a human.")

    if "user_invites" not in trusted:
        problems = 1
        print("\nhandle_new_user DOES NOT CONSULT public.user_invites.\n"
              "That is the path a school adds a teacher through when the\n"
              "create-teacher Edge Function is not deployed. Without it, the\n"
              "only way to add staff is an Edge Function deployment.")

    if problems:
        return 1

    print(f"checked {len(records)} function(s) touching user metadata")
    print(f"  {seen_display} display-only read(s) of raw_user_meta_data, all allow-listed")
    print("no authorisation is decided from client-controlled metadata")
    return 0


if __name__ == "__main__":
    sys.exit(main())
