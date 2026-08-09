#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The Zephyr workspace (~3.3 GB). Runs as YOU, not root. This is the long one.
#
#   bash ~/two-computers-one-board/provision/user/30-zephyr-workspace.sh
#
# Idempotent: an existing workspace at the right version is left alone.
#
# THE MANIFEST FILTER
# -------------------
# Keeps the workspace at ~3.3 GB instead of ~7 GB by skipping vendor HALs for
# hardware this board does not have. It is not cosmetic - a 3.6 GiB board with
# a 10 GB rootfs does not have 7 GB to spare.
#
# It lives in ../../west-project-filter and is READ from there, because CI now
# builds the same module set and a second copy would drift. Edit that file.
#
# NEVER `rm -rf` a module directory without filtering it out first: west would
# then be managing a project whose checkout has vanished, and every subsequent
# `west update` fails. Change the filter, then delete.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

[ "$(id -u)" = 0 ] && fail "run this WITHOUT sudo - it installs into \$HOME"

export PATH="$HOME/.local/bin:$PATH"

WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
ZEPHYR_VERSION="${ZEPHYR_VERSION:-v4.4.2}"
PYTHON_VERSION="${WS_PYTHON:-3.13}"

# Shared with CI rather than copied into it - see the file's own header. Read,
# not sourced, so the same bytes reach `west config` here and the workflow there.
FILTER_FILE="$PROJECT/west-project-filter"
[ -r "$FILTER_FILE" ] || fail "missing $FILTER_FILE - the module filter lives there now"
FILTER="$(grep -vE '^[[:space:]]*(#|$)' "$FILTER_FILE" | head -1)"
[ -n "$FILTER" ] || fail "$FILTER_FILE has no filter line"

command -v uv >/dev/null 2>&1 || fail "uv missing - run provision/user/10-host-tools.sh first"

step "workspace venv"
mkdir -p "$WS"
if [ -x "$WS/.venv/bin/python" ]; then
  skip "$WS/.venv exists"
else
  uv venv --python "$PYTHON_VERSION" "$WS/.venv" >/dev/null 2>&1 ||
    fail "could not create $WS/.venv"
  did "created $WS/.venv (python $PYTHON_VERSION)"
fi

step "west + imgtool in the workspace venv"
if [ -x "$WS/.venv/bin/west" ] && [ -x "$WS/.venv/bin/imgtool" ]; then
  skip "west and imgtool present"
else
  # imgtool signs the MCUboot image; zbuild.sh calls it by this path.
  uv pip install --python "$WS/.venv/bin/python" -q west imgtool ||
    fail "could not install west/imgtool"
  did "west + imgtool installed"
fi

step "Zephyr $ZEPHYR_VERSION checkout"
if [ -d "$WS/zephyr" ] && [ -f "$WS/.west/config" ]; then
  have="$(git -c safe.directory="$WS/zephyr" -C "$WS/zephyr" describe --tags 2>/dev/null)"
  skip "workspace initialised at ${have:-unknown}"
else
  echo "  west init (this clones Zephyr - several minutes)..."
  "$WS/.venv/bin/west" init -m https://github.com/zephyrproject-rtos/zephyr \
    --mr "$ZEPHYR_VERSION" "$WS" >/dev/null 2>&1 ||
    fail "west init failed"
  did "west init at $ZEPHYR_VERSION"
fi

step "manifest filter"
# `cd "$WS"`, not `-z "$WS"`: -z is --zephyr-base, which is not how west finds a
# workspace. Read from outside, it returned empty every time, so this compared
# the filter against "" and reported "changed" on every run of an idempotent
# script. The write below always used `cd` and was therefore always correct -
# only the reporting lied, which is why it survived.
current="$(cd "$WS" && "$WS/.venv/bin/west" config manifest.project-filter 2>/dev/null || true)"
if [ "$current" = "$FILTER" ]; then
  skip "filter already set"
else
  (cd "$WS" && "$WS/.venv/bin/west" config manifest.project-filter -- "$FILTER") ||
    fail "could not set the manifest filter"
  did "manifest filter set (keeps the workspace at ~3.3 GB)"
fi

step "west update"
# --narrow -o=--depth=1 fetches only the tips: full history of every Zephyr
# module is several GB of git objects nobody on this board will read.
if [ -d "$WS/modules/hal/stm32" ]; then
  skip "modules already checked out (delete $WS/modules to force a refresh)"
else
  echo "  west update (downloads ~3 GB - this is the slow step)..."
  (cd "$WS" && "$WS/.venv/bin/west" update --narrow -o=--depth=1) >/dev/null 2>&1 ||
    fail "west update failed"
  did "modules checked out"
fi

step "zephyr-export"
if [ -d "$HOME/.cmake/packages/Zephyr" ]; then
  skip "Zephyr already registered with CMake"
else
  (cd "$WS" && "$WS/.venv/bin/west" zephyr-export) >/dev/null 2>&1 ||
    fail "west zephyr-export failed"
  did "Zephyr registered with CMake"
fi

step "Zephyr's own python requirements"
# Zephyr pins its tool versions per release; these are deliberate, and
# check-versions.sh explains why `pip list --outdated` flags them.
if "$WS/.venv/bin/python" -c 'import pyelftools' 2>/dev/null ||
  "$WS/.venv/bin/python" -c 'import elftools' 2>/dev/null; then
  skip "requirements already satisfied"
else
  uv pip install --python "$WS/.venv/bin/python" -q \
    -r "$WS/zephyr/scripts/requirements.txt" ||
    fail "could not install Zephyr's requirements"
  did "Zephyr requirements installed"
fi

step "size"
skip "workspace: $(du -sh "$WS" 2>/dev/null | cut -f1)"

summary
