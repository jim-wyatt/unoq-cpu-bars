#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Run the MCU test suites on the host - no flashing, no hardware.
#
#   ./ztest.sh                 # run everything under mcu/tests/
#   ./ztest.sh -p arduino_uno_q  # cross-compile for the real board instead
#
# native_sim builds a normal Linux binary, so tests execute natively on the
# UNO Q's own MPU. Use native_sim/native/64 - plain native_sim is a 32-bit
# target and fails on aarch64 with a CONFIG_64BIT error.
set -euo pipefail

WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
HERE="$(cd "$(dirname "$0")" && pwd)"

export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export ZEPHYR_SDK_INSTALL_DIR="${ZEPHYR_SDK:-$HOME/zephyr-sdk-1.0.1}"
export ZEPHYR_BASE="$WS/zephyr"

PLATFORM="native_sim/native/64"
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -p | --platform)
      PLATFORM="$2"
      shift 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

# --clobber-output deletes the previous outdir instead of renaming it. Without
# it twister keeps every past run as twister-out.1, .2, .3 ... and /tmp here is
# tmpfs, so each 19 MB run is 19 MB of the board's shared RAM, forever.
exec "$WS/.venv/bin/python" "$WS/zephyr/scripts/twister" \
  -T "$HERE/tests" \
  -p "$PLATFORM" \
  --outdir /tmp/twister-out \
  --clobber-output \
  -v "${ARGS[@]}"
