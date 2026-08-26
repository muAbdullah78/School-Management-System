#!/usr/bin/env bash
# =============================================================================
# The website's buttons must lead somewhere.
#
# WHY THIS EXISTS
#
# Every call to action on site/index.html used to be `href="#pricing"` or
# `href="#trial"` — anchors on the page the visitor was already reading. "Start
# free trial" scrolled them down. There was no way to sign in. There was no
# download, because the Windows installer only existed as a CI artifact behind a
# GitHub login.
#
# That is not a bug a browser reports and not one a unit test notices: the page
# renders perfectly and every link works. It is only wrong if you know where the
# buttons were supposed to go.
#
# So this asserts the wiring exists:
#
#   * every route wire.js knows about is used by at least one button, and every
#     data-app value in the HTML is a route wire.js knows — a typo'd
#     data-app="signn" silently falls back to "/" and lands on the app's home
#     page, which for a signed-out visitor is a login screen that looks right and
#     is not what the button said;
#   * the download section exists with the ids wire.js writes into;
#   * config.js has every key wire.js reads, so a new setting cannot be read
#     before it is documented;
#   * NOTHING in site/ contains a Supabase KEY, matched on the shape of a JWT
#     rather than on the word "service_role" — the first version of that check
#     failed on config.js's own comment saying never to put one there.
#
# Usage:  bash supabase/check-site-links.sh      (no database needed)
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

HTML=site/index.html
WIRE=site/wire.js
CONF=site/config.js
fail=0

for f in "$HTML" "$WIRE" "$CONF"; do
  [ -f "$f" ] || { echo "  missing: $f"; fail=1; }
done
[ "$fail" = 1 ] && { echo "::error::the website is missing files it needs"; exit 1; }

# --- 1. data-app values on both sides must agree -----------------------------
# ROUTES in wire.js is the authority. Extracted rather than duplicated here: a
# third copy of the list would be a third thing to keep in step.
routes=$(sed -n 's/.*var ROUTES = {\(.*\)}.*/\1/p' "$WIRE" \
         | tr ',' '\n' | sed -E 's/^[[:space:]]*([a-z]+):.*/\1/' | sed '/^$/d' | sort -u)
used=$(grep -o 'data-app="[a-z]*"' "$HTML" | sed 's/data-app="//; s/"//' | sort -u)

if [ -z "$routes" ]; then
  echo "REFUSING TO REPORT SUCCESS: could not read ROUTES out of $WIRE" >&2
  exit 1
fi
if [ -z "$used" ]; then
  echo "  no button on the site points into the app at all (no data-app attributes)"
  fail=1
fi

# A data-app the router does not know falls back to "/" — a link that looks
# right and goes to the wrong place, which is worse than one that is obviously
# broken.
for u in $used; do
  echo "$routes" | grep -qx "$u" \
    || { echo "  site/index.html has data-app=\"$u\" and wire.js has no route for it"; fail=1; }
done

# The four the design promised. A route defined and never used is dead code on a
# marketing page, which is where dead code is least likely to be noticed.
for r in signin signup billing portal; do
  echo "$used" | grep -qx "$r" \
    || { echo "  nothing on the site links to \"$r\" — that path is still unreachable"; fail=1; }
done

# --- 2. the download section, and the ids wire.js writes into ---------------
for id in download-box download-btn download-meta download-sha download-notes; do
  grep -q "id=\"$id\"" "$HTML" \
    || { echo "  $HTML has no element with id=\"$id\", which wire.js writes the release into"; fail=1; }
done
grep -q 'id="download"' "$HTML" \
  || { echo "  there is no #download section for the nav to link to"; fail=1; }

# --- 3. every setting wire.js reads is in config.js -------------------------
keys=$(grep -oE 'C\.[A-Z_]+' "$WIRE" | sed 's/^C\.//' | sort -u)
for k in $keys; do
  grep -q "$k" "$CONF" \
    || { echo "  wire.js reads $k and config.js does not document it"; fail=1; }
done

# --- 4. no KEY has been pasted into a static file --------------------------
# Matched on the SHAPE OF A VALUE, not on the word "service_role".
#
# The first version grepped for that word and failed on config.js's own comment
# telling you never to put it there — the guard reporting its own documentation
# as a breach, which is the same mistake check-readonly-writes.py made about a
# comment explaining why a function used has_role.
#
# A Supabase key is a JWT: three dot-separated base64url segments starting
# `eyJ`. Looking for that catches BOTH keys, which is what is wanted — the anon
# key is safe to publish but does not belong in the repository either, because a
# committed project URL and key is a thing you cannot take back and the
# deployment is where they belong.
if grep -rlE 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' site/ >/dev/null 2>&1; then
  echo "  a file in site/ contains what looks like a Supabase key (a JWT)."
  echo "  Keys belong on the deployment, not in the repository. And if it is the"
  echo "  service_role key: that one bypasses every row-level rule in the database"
  echo "  and must never reach a file a browser can download."
  grep -rlE 'eyJ[A-Za-z0-9_-]{10,}\.' site/ | sed 's/^/    /'
  fail=1
fi
# A filled-in config is fine locally and must not be committed: it is how a real
# project URL and a real phone number end up in a public git history.
if grep -qE "^\s*(SUPABASE_URL|SUPABASE_ANON_KEY|APP_URL):\s*'[^']+'" "$CONF"; then
  echo "  site/config.js has values filled in. Deploy-time settings belong on the"
  echo "  deployment, not in the repository — leave the defaults empty here."
  fail=1
fi

if [ "$fail" = 1 ]; then
  echo
  echo "::error::the website's links are not wired to the software"
  exit 1
fi

echo "site/ links into the app for: $(echo "$used" | tr '\n' ' ')— download section present, config documented, no secrets"
