#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Optional: show host CPU load on the LED matrix at every boot.
# Run:  sudo bash ~/hybrid/provision/50-cpu-bars.sh
#
# Unlike 10..40 this one is a convenience, not a prerequisite - nothing else in
# the project needs it, and it is the only unit here that holds a resource you
# will want back.
#
# IT KEEPS /dev/ttyHS1 OPEN. pyserial opens the port exclusively, so while this
# service runs, `mcucon`, `tio`, unoq.MCU and FOTA all fail with "device busy".
# Stop it before working on the MCU:
#
#     sudo systemctl stop unoq-cpu-bars      # start it again when you are done
#
# Flashing over SWD (flash.sh, zflash) is unaffected - that is OpenOCD on the
# GPIO lines, not the UART.
set -uo pipefail

# REVERT: systemctl disable --now unoq-cpu-bars.service &&
#         rm /etc/systemd/system/unoq-cpu-bars.service && systemctl daemon-reload
install -m 0644 /home/arduino/hybrid/python/unoq-cpu-bars.service \
  /etc/systemd/system/unoq-cpu-bars.service
systemctl daemon-reload
systemctl enable --now unoq-cpu-bars.service
systemctl --no-pager status unoq-cpu-bars.service | head -8

echo
echo "Logs:  journalctl -u unoq-cpu-bars -f"
echo "Stop:  sudo systemctl stop unoq-cpu-bars   (frees /dev/ttyHS1)"
