#!/bin/bash
# RECOVERY: put the board back to the stock Arduino Zephyr firmware.
#
#   ./restore-arduino-firmware.sh
#
# Run this if a west-built firmware misbehaves, or if you want the Arduino
# App / Bridge stack working again. The image restored here was copied out of
# the Arduino platform tree BEFORE anything was removed, so this works even
# after ~/.arduino15 is deleted.
#
# After restoring, the MCU again exposes the Router Bridge on /dev/ttyHS1,
# and `arduino-app-cli` (if still installed) will behave as it did originally.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$HERE/../backup/mcu-firmware/zephyr-arduino_uno_q_stm32u585xx.hex"

[ -f "$FW" ] || { echo "backup firmware missing: $FW" >&2; exit 1; }

echo "This will overwrite the MCU with the stock Arduino firmware:"
echo "  $FW"
read -rp "continue? [y/N] " ans
[ "$ans" = "y" ] || { echo "aborted."; exit 0; }

exec "$HERE/flash.sh" "$FW"
