#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Bring up the MPU <-> MCU hardware link on the Arduino UNO Q.
#
#   ~/two-computers-one-board/mcu/link-up.sh
#
# WHY THIS EXISTS
# ---------------
# Two GPIO lines on the MPU control the MCU, and nothing in the Zephyr board
# definition mentions them. They were previously driven by `arduino-router`,
# so disabling that service silently breaks the board:
#
#   gpiochip1 line 37  = MCU BOOT0
#       Latched at MCU reset. HIGH/floating -> the STM32 boots its internal
#       ROM bootloader (PC lands around 0x0bf9xxxx) and your firmware in
#       flash never runs, even though it flashed and verified fine.
#
#   gpiochip1 line 70  = UART link enable
#       LOW/floating -> the MCU transmits happily but nothing reaches
#       /dev/ttyHS1. Looks exactly like broken firmware. It is not.
#
# Pin state persists after the gpioset process exits (the SoC pinctrl keeps
# driving the last value), which is why a one-shot is enough - that is also
# how arduino-router did it.
#
# SWD lines, for reference: swclk=26 swdio=25 srst/trst=38 (all chip 1).
set -euo pipefail

CHIP="${UNOQ_GPIOCHIP:-/dev/gpiochip1}"
BOOT0="${UNOQ_BOOT0_LINE:-37}"
LINK_EN="${UNOQ_LINK_LINE:-70}"

# -t0 = set and exit (no toggling); the value sticks.
gpioset -c "$CHIP" -t0 "$BOOT0=0"
gpioset -c "$CHIP" -t0 "$LINK_EN=1"

echo "UNO Q link up: BOOT0(line $BOOT0)=0  UART-enable(line $LINK_EN)=1  on $CHIP"
