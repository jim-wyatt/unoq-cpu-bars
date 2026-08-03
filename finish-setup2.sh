#!/bin/bash
# Final conveniences. Run:  sudo bash ~/hybrid/finish-setup2.sh
set -uo pipefail

# --- 1. tio: a far better serial terminal than the minicom that ships here.
# REVERT: apt-get remove -y tio
apt-get install -y tio

# --- 2. Apply the MCU link GPIOs at every boot.
#
# gpiochip1 line 37 = MCU BOOT0 (latched at reset; high/floating -> the STM32
#                    boots its ROM bootloader and your firmware never runs)
# gpiochip1 line 70 = UART link enable (low/floating -> /dev/ttyHS1 is silent)
#
# These were previously held by arduino-router, which is now disabled.
# REVERT: systemctl disable --now unoq-link.service && rm /etc/systemd/system/unoq-link.service
install -m 0644 /home/arduino/hybrid/mcu/unoq-link.service \
                /etc/systemd/system/unoq-link.service
systemctl daemon-reload
systemctl enable --now unoq-link.service
systemctl --no-pager status unoq-link.service | head -5

echo
echo "Serial console:  tio /dev/ttyHS1 -b 115200"
