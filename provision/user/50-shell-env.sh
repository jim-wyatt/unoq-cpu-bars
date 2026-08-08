#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Wire env.sh into your shell, and install the git pre-commit hook.
# Runs as YOU, not root.
#
#   bash ~/hybrid/provision/user/50-shell-env.sh
#
# Idempotent: the ~/.bashrc line is added once and matched on the marker, not
# on the literal path, so a re-run after moving the checkout updates it rather
# than appending a second source line.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

[ "$(id -u)" = 0 ] && fail "run this WITHOUT sudo - it edits your ~/.bashrc"

MARKER="# unoq hybrid dev environment"
BASHRC="$HOME/.bashrc"

step "$BASHRC"
LINE="$MARKER
source $PROJECT/env.sh"
if grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
  # Present - check it still points at this checkout.
  if grep -qF "source $PROJECT/env.sh" "$BASHRC"; then
    skip "already sources $PROJECT/env.sh"
  else
    # Rewrite the marked line rather than appending a competing one.
    sed -i "\#^source .*/env.sh\$#c\\source $PROJECT/env.sh" "$BASHRC"
    did "repointed the env.sh line at $PROJECT"
  fi
else
  printf '\n%s\n' "$LINE" >>"$BASHRC"
  did "added env.sh to $BASHRC"
fi

step "git pre-commit hook"
if [ -L "$PROJECT/.git/hooks/pre-commit" ]; then
  skip "hook already installed"
elif [ -d "$PROJECT/.git" ]; then
  "$PROJECT/tools/install-hooks.sh" >/dev/null 2>&1 ||
    warn "install-hooks.sh failed (a non-symlink hook may already exist)"
  did "pre-commit hook -> tools/check.sh --fast"
else
  skip "not a git checkout - no hook to install"
fi

step "verify"
# shellcheck source=/dev/null
if (
  set +u
  . "$PROJECT/env.sh" && command -v zbuild >/dev/null 2>&1
); then
  skip "env.sh sources cleanly and defines zbuild"
else
  warn "env.sh did not define the expected aliases - check it by hand"
fi

summary
echo "Open a new shell, or:  source $PROJECT/env.sh"
