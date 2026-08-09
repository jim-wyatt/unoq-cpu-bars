#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The two board LEDs Linux can drive: connectivity, and whether anything failed.
#
#   sudo bash ~/hybrid/provision/35-status-leds.sh
#
# Idempotent, and cheap: it installs one unit and starts it. Nothing here
# touches the network, the USB port or the MCU.
#
# WHY THIS IS NOT PART OF THE USB GADGET
# --------------------------------------
# It used to be. `leds.sh` lived in usb/ because the first thing it reported was
# the USB link, so 60-usb-gadget.sh installed it - which meant the LEDs only
# existed if you passed `--with-usb-gadget`.
#
# That is backwards. These LEDs are the board's ONLY output when the network is
# down, the gadget is unbound and nobody can log in. Making them conditional on
# an optional feature is making the fallback conditional on the thing it is a
# fallback for. A board provisioned without the gadget had no way to say
# anything at all.
#
# So they are installed unconditionally, from here, and `bootstrap.sh` runs this
# with the rest of the base setup rather than with the extras.
#
# REVERT: systemctl disable --now unoq-leds.service &&
#         rm /etc/systemd/system/unoq-leds.service && systemctl daemon-reload
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

step "the LEDs this board has"
# Six writable channels, which are two RGB packages rather than six lights - a
# distinction that cost an afternoon the first time. See docs/reference/hardware.md.
found=0
for ch in unoq:user-red1 unoq:user-green1 unoq:user-blue1 \
  unoq:panic-red2 unoq:wlan-green2 unoq:bt-blue2; do
  [ -w "/sys/class/leds/$ch/brightness" ] && found=$((found + 1))
done
if [ "$found" = 6 ]; then
  skip "all six channels present and writable"
elif [ "$found" -gt 0 ]; then
  warn "only $found of 6 LED channels found - the service will drive what it can"
else
  warn "no unoq:* LEDs under /sys/class/leds - is this an UNO Q?"
  warn "  the service is still installed; it degrades to doing nothing"
fi

step "systemd unit"
install_unit "$PROJECT/status/unoq-leds.service"
if systemctl is-enabled --quiet unoq-leds.service 2>/dev/null &&
  systemctl is-active --quiet unoq-leds.service; then
  skip "already enabled and running"
else
  # Started as well as enabled: there is nothing to wait for, and a board that
  # has just been provisioned should light up now rather than at the next boot.
  systemctl enable --now unoq-leds.service >/dev/null 2>&1 ||
    warn "could not start unoq-leds.service - check: journalctl -u unoq-leds"
  did "enabled and started"
fi

summary
cat <<EOF

What the colours mean:  $PROJECT/status/leds.sh explain
Learn them by watching: sudo $PROJECT/status/leds.sh test
EOF
