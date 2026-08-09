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
# Wall-clock ceiling per page, so a browser that never exits cannot hang a job.
PAGE_TIMEOUT="${UNOQ_DIAGRAM_PAGE_TIMEOUT:-45}"

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
  echo "  install one, or skip this gate with: tools/check.sh python shell c docs" >&2
  exit 1
fi

# Build first rather than trusting whatever is on disk. share/learn is generated
# and gitignored, so switching branches leaves the previous branch's site there -
# and this gate then reports eleven confident failures about markup that is
# perfectly fine on the branch you are actually on. Costs ~8s; worth it to make
# the script mean the same thing standalone as it does inside check.sh.
if [ -z "${UNOQ_SITE:-}" ]; then
  "$PROJECT/tools/build-docs.sh" >/dev/null || {
    echo "tools/build-docs.sh failed - fix that before checking the diagrams" >&2
    exit 1
  }
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

WORK="$(mktemp -d)"
trap 'cleanup; rm -rf "$WORK"' EXIT

# render <url> - print the number of diagrams the browser marked as drawn, or
# the word "broken" if the browser itself failed. Those two are DIFFERENT
# ANSWERS and conflating them cost a whole debugging session: `grep -c` prints
# "0" for empty input, so a browser that produced nothing at all was reported as
# "0 of 1 diagrams drew" - which reads as "your markup is wrong" when it means
# "the browser never ran".
render() {
  local url="$1" dom rc
  # A FRESH PROFILE PER LAUNCH. Chrome puts a SingletonLock in the profile
  # directory, and a previous instance that has not finished tearing down makes
  # the next one wait on it. Sharing one directory across eleven sequential
  # launches worked on this board and produced a 45s-then-1s alternating pattern
  # on the runner - half the pages timing out, the rest returning empty.
  local profile="$WORK/profile.$$.$RANDOM"
  # HARD TIMEOUT, non-negotiable. On a GitHub runner an earlier version of this
  # hung on the first page and took the whole job to its fifteen-minute limit
  # with chrome still alive. A gate that can hang is worse than no gate: it
  # turns an unrelated pull request into a fifteen-minute wait and a red tick.
  #
  # Plain --headless, NOT --headless=old: old headless was removed from Chrome
  # in 132, so on any current runner that flag is at best ignored. The board's
  # Chromium 151 draws diagrams identically under both, which is exactly why
  # the difference stayed invisible here.
  #
  # --disable-dev-shm-usage because CI containers give /dev/shm 64 MB, where
  # chrome deadlocks rather than failing.
  dom="$(timeout "$PAGE_TIMEOUT" "$BROWSER" \
    --headless --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --no-first-run --disable-extensions --disable-background-networking \
    --user-data-dir="$profile" \
    --virtual-time-budget="$BUDGET_MS" \
    --dump-dom "$url" 2>/dev/null)"
  rc=$?
  rm -rf "$profile"
  # Empty output means the browser died or timed out. A real page always comes
  # back with at least an <html> element, diagrams or not.
  if [ "$rc" != 0 ] || [ -z "$dom" ]; then
    echo broken
    return
  fi
  grep -c 'data-processed="true"' <<<"$dom"
}

# SELF-TEST FIRST, against a fixture this script writes itself.
#
# Without this, every failure looks like "the diagrams are broken" - and the
# last two were not. One was a profile lock, one was a headless-mode flag. Both
# reported eleven confident failures about markup that was perfectly correct,
# which is the most expensive kind of wrong a gate can be.
#
# The fixture uses the SAME vendored library and the SAME init script as the
# real pages, so if it draws, the browser and the library both work and a zero
# on a real page is genuinely that page's fault.
lib="$(cd "$SITE" && find assets/external -name 'mermaid*.js' 2>/dev/null | head -1)"
if [ -z "$lib" ]; then
  echo "no vendored mermaid in $SITE - run tools/check-diagram-assets.sh for why" >&2
  exit 1
fi
cat >"$SITE/_selftest.html" <<EOF
<!doctype html><html><body>
<pre class="mermaid">graph LR
  A[in] --> B[out]</pre>
<script src="$lib"></script>
<script src="assets/javascripts/mermaid-init.js"></script>
</body></html>
EOF
trap 'cleanup; rm -rf "$WORK"; rm -f "$SITE/_selftest.html"' EXIT

self="$(render "http://127.0.0.1:$PORT/_selftest.html")"
if [ "$self" != 1 ]; then
  # Run it ONCE more with stderr kept. Everywhere else stderr is discarded,
  # because a working chromium is noisy (dbus, UPower, GPU probing) and it would
  # bury the per-page results. Here it is the only thing that can say WHY, and
  # the alternative is another guess and another CI round - which is how this
  # gate has already burned an afternoon.
  echo "--- what the browser said, verbatim ---" >&2
  timeout "$PAGE_TIMEOUT" "$BROWSER" \
    --headless --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --no-first-run --disable-extensions --disable-background-networking \
    --user-data-dir="$WORK/diag" \
    --virtual-time-budget="$BUDGET_MS" \
    --dump-dom "http://127.0.0.1:$PORT/_selftest.html" 2>&1 >/dev/null |
    head -20 >&2
  diag_rc="${PIPESTATUS[0]}"
  echo "--- exit status: $diag_rc  (124 = killed by the ${PAGE_TIMEOUT}s timeout) ---" >&2
  # And prove the server is serving, so a fixture that 404s is never mistaken
  # for a browser that cannot render.
  printf 'fixture over HTTP: %s\nlibrary over HTTP: %s\n\n' \
    "$(curl -sS -o /dev/null -w '%{http_code}, %{size_download} bytes' \
      "http://127.0.0.1:$PORT/_selftest.html" 2>&1)" \
    "$(curl -sS -o /dev/null -w '%{http_code}, %{size_download} bytes' \
      "http://127.0.0.1:$PORT/$lib" 2>&1)" >&2
  cat >&2 <<EOF
THE HARNESS IS BROKEN, not the site.

A one-diagram fixture, using this build's own vendored library and init script,
came back as "$self" instead of 1. That is the browser, this script, or the
library - not the documentation. Nothing below would have been trustworthy, so
no pages were checked.

  browser:  $BROWSER ($("$BROWSER" --version 2>/dev/null || echo 'version unknown'))
  library:  $lib

Reproduce it by hand:
  python3 -m http.server $PORT --directory $SITE &
  $BROWSER --headless --no-sandbox --dump-dom http://127.0.0.1:$PORT/_selftest.html
EOF
  exit 1
fi

fail=0
checked=0
total=0

while IFS= read -r page; do
  want="$(grep -c 'class="mermaid"' "$SITE/$page")"
  [ "$want" = 0 ] && continue
  checked=$((checked + 1))
  got="$(render "http://127.0.0.1:$PORT/$page")"
  if [ "$got" = broken ]; then
    printf '  FAIL  %-46s the browser produced nothing (timed out after %ss?)\n' \
      "$page" "$PAGE_TIMEOUT"
    fail=1
    continue
  fi
  total=$((total + got))
  if [ "$got" != "$want" ]; then
    printf '  FAIL  %-46s %s of %s diagrams drew\n' "$page" "$got" "$want"
    fail=1
  fi
done < <(cd "$SITE" && find . -name '*.html' ! -name '_selftest.html' -printf '%P\n' | sort)

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
