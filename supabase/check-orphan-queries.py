#!/usr/bin/env python3
"""Every orphan sweep must exclude NULL, or it counts rows that are perfectly fine.

WHAT THIS CATCHES

    select count(*) from public.profiles p
     where not exists (select 1 from public.schools sc where sc.id = p.school_id)

That reads as "profiles whose school is missing". It is not. When `p.school_id`
is NULL, `sc.id = NULL` is never true, so `not exists` is TRUE and the row is
counted as an orphan. A NULL school_id does not mean "the school vanished" — it
means "this row belongs to no school", which for several tables here is the
normal, designed state:

  * a platform operator's `profiles` row has no school. That is what being the
    operator IS.
  * `platform_invoices`, `platform_payments`, `platform_exports` and
    `operator_actions` are deliberately nullable, because 0080 changed them from
    ON DELETE CASCADE to SET NULL so our own sales ledger and audit trail survive
    a customer being purged. Every correctly-retained row has school_id NULL.

So an unguarded sweep reports the operator account and the entire retained ledger
as damage. It has done exactly that twice: `repair/facts.sql` reported "profiles
rows on such an id: 1" on a live project, which was the operator's own account
and led to a written claim that the orphan spanned three tables when it spanned
two; and `repair/inspect-orphans.sql` carried the same shape for three ledger
tables.

THE RULE

Any correlated `not exists (select 1 from public.schools X where X.id =
Y.school_id)` must be preceded, within the same statement, by `school_id is not
null`. Applied uniformly — including on `subscriptions`, whose school_id is the
primary key and cannot be NULL, where the guard is a no-op. A rule with
exceptions needs a list of which columns are nullable, and a hand-maintained list
is what drifted between verify.sql and detect.sql and reported MISSING on a
correct database for two rounds.

TWO THINGS ARE SKIPPED, AND NEITHER IS A HAND-MAINTAINED EXEMPTION LIST

Bundles: generated from migrations, so a finding there duplicates the migration
it was built from.

Migrations already FROZEN into a shipped bundle: those files have been run on
live databases, and editing one rewrites a bundle somebody has already applied —
the hazard build-bundles.sh names in as many words. The frozen set is read from
supabase/bundles/MANIFEST, which is generated, so this skip maintains itself: a
migration in an open bundle is still checked, and the day its bundle is frozen it
stops being editable and stops being checked, together.

That is the whole reason 0090's sweep is not guarded. It reads `subscriptions`,
whose school_id is the primary key and cannot be NULL, so the guard would be a
no-op bought at the price of rewriting a bundle the operator has already run.

Usage: python3 supabase/check-orphan-queries.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "bundles" / "MANIFEST"


def frozen_migrations() -> set:
    """Migration filenames already baked into a frozen bundle."""
    if not MANIFEST.exists():
        return set()
    names = set()
    for line in MANIFEST.read_text().splitlines():
        if "|" not in line:
            continue
        names.update(line.split("|", 1)[1].split())
    return names

# A correlated existence check against schools, keyed on some row's school_id.
# The backreference on the alias is what keeps this to real sweeps: an existence
# check on a parameter (`where id = p_school_id`) has no alias to correlate and
# does not match.
SWEEP = re.compile(
    r"not\s+exists\s*\(\s*select\s+1\s+from\s+public\.schools\s+(\w+)\s+"
    r"where\s+\1\.id\s*=\s*(\w+)\.school_id",
    re.IGNORECASE | re.DOTALL,
)
GUARD = re.compile(r"school_id\s+is\s+not\s+null", re.IGNORECASE)

# How far back to look for the guard. Long enough to span a wrapped WHERE clause,
# short enough not to reach a previous statement's guard and pass on its coat-tails.
WINDOW = 220


def main() -> int:
    bad = []
    checked = 0
    frozen = frozen_migrations()
    for path in sorted(ROOT.rglob("*.sql")):
        if "bundles" in path.parts or path.name in frozen:
            continue
        text = path.read_text()
        # Whitespace-flattened so a clause wrapped over four lines is one string,
        # while offsets stay usable for reporting a line number.
        flat = re.sub(r"\s+", " ", text)
        for m in SWEEP.finditer(flat):
            checked += 1
            if not GUARD.search(flat[max(0, m.start() - WINDOW):m.start()]):
                # Map back to a line number by finding the same text in the file.
                needle = m.group(0).split()[0:6]
                line = 1
                probe = re.search(
                    r"not\s+exists\s*\(\s*select\s+1\s+from\s+public\.schools\s+"
                    + re.escape(m.group(1)),
                    text, re.IGNORECASE | re.DOTALL)
                if probe:
                    line = text.count("\n", 0, probe.start()) + 1
                bad.append((path.relative_to(ROOT.parent), line, m.group(2)))

    if bad:
        print("Orphan sweeps that count NULL school_id as an orphan:\n")
        for path, line, alias in bad:
            print(f"  {path}:{line}")
            print(f"      add `{alias}.school_id is not null and` before the not exists\n")
        print("A NULL school_id means the row belongs to no school — the operator's")
        print("own profile, or a ledger row deliberately unlinked when a customer was")
        print("purged. Counting those as damage reports healthy rows as broken.")
        return 1

    print(f"supabase: all {checked} orphan sweeps exclude NULL school_id")
    return 0


if __name__ == "__main__":
    sys.exit(main())
