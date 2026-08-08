#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Remove the remaining Arduino Debian packages.
#
#   sudo bash ~/hybrid/provision/40-purge-arduino.sh
#
# Their services are already disabled by 20-dev-tools.sh, so this only reclaims
# disk - it does not change behaviour. Run it when you are confident you will
# not go back. Idempotent: a second run finds nothing to remove.
#
# SAFETY: /opt/openocd is owned by NO package (`dpkg -S /opt/openocd` finds
# nothing), so apt cannot remove it. It is the only way to flash the MCU.
# Verified below before and after; the script aborts rather than proceed
# without it.
#
# TO GO BACK: apt-get install -y arduino-app-cli arduino-app-lab \
#                                arduino-router arduino-cli
#             ~/hybrid/mcu/restore-arduino-firmware.sh
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

OCD="${OCD_ROOT:-/opt/openocd}"

step "openocd before"
if [ -x "$OCD/bin/openocd" ]; then
  skip "$OCD/bin/openocd present"
else
  fail "$OCD/bin/openocd is already missing - refusing to purge.
  Restore it first:  sudo cp -a ~/uno-q-backup/openocd $OCD
  or rebuild it:     sudo bash $PROJECT/tools/build-openocd.sh --promote"
fi

# The stock MCU firmware is Arduino's build and is not redistributable, so it
# cannot be recovered from this repo, or from apt, or from anywhere else once
# this script has run: after the purge ~/.arduino15 is gone and so is the only
# copy on the board. Getting this wrong costs a factory reset.
#
# The image is FOUND, not guessed at. This used to glob
# .../hardware/zephyr/*/variants/*/*.hex, which matches nothing on core 0.55.2 -
# the .hex is in firmwares/, and variants/ holds the board's sources. So the
# backup silently found nothing, warned, and carried on into the purge, which
# is the failure this step exists to prevent, dressed up as having run.
#
# A find over the core covers both layouts and any later rearrangement, which
# matters because the layout is Arduino's to change and this script only gets
# one attempt at it, on someone else's board, with no way back.
step "stock firmware backup"
BACKUP_DIR="${UNOQ_BACKUP:-$TARGET_HOME/uno-q-backup}"
STOCK_FOUND="$(find "$TARGET_HOME/.arduino15/packages/arduino/hardware/zephyr" \
  -name '*stm32u585xx*.hex' -type f 2>/dev/null | sort | head -1)"
if compgen -G "$BACKUP_DIR/*.hex" >/dev/null; then
  skip "stock firmware already backed up in $BACKUP_DIR"
elif [ -n "$STOCK_FOUND" ]; then
  as_user mkdir -p "$BACKUP_DIR"
  as_user cp "$STOCK_FOUND" "$BACKUP_DIR/"
  did "backed up $(basename "$STOCK_FOUND") -> $BACKUP_DIR"
elif [ "${UNOQ_ALLOW_NO_STOCK_FW:-0}" = "1" ]; then
  warn "no stock .hex found, and UNOQ_ALLOW_NO_STOCK_FW=1 - purging anyway."
  warn "restore-arduino-firmware.sh will have nothing to flash, permanently."
else
  # Refuses rather than warns. Everything else here has a revert line in the
  # comment above it; this is the one step whose damage is not undoable, so
  # "continuing" was never the right default - a warning scrolls past in a
  # bootstrap run and is read, if at all, after the fact.
  fail "no stock MCU firmware found under $TARGET_HOME/.arduino15 and none in
        $BACKUP_DIR. It is Arduino's build - not in this repo, not in apt -
        and this script is about to delete the only copy on the board.

        Find and copy it first:
          find ~/.arduino15 -name '*stm32u585xx*.hex'
          mkdir -p $BACKUP_DIR && cp <that file> $BACKUP_DIR/

        Or accept losing it: UNOQ_ALLOW_NO_STOCK_FW=1 sudo bash $0"
fi

step "remove Arduino packages"
apt_remove arduino-app-cli arduino-app-lab arduino-router arduino-cli

step "autoremove"
if DEBIAN_FRONTEND=noninteractive apt-get -s autoremove 2>/dev/null | grep -q '^Remv'; then
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null
  did "autoremoved orphaned dependencies"
else
  skip "nothing to autoremove"
fi

step "openocd after (must still work)"
if "$OCD/bin/openocd" --version >/dev/null 2>&1; then
  skip "flashing capability intact: $("$OCD/bin/openocd" --version 2>&1 | head -1 | cut -d' ' -f1-4)"
else
  fail "openocd is GONE - restore it now:
  sudo cp -a $BACKUP_DIR/openocd $OCD
  or rebuild: sudo bash $PROJECT/tools/build-openocd.sh --promote"
fi

summary
