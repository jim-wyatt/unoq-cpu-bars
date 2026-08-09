#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Do the mermaid diagrams actually draw?
#
#   tools/check-diagrams.sh
#
# WHY THIS EXISTS
# ---------------
# Because they did not, and nothing noticed. Twelve diagrams were added to the
# course, the build was clean, `--strict` was happy, the markup was right, the
# library was vendored and served with a 200 - and every one of them came out as
# a block of grey text, on every page, for hours.
#
# Nothing in a static-site build can catch that. The failure is in the browser,
# after the page loads, and the page is perfectly valid either way. The only
# honest test is to open it in a browser and look, so that is what this does:
# serves the built site, loads each page that contains a diagram in headless
# Chromium, and counts how many `pre.mermaid` blocks mermaid actually marked as
# `data-processed`.
#
# It is slow (a second or two per page) and it needs a browser. That is the
# price of testing the one thing that cannot be tested any other way.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="${UNOQ_SITE:-$PROJECT/share/learn}"
PORT="${UNOQ_DIAGRAM_PORT:-8099}"
# What actually costs the time here is chromium STARTUP - about 5.5s per launch
# on this board, eleven launches, so ~60s regardless of this number. Lowering it
# from 25000 changed nothing measurable, and running the pages four at a time
# was WORSE (77s): four chromium instances on a four-core 3.6 GB board contend
# more than they gain.
#
# Making it genuinely fast means driving one browser over the DevTools protocol
# instead of launching one per page, which is a dependency this gate does not
# currently justify. It is excluded from --fast for that reason.
BUDGET_MS="${UNOQ_DIAGRAM_BUDGET_MS:-8000}"

# GitHub's ubuntu runners ship google-chrome; this board has chromium. Try the
# usual names rather than assuming either.
BROWSER=""
for candidate in chromium chromium-browser google-chrome google-chrome-stable; do
  if command -v "$candidate" >/dev/null 2>&1; then
    BROWSER="$candidate"
    break
  fi
done
if [ -z "$BROWSER" ]; then
  echo "no chromium/chrome on PATH - cannot check whether the diagrams render" >&2
  echo "  install one, or skip this gate with: tools/check.sh python shell c" >&2
  exit 1
fi

if [ ! -d "$SITE" ]; then
  echo "$SITE does not exist - run tools/build-docs.sh first" >&2
  exit 1
fi

# Serve over HTTP rather than pointing the browser at file://. The site is
# meant to work both ways, but a local server is what the board and Pages both
# do, and file:// adds its own failure modes that would muddy this test.
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SITE" >/dev/null 2>&1 &
SERVER=$!
cleanup() { kill "$SERVER" 2>/dev/null; }
trap cleanup EXIT

# Give it a moment to bind, and confirm rather than sleeping and hoping.
for _ in $(seq 1 20); do
  curl -sSf -o /dev/null "http://127.0.0.1:$PORT/index.html" 2>/dev/null && break
  sleep 0.25
done

PROFILE="$(mktemp -d)"
trap 'cleanup; rm -rf "$PROFILE"' EXIT

fail=0
checked=0
total=0

while IFS= read -r page; do
  want="$(grep -c 'class="mermaid"' "$SITE/$page")"
  [ "$want" = 0 ] && continue
  checked=$((checked + 1))
  got="$("$BROWSER" --headless --no-sandbox --disable-gpu \
    --user-data-dir="$PROFILE" \
    --virtual-time-budget="$BUDGET_MS" \
    --dump-dom "http://127.0.0.1:$PORT/$page" 2>/dev/null |
    grep -c 'data-processed="true"')"
  total=$((total + got))
  if [ "$got" != "$want" ]; then
    printf '  FAIL  %-46s %s of %s diagrams drew\n' "$page" "$got" "$want"
    fail=1
  fi
done < <(cd "$SITE" && find . -name '*.html' -printf '%P\n' | sort)

if [ "$fail" != 0 ]; then
  cat >&2 <<EOF

Diagrams did not render. Things worth checking, in the order they have bitten:

  1. extra_javascript in mkdocs.yml still lists assets/javascripts/mermaid-init.js.
     Without it the library loads and nothing ever calls mermaid.run().
  2. site_url is still unset. With it, the privacy plugin rewrites the vendored
     library to an ABSOLUTE url, which is a network fetch on the USB drive.
  3. The library still publishes a global on its last line. Open
     share/learn/assets/external/.../mermaid.min.js and look for
     globalThis["mermaid"] - if that has gone, mermaid-init.js needs rewriting
     as a module.
EOF
  exit 1
fi

printf '%s diagrams drew across %s pages\n' "$total" "$checked"
