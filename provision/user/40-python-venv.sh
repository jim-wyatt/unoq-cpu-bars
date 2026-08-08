#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The MPU-side Python venv and the `unoq` package. Runs as YOU, not root.
#
#   bash ~/hybrid/provision/user/40-python-venv.sh
#
# Idempotent.
#
# The package is installed EDITABLE (-e) on purpose: this is the working
# checkout, and an editable install means an edit to python/unoq/ takes effect
# without a reinstall. It is also why python/ must not move.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

[ "$(id -u)" = 0 ] && fail "run this WITHOUT sudo - it installs into the checkout"

export PATH="$HOME/.local/bin:$PATH"
VENV="${UNOQ_VENV:-$PROJECT/.venv}"

command -v uv >/dev/null 2>&1 || fail "uv missing - run provision/user/10-host-tools.sh first"

step "venv"
if [ -x "$VENV/bin/python" ]; then
  skip "$VENV exists ($("$VENV/bin/python" --version))"
else
  uv venv "$VENV" >/dev/null 2>&1 || fail "could not create $VENV"
  did "created $VENV"
fi

step "hardware libraries"
# gpiod drives the BOOT0/link lines, pyserial the shell, smpclient the FOTA
# path. smbus2 and spidev are for the Qwiic/SPI headers - not used by the
# CPU-bars demo, but this is the venv you get a REPL in.
if "$VENV/bin/python" -c 'import gpiod, serial, smpclient' 2>/dev/null; then
  skip "gpiod, pyserial, smpclient present"
else
  uv pip install --python "$VENV/bin/python" -q gpiod smbus2 pyserial spidev smpclient ||
    fail "could not install the hardware libraries"
  did "hardware libraries installed"
fi

step "unoq package (editable)"
if "$VENV/bin/python" -c 'import unoq' 2>/dev/null && [ -x "$VENV/bin/unoq-cpu-bars" ]; then
  skip "unoq importable and unoq-cpu-bars on PATH"
else
  uv pip install --python "$VENV/bin/python" -q -e "$PROJECT/python" ||
    fail "could not install the unoq package"
  did "unoq installed editable from $PROJECT/python"
fi

step "dev tooling"
# Delegated rather than duplicated: install-dev-tools.sh already knows how to
# get ruff/mypy/pytest into this venv and shellcheck/shfmt into ~/.local/bin,
# and it is what CI runs too.
if [ -x "$VENV/bin/pytest" ] && [ -x "$VENV/bin/mypy" ] && [ -x "$VENV/bin/ruff" ]; then
  skip "ruff, mypy and pytest present"
else
  "$PROJECT/tools/install-dev-tools.sh" >/dev/null 2>&1 ||
    fail "tools/install-dev-tools.sh failed - run it directly to see why"
  did "dev tooling installed"
fi

step "verify"
if out="$("$VENV/bin/python" -c 'import unoq; print(unoq.__version__)' 2>&1)"; then
  skip "unoq $out"
else
  fail "unoq will not import: $out"
fi

summary
