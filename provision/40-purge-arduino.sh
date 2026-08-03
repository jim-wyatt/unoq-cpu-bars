#!/bin/bash
# Remove the remaining Arduino Debian packages.
#
#   sudo bash ~/hybrid/provision/40-purge-arduino.sh
#
# Their services are already disabled, so this only reclaims disk - it does not
# change behaviour. Run it when you are confident you will not go back.
#
# SAFETY: /opt/openocd is owned by NO package (`dpkg -S /opt/openocd` finds
# nothing), so apt cannot remove it. It is the only way to flash the MCU and
# is additionally backed up at ~/hybrid/backup/opt-openocd. Verified below
# before and after.
#
# TO GO BACK: apt-get install -y arduino-app-cli arduino-app-lab \
#                                arduino-router arduino-cli
#             ~/hybrid/mcu/restore-arduino-firmware.sh
set -uo pipefail

echo "== openocd before =="
ls -la /opt/openocd/bin/openocd || { echo "openocd already missing - ABORT" >&2; exit 1; }

apt-get remove -y arduino-app-cli arduino-app-lab arduino-router arduino-cli
apt-get autoremove -y

echo
echo "== openocd after (must still exist) =="
if /opt/openocd/bin/openocd --version 2>&1 | head -1; then
    echo "OK - flashing capability intact"
else
    echo "openocd is GONE - restore it now:" >&2
    echo "  sudo cp -a ~/hybrid/backup/opt-openocd /opt/openocd" >&2
    exit 1
fi

echo
echo "Sanity-check the toolchain still works:"
echo "  ~/hybrid/mcu/zbuild.sh ~/hybrid/mcu/app"
echo "  python -c \"from unoq import MCU; print(MCU().status())\""
