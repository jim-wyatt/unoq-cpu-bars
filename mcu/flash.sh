#!/bin/bash
# Flash the UNO Q's STM32U585 over SWD, bit-banged on the MPU's own GPIO lines.
#
#   ./flash.sh build/zephyr/zephyr.hex          # flash a west build
#   ./flash.sh firmware.bin 0x08000000          # flash a raw binary at address
#
# No root, no Arduino tooling. /opt/openocd is a system package (from the
# arduino-unoq deb) and is independent of ~/.arduino15.
#
# SWD wiring, per /opt/openocd/openocd_gpiod.cfg - all on /dev/gpiochip1:
#   swclk = 26   swdio = 25   srst/trst = 38
# Your user needs to be in the `gpiod` group (it is).
set -euo pipefail

OCD_ROOT=/opt/openocd
OPENOCD="$OCD_ROOT/bin/openocd"
CFG="$OCD_ROOT/openocd_gpiod.cfg"

IMG="${1:?usage: flash.sh <firmware.hex|firmware.bin> [load-address]}"
ADDR="${2:-}"

[ -f "$IMG" ]      || { echo "no such image: $IMG" >&2; exit 1; }
[ -x "$OPENOCD" ]  || { echo "openocd missing at $OPENOCD" >&2; exit 1; }

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
