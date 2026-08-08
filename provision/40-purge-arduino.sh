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
# cannot be recovered from this repo. Warn while the Arduino tree still exists
# - after the purge, ~/.arduino15 is gone and so is the only copy.
step "stock firmware backup"
STOCK_GLOB=("$TARGET_HOME"/.arduino15/packages/arduino/hardware/zephyr/*/variants/*/*.hex)
BACKUP_DIR="${UNOQ_BACKUP:-$TARGET_HOME/uno-q-backup}"
if compgen -G "$BACKUP_DIR/*.hex" >/dev/null; then
  skip "stock firmware already backed up in $BACKUP_DIR"
elif [ -f "${STOCK_GLOB[0]}" ]; then
  as_user mkdir -p "$BACKUP_DIR"
  as_user cp "${STOCK_GLOB[0]}" "$BACKUP_DIR/"
  did "backed up $(basename "${STOCK_GLOB[0]}") -> $BACKUP_DIR"
else
  warn "no stock .hex found and none backed up."
  warn "restore-arduino-firmware.sh will have nothing to flash. Continuing."
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
