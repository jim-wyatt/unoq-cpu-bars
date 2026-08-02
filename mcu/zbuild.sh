#!/bin/bash
# Build a Zephyr application for the Arduino UNO Q (STM32U585) with west.
#
#   ./zbuild.sh samples/basic/blinky            # build a Zephyr sample
#   ./zbuild.sh ~/hybrid/mcu/app                # build your own app
#   ./zbuild.sh samples/basic/blinky -p         # pristine rebuild
#
# Afterwards:
#   ./flash.sh ~/zephyrproject/build/zephyr/zephyr.hex
#
# Board name is the upstream Zephyr one: arduino_uno_q. No Arduino tooling
# is involved - this is stock Zephyr plus the Zephyr SDK.
set -euo pipefail

WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
BOARD="${BOARD:-arduino_uno_q}"
SDK="${ZEPHYR_SDK:-$HOME/zephyr-sdk-1.0.1}"

export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export ZEPHYR_SDK_INSTALL_DIR="$SDK"

APP="${1:?usage: zbuild.sh <app-path> [extra west args]}"; shift || true

# Allow paths relative to the Zephyr tree, e.g. samples/basic/blinky
[ -d "$APP" ] || APP="$WS/zephyr/$APP"
[ -d "$APP" ] || { echo "no such app: $APP" >&2; exit 1; }

cd "$WS"
echo "building $APP for $BOARD"
./.venv/bin/west build -b "$BOARD" "$APP" "$@"

# clangd reads compile_commands.json from the workspace root. west writes it
# into build/, so link it up to give the editor working IntelliSense.
if [ -f "$WS/build/compile_commands.json" ]; then
  ln -sf "$WS/build/compile_commands.json" "$WS/compile_commands.json"
  echo "linked compile_commands.json -> build/"
fi

echo
ls -la "$WS/build/zephyr/zephyr.hex" "$WS/build/zephyr/zephyr.bin" 2>/dev/null || true
echo
echo "flash it:  ~/hybrid/mcu/flash.sh $WS/build/zephyr/zephyr.hex"
