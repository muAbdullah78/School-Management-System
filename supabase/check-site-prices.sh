#!/usr/bin/env bash
# =============================================================================
# The website's prices must match what the console actually charges.
#
# WHY THIS EXISTS
#
# The site carries the prices as literal text — Rs 950, Rs 9,500 a year,
# "up to 100 students" — and `plans` carries them as data. 0082 made the site read
# `plans` at page load, so the live page is correct. But the literals are the
# FALLBACK, shown when Supabase is unreachable or before the fetch lands, and a
# fallback that is out of date is worse than no fallback: the visitor reads a
# price nobody will honour, and the first thing they say on the phone is "your
# website says Rs 950".
#
# So this asserts the two agree. A price rise then fails CI until the HTML is
# updated too, which is exactly the reminder that would otherwise be forgotten
# for a year.
#
# It also checks the student limits, because "up to 100 students" is a price: a
# school reading 300 and being told 100 has been quoted the wrong plan.
#
# Usage:  bash supabase/check-site-prices.sh
#         (needs PG* env vars pointing at a database with the migrations applied)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

# THE SITE IS NO LONGER ONE PAGE, and this check assumed it was.
#
# The plan cards moved to site/pricing.html when the site was split up for
# search. The hero's "From Rs 950" stayed on the home page. The JSON-LD offers
# are emitted by scripts/build-site.py into every page that asks for the
# software schema, which is currently seven of them.
#
# Pointed at site/index.html alone this check would have found no cards at all
# and hit its own "matched fewer than 3 plans" floor, which is the right
# failure but the wrong reason. Each figure is now checked where it actually
# lives, and PAGES lists everything that may carry a price so a stale figure
# cannot hide on a page nobody thought to look at.
CARDS=site/pricing.html
HERO=site/index.html
PAGES=$(ls site/*.html site/guides/*.html 2>/dev/null | grep -v '^site/guide\.html$')
fail=0
checked=0

for f in "$CARDS" "$HERO"; do
  if [ ! -f "$f" ]; then
    echo "REFUSING TO REPORT SUCCESS: $f does not exist. Run python3 scripts/build-site.py"
    exit 1
  fi
done

# Every active, priced plan from the database. `custom` has no price and its card
# says "Let's talk", so it is skipped by the price filter rather than by name —
# a future free tier would be skipped for the same real reason.
rows=$(psql -tA -F'|' -v ON_ERROR_STOP=1 -c \
  "select code, student_limit, price_monthly::bigint, price_yearly::bigint
     from public.plans
    where active and price_monthly > 0
    order by sort_order") || {
  echo "could not read plans — are PG* env vars set?" >&2
  exit 1
}

if [ -z "$rows" ]; then
  echo "REFUSING TO REPORT SUCCESS: no priced plans in the database" >&2
  exit 1
fi

# The block of HTML for one plan, from its data-plan attribute to the closing
# </div>. Extracted per plan so a figure in the WRONG card is caught: the
# failure a whole-file grep would miss, and the one that quotes Growth's price
# for Starter's limit.
#
# THIS DID NOT WORK, AND IT IS WORTH SAYING WHY IN FULL.
#
# The closing condition used to be:
#
#     inside && /<\/div>[[:space:]]*$/ && /btn/ { inside = 0 }
#
# which requires ONE line to both end in </div> and contain "btn". No line in
# the markup ever did: the button and the closing tag are on separate lines, as
# any formatter would leave them. So `inside` was never cleared, every card
# extraction ran to end of file, and each plan's "card" contained every other
# plan's prices. Measured before rewriting: the starter extraction returned 240
# lines and matched Growth's "Rs 2,000".
#
# So the check passed, and it passed for a reason that had nothing to do with
# what it claimed. The whole-card assertion it advertises was a whole-file grep
# wearing a per-card costume, and the one failure the comment above promises to
# catch was the exact failure it could not see.
#
# Two changes, and the second is the one that matters:
#
#   1. Close on an EXPLICIT marker, <!-- /plan -->, rather than on a guessed
#      combination of tag and class. Markup gets reformatted; a marker does not
#      move on its own.
#   2. REFUSE if the marker is missing, rather than falling back to end of file.
#      A checker that degrades quietly into a weaker check when its assumption
#      breaks is worse than one that stops, because the weaker check still
#      prints success. That is precisely how this one hid for so long.
card() {
  awk -v want="$1" '
    $0 ~ ("data-plan=\"" want "\"") { inside = 1 }
    inside { print }
    inside && /<!-- \/plan -->/ { exit }
  ' "$CARDS"
}

# True when the plan block is properly terminated. Kept separate from card() so
# the refusal below is explicit rather than inferred from a line count.
card_is_closed() {
  awk -v want="$1" '
    $0 ~ ("data-plan=\"" want "\"") { inside = 1 }
    inside && /<!-- \/plan -->/ { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$CARDS"
}

commas() {   # 9500 -> 9,500  (the grouping the page prints)
  # NOT printf "%'d": that only groups when the locale says to, and CI runs in
  # the C locale where it prints 9500 — so the first version of this check
  # reported six false failures. sed does it the same way everywhere.
  echo "$1" | sed -E ':a; s/([0-9])([0-9]{3})($|,)/\1,\2\3/; ta'
}

while IFS='|' read -r code limit monthly yearly; do
  [ -z "${code:-}" ] && continue
  block=$(card "$code")
  if [ -z "$block" ]; then
    echo "  $code: $CARDS has no card for this plan (data-plan=\"$code\")"
    fail=1
    continue
  fi
  # Unterminated means the block below is every remaining line of the file, so
  # every assertion against it would pass on any other plan's figures. Refuse
  # rather than check something weaker than advertised.
  if ! card_is_closed "$code"; then
    echo "REFUSING TO REPORT SUCCESS: the $code card in $CARDS has no <!-- /plan --> marker," >&2
    echo "so its block runs to end of file and would match any plan's price." >&2
    exit 1
  fi
  checked=$((checked + 1))

  m=$(commas "$monthly")
  y=$(commas "$yearly")
  l=$(commas "$limit")

  printf '%s' "$block" | grep -qF "Rs $m" \
    || { echo "  $code: monthly price is Rs $monthly in the database; \"Rs $m\" is not in its card"; fail=1; }
  printf '%s' "$block" | grep -qF "Rs $y" \
    || { echo "  $code: yearly price is Rs $yearly in the database; \"Rs $y\" is not in its card"; fail=1; }
  if [ -n "${limit:-}" ]; then
    printf '%s' "$block" | grep -qF "$l students" \
      || { echo "  $code: limit is $limit students in the database; \"$l students\" is not in its card"; fail=1; }
  fi
done <<< "$rows"

# The hero also quotes the cheapest monthly price. It is a separate literal and
# it drifted in exactly the way this whole check exists to stop.
# By PRICE, not by sort_order. This ordered by sort_order and took the first
# row, which is the same defect wire.js had: with growth ahead of starter, the
# guard would have demanded the hero quote Rs 2,000 as its "From" figure while
# a Rs 950 plan sat in the table below it. "From" is a claim about the minimum.
cheapest=$(psql -tA -v ON_ERROR_STOP=1 -c \
  "select price_monthly::bigint from public.plans
    where active and price_monthly > 0 order by price_monthly limit 1")
grep -qF "Rs $(commas "$cheapest")" <(grep 'id="lead-price"' "$HERO") \
  || { echo "  the headline price in the hero of $HERO is not Rs $cheapest"; fail=1; }

# --- the copies of the price that live OUTSIDE the cards -------------------
#
# The cards and the hero were guarded; four other places quoting the same figure
# were not, and a stale price in any of them is a price you will be held to.
# Measured with plans stubbed to 1400/2900/4900: the cards and the hero all
# updated correctly while the meta description, the Open Graph description and
# the JSON-LD offers still read 950, and the JSON-LD is the copy Google puts in
# a rich result.
cheap=$(commas "$cheapest")

# Two pages quote the price in their own meta description and Open Graph
# description: the home page and the pricing page. Checked by page rather than
# demanding every page quote a price, because most of them should not.
for f in "$HERO" "$CARDS"; do
  for label in 'meta name="description"' 'meta property="og:description"'; do
    line=$(grep "$label" "$f" || true)
    if [ -z "$line" ]; then
      echo "  $f has no <$label>, which the price check expects to find"
      fail=1
    elif ! printf '%s' "$line" | grep -qF "Rs $cheap"; then
      echo "  <$label> in $f does not quote the cheapest price, Rs $cheapest"
      fail=1
    fi
  done
done

# And no OTHER page may quote a price that is not the current cheapest. A stale
# "Rs 800" in the middle of a guide is a price you will be held to just as much
# as one in a card.
for f in $PAGES; do
  while read -r stale; do
    [ -z "$stale" ] && continue
    case "$stale" in
      "Rs $cheap"|"Rs $(commas "$(psql -tA -c "select price_monthly::bigint from public.plans where active and price_monthly>0 order by price_monthly desc limit 1")")") continue ;;
    esac
    known=0
    while IFS='|' read -r c l m y; do
      [ -z "${c:-}" ] && continue
      [ "$stale" = "Rs $(commas "$m")" ] && known=1
      [ "$stale" = "Rs $(commas "$y")" ] && known=1
    done <<< "$rows"
    if [ "$known" = 0 ]; then
      echo "  $f quotes \"$stale\" a month, which is not any active plan's price"
      fail=1
    fi
  done <<< "$(grep -oE 'Rs [0-9][0-9,]*(\.[0-9]+)? a month' "$f" | sed -E 's/ a month$//' | sort -u)"
done

# The JSON-LD offers, which are structured data and get scraped verbatim.
# The JSON-LD offers, which are structured data and get scraped verbatim.
# scripts/build-site.py emits them from one PLANS list into every page that
# declares the software schema, so any such page is a valid place to check and
# every one of them must agree.
ld_pages=$(grep -l '"@type": "SoftwareApplication"' $PAGES || true)
if [ -z "$ld_pages" ]; then
  echo "REFUSING TO REPORT SUCCESS: no page carries the SoftwareApplication schema," >&2
  echo "so the offer prices Google reads are not being checked at all." >&2
  exit 1
fi
for f in $ld_pages; do
  while IFS='|' read -r code limit monthly yearly; do
    [ -z "${code:-}" ] && continue
    grep -qE "\"price\": ?\"$monthly\"" "$f" \
      || { echo "  $f: JSON-LD has no offer priced \"$monthly\" for $code"; fail=1; }
    if [ -n "${limit:-}" ]; then
      grep -qF "Up to $(commas "$limit") students" "$f" \
        || { echo "  $f: JSON-LD has no \"Up to $(commas "$limit") students\" for $code"; fail=1; }
    fi
  done <<< "$rows"
done

# The AUTH SCREENS quote it too, and they are in the app rather than the site.
AUTH=web/src/components/AuthLayout.tsx
if [ -f "$AUTH" ]; then
  grep -qF "Rs $cheap" "$AUTH" \
    || { echo "  $AUTH quotes a price that is not Rs $cheapest (the signup panel)"; fail=1; }
fi

# The floor. A card-matching function that silently matched nothing would report
# a clean run over an empty check — the failure mode two of this project's other
# guards have already had.
if [ "$checked" -lt 3 ]; then
  echo "REFUSING TO REPORT SUCCESS: only matched $checked plan card(s) in $HTML; expected at least 3." >&2
  exit 1
fi

if [ "$fail" = 1 ]; then
  echo
  echo "::error::the site quotes prices the console does not charge"
  echo "The page reads \`plans\` at load, so the LIVE site is right — but these"
  echo "literals are what a visitor sees when Supabase is slow or unreachable,"
  echo "and a stale fallback is a price you will be held to. Update them."
  exit 1
fi

echo "the site and public.plans agree on $checked plan(s), the hero figure, the meta and Open Graph descriptions on both money pages, the JSON-LD offers on $(printf '%s\n' $ld_pages | wc -l | tr -d ' ') page(s), the signup panel, and no page quotes a price that is not a real one"
