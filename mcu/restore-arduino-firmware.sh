#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# RECOVERY: put the board back to the stock Arduino Zephyr firmware.
#
#   ./restore-arduino-firmware.sh
#
# Run this if a west-built firmware misbehaves, or if you want the Arduino
# App / Bridge stack working again.
#
# You supply the image. It is Arduino's build rather than this project's, so
# it is not redistributed here (THIRD-PARTY.md) - copy it off your own board
# before purging the Arduino tree, and it will still work once ~/.arduino15 is
# gone.
#
# After restoring, the MCU again exposes the Router Bridge on /dev/ttyHS1,
# and `arduino-app-cli` (if still installed) will behave as it did originally.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# The stock image is Arduino's build, not ours to redistribute, so it is not in
# this repository - see THIRD-PARTY.md. Point STOCK_FW at your own copy.
FW="${STOCK_FW:-$HOME/uno-q-backup/zephyr-arduino_uno_q_stm32u585xx.hex}"

[ -f "$FW" ] || {
  cat >&2 <<EOF
stock firmware not found at: $FW

It is Arduino's image, so this repository does not ship it. Copy it off your
own board BEFORE running provision/40-purge-arduino.sh, which is the point
after which there is no copy left anywhere:

  mkdir -p ~/uno-q-backup
  find ~/.arduino15 -name '*stm32u585xx*.hex' -exec cp {} ~/uno-q-backup/ \;

A find rather than a path, because the layout has moved: on core 0.55.2 the
image is in firmwares/, not the variants/ directory this used to name.

then re-run this, or set STOCK_FW=/path/to/image.hex
EOF
  exit 1
}

echo "This will overwrite the MCU with the stock Arduino firmware:"
echo "  $FW"
read -rp "continue? [y/N] " ans
[ "$ans" = "y" ] || {
  echo "aborted."
  exit 0
}

exec "$HERE/flash.sh" "$FW"
