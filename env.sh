# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Development environment for the Arduino UNO Q (MPU + STM32U585 MCU).
#
#   source ~/hybrid/env.sh
#
# Add that line to ~/.bashrc to have it always available.
#
# This file is sourced, never executed, so it has no shebang - the directive
# below is what tells shellcheck which shell to assume.
# shellcheck shell=bash

# Where this file lives. The helpers below used to name $HOME/hybrid literally,
# which is only right if you cloned to exactly that path - and nothing in this
# repo creates that symlink. A `git clone` with no destination, or VS Code's
# clone, gives you ~/unoq-cpu-bars, and then zbuild, zflash, hpy and mcucon all
# point at a directory that does not exist, while everything else keeps working.
# 50-shell-env.sh already points ~/.bashrc at the real checkout; this makes the
# rest of the file agree with it.
UNOQ_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]:-$HOME/hybrid/env.sh}")" && pwd)"
export UNOQ_PROJECT

# uv, west, cmake, ninja (installed as uv tools) + on-board OpenOCD
export PATH="$HOME/.local/bin:/opt/openocd/bin:$PATH"

# Zephyr / west
export ZEPHYR_BASE="$HOME/zephyrproject/zephyr"
export ZEPHYR_SDK_INSTALL_DIR="$HOME/zephyr-sdk-1.0.1"
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export BOARD=arduino_uno_q

# west lives in the workspace venv, not on the global PATH
west() { "$HOME/zephyrproject/.venv/bin/west" "$@"; }

# The three aliases below are double-quoted on purpose, so $UNOQ_PROJECT is
# resolved once here rather than left to expand when you run them. That is what
# SC2139 warns about, and it is the behaviour we want: the alias should keep
# pointing at the checkout it was sourced from even if $HOME or the working
# directory changes underneath it. Disabled per line, not per file, so a future
# alias that genuinely wants late expansion still gets flagged.

# MPU-side Python (gpiod, smbus2, pyserial, spidev)
# shellcheck disable=SC2139
alias hpy="$UNOQ_PROJECT/.venv/bin/python"

# MCU helpers
# shellcheck disable=SC2139
alias zbuild="$UNOQ_PROJECT/mcu/zbuild.sh"
# shellcheck disable=SC2139
alias zflash="$UNOQ_PROJECT/mcu/flash.sh"

# Watch the MCU console (lpuart1 -> /dev/ttyHS1). Ctrl-C to stop.
mcucon() {
  "$UNOQ_PROJECT/.venv/bin/python" - <<'PY'
import serial, sys
s = serial.Serial('/dev/ttyHS1', 115200, timeout=0.5)
print("--- /dev/ttyHS1 @115200 (Ctrl-C to stop) ---", file=sys.stderr)
try:
    while True:
        d = s.read(256)
        if d:
            sys.stdout.write(d.decode('utf-8', 'replace')); sys.stdout.flush()
except KeyboardInterrupt:
    s.close()
PY
}
