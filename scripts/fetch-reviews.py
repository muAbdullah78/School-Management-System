#!/usr/bin/env python3
"""Pull the published reviews out of the database into the site's source.

WHY THE SITE DOES NOT JUST FETCH THEM AT PAGE LOAD

It does, for a human: wire.js reads them live so a visitor always sees the
current list. But the STRUCTURED DATA has to be in the HTML that Google fetches.
Google does execute JavaScript, and it does pick up JSON-LD injected by a
script, but it is slower, it is not guaranteed, and an aggregate rating that
depends on a runtime fetch is an aggregate rating that silently disappears the
day the fetch fails. So the ratings are baked in at build time and the page
hydrates on top of them.

It also means the number in the markup cannot be inflated by a bug in the
browser code: it is whatever this script read out of reviews_summary, which is
a view over published reviews only.

    export PGHOST=... PGPORT=... PGUSER=... PGDATABASE=... PGPASSWORD=...
    python3 scripts/fetch-reviews.py       # writes site-src/data/reviews.json
    python3 scripts/build-site.py          # bakes it into /reviews
    python3 scripts/check-site-seo.py

READS ONLY THE PUBLIC VIEWS. reviews_public and reviews_summary carry no author
name, no user id and no moderation note, so this cannot copy something private
into a file that gets uploaded to a web server even by accident.

It writes the file even when there are no reviews, with total 0. The builder
then renders an honest empty page and emits NO aggregateRating, because a rating
of 0 from 0 reviews is not a rating and marking it up as one would be a lie
about your customers.
"""
import json
import subprocess
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'site-src' / 'data' / 'reviews.json'

SUMMARY_SQL = """
select coalesce(json_agg(row_to_json(s)), '[]'::json)
  from (select total, average, five, four, three, two, one
          from public.reviews_summary) s
"""

LIST_SQL = """
select coalesce(json_agg(row_to_json(r) order by r.published_on desc), '[]'::json)
  from (select id, rating, title, body, school_name, city, display_mode,
               published_on
          from public.reviews_public) r
"""


def q(sql: str):
    r = subprocess.run(
        ['psql', '-tA', '-v', 'ON_ERROR_STOP=1', '-c', sql],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print('could not read the database. Are the PG* variables set?', file=sys.stderr)
        print(r.stderr.strip(), file=sys.stderr)
        sys.exit(1)
    return json.loads(r.stdout.strip() or '[]')


def main() -> int:
    summary_rows = q(SUMMARY_SQL)
    reviews = q(LIST_SQL)
    summary = summary_rows[0] if summary_rows else {
        'total': 0, 'average': None, 'five': 0, 'four': 0, 'three': 0, 'two': 0, 'one': 0,
    }

    # The two must agree. reviews_summary is a view over reviews_public, so a
    # mismatch means one of them was read at a different moment, and a page
    # claiming "12 reviews" above a list of 11 is worse than either number.
    if int(summary.get('total') or 0) != len(reviews):
        print(f'REFUSING: the summary says {summary.get("total")} reviews and the list '
              f'has {len(reviews)}. Re-run; something was published between the two '
              f'queries.', file=sys.stderr)
        return 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({
        'fetched_on': date.today().isoformat(),
        'summary': summary,
        'reviews': reviews,
    }, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

    n = len(reviews)
    avg = summary.get('average')
    print(f'wrote {OUT.relative_to(ROOT)}: {n} published review(s)'
          + (f', average {avg}' if n else ', so /reviews will say so and claim no rating'))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
