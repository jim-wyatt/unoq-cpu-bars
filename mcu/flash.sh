#!/bin/bash
# Flash the UNO Q's STM32U585 over SWD, bit-banged on the MPU's own GPIO lines.
#
#   ./flash.sh build/zephyr/zephyr.hex          # flash a west build
#   ./flash.sh firmware.bin 0x08000000          # flash a raw binary at address
#
# No root, no Arduino tooling needed.
#
# /opt/openocd is owned by NO Debian package - it was dropped in by an install
# script. `apt install openocd` will not substitute for it: Debian ships 0.12.0
# (2023), which predates the libgpiod v2 support this board needs. Rebuild from
# upstream OpenOCD master with ~/hybrid/tools/build-openocd.sh.
#
# SWD wiring, per /opt/openocd/openocd_gpiod.cfg - all on /dev/gpiochip1:
#   swclk = 26   swdio = 25   srst/trst = 38
# Your user needs to be in the `gpiod` group (it is).
set -euo pipefail

# Override to test a rebuilt OpenOCD without replacing the system one:
#   OCD_ROOT=/opt/openocd-rebuilt ./flash.sh ...
OCD_ROOT="${OCD_ROOT:-/opt/openocd}"
OPENOCD="$OCD_ROOT/bin/openocd"
CFG="$OCD_ROOT/openocd_gpiod.cfg"

IMG="${1:?usage: flash.sh <firmware.hex|firmware.bin> [load-address]}"
ADDR="${2:-}"

[ -f "$IMG" ] || {
  echo "no such image: $IMG" >&2
  exit 1
}
[ -x "$OPENOCD" ] || {
  echo "openocd missing at $OPENOCD" >&2
  exit 1
}

# BOOT0 (gpiochip1 line 37) is latched at MCU reset. If it is high or floating
# the STM32 boots its ROM bootloader instead of the image we just wrote - the
# flash succeeds and verifies, but nothing runs. Line 70 enables the UART link
# to Linux. Both were previously held by arduino-router. See link-up.sh.
"$(dirname "$0")/link-up.sh" || echo "warning: could not set BOOT0/link GPIOs" >&2

# .hex/.elf carry their own load addresses; raw .bin needs one supplied.
case "$IMG" in
  *.bin)
    ADDR="${ADDR:-0x08000000}"
    PROGRAM="program \"$IMG\" verify reset exit $ADDR"
    ;;
  *)
    PROGRAM="program \"$IMG\" verify reset exit"
    ;;
esac

echo "flashing $IMG ${ADDR:+@ $ADDR}"
"$OPENOCD" -s "$OCD_ROOT" -s "$OCD_ROOT/share/openocd/scripts" \
  -f "$CFG" -c "$PROGRAM"
echo "done."
