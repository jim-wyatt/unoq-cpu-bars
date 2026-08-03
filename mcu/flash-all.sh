#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Flash the complete MCUboot chain over SWD: bootloader + signed application.
#
#   ./flash-all.sh
#
# Use this for a from-scratch recovery, or after changing the bootloader.
# For routine app updates you do NOT need SWD at all - upload over serial:
#
#   python -c "from unoq import fota; fota.upload('.../zephyr.signed.bin'); \
#              fota.test(); fota.reset()"
#   # then fota.confirm() once it boots, or it reverts on the next reset.
#
# Layout (from the board DTS):
#   0x08000000  boot_partition  64K   MCUboot
#   0x08010000  slot0          416K   signed application
#   0x08078000  slot1          416K   staged update
#   0x080e0000  storage        128K   NVS (settings, boot counter)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
MCUBOOT_BUILD="${MCUBOOT_BUILD:-/tmp/bmcuboot}"
APP_HEX="${1:-$WS/build/zephyr/zephyr.signed.hex}"

if [ ! -f "$MCUBOOT_BUILD/zephyr/zephyr.hex" ]; then
  echo "MCUboot not built. Building it now..."
  ZEPHYR_TOOLCHAIN_VARIANT=zephyr \
    ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK:-$HOME/zephyr-sdk-1.0.1}" \
    "$WS/.venv/bin/west" build -b "${BOARD:-arduino_uno_q}" \
    "$WS/bootloader/mcuboot/boot/zephyr" -p always -d "$MCUBOOT_BUILD"
fi

[ -f "$APP_HEX" ] || {
  echo "no signed app image at $APP_HEX" >&2
  echo "build it with: ~/hybrid/mcu/zbuild.sh ~/hybrid/mcu/app" >&2
  exit 1
}

echo "== 1/2 MCUboot -> boot_partition =="
"$HERE/flash.sh" "$MCUBOOT_BUILD/zephyr/zephyr.hex"

echo "== 2/2 signed application -> slot0 =="
"$HERE/flash.sh" "$APP_HEX"

echo
echo "Chain flashed. Verify:"
echo "  python -c \"from unoq import MCU; print(MCU().status())\""
