#!/bin/bash
# Pre-commit gate. Installed by tools/install-hooks.sh.
#
# Runs the fast gates (lint, format, types, Python tests) but not the MCU
# suite, which builds Zephyr and takes ~70s - too slow to sit in front of
# every commit. CI runs the same script, and check.sh with no --fast covers
# the rest before you push.
#
# Skip once with:  git commit --no-verify
set -uo pipefail

PROJECT="$(git rev-parse --show-toplevel)"

# Check the tree as it will exist after the commit, not the working tree:
# a partially staged file would otherwise be judged on unstaged content.
STASHED=0
if ! git diff --quiet; then
  git stash push --keep-index --quiet --message "pre-commit: unstaged" &&
    STASHED=1
fi

"$PROJECT/tools/check.sh" --fast
STATUS=$?

[ "$STASHED" = 1 ] && git stash pop --quiet

if [ "$STATUS" -ne 0 ]; then
  echo
  echo "Commit blocked. Fix the failures above, or:"
  echo "  tools/check.sh --fix     # reformat in place"
  echo "  git commit --no-verify   # skip this once"
fi
exit "$STATUS"
