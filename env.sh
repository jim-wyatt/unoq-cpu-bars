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

# uv, west, cmake, ninja (installed as uv tools) + on-board OpenOCD
export PATH="$HOME/.local/bin:/opt/openocd/bin:$PATH"

# Zephyr / west
export ZEPHYR_BASE="$HOME/zephyrproject/zephyr"
export ZEPHYR_SDK_INSTALL_DIR="$HOME/zephyr-sdk-1.0.1"
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export BOARD=arduino_uno_q

# west lives in the workspace venv, not on the global PATH
west() { "$HOME/zephyrproject/.venv/bin/west" "$@"; }

# MPU-side Python (gpiod, smbus2, pyserial, spidev)
alias hpy='$HOME/hybrid/.venv/bin/python'

# MCU helpers
alias zbuild='$HOME/hybrid/mcu/zbuild.sh'
alias zflash='$HOME/hybrid/mcu/flash.sh'

# Watch the MCU console (lpuart1 -> /dev/ttyHS1). Ctrl-C to stop.
mcucon() {
  "$HOME/hybrid/.venv/bin/python" - <<'PY'
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
