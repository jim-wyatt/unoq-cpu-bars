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
# BUILD DIRECTORY
# ---------------
# This project's own app builds into $WS/build - the path the docs, the VS Code
# tasks and launch.json all name. Any *other* app (a Zephyr sample, a second
# project) builds into $WS/build-<name> instead. Sharing one build directory
# would mean a pristine rebuild on every switch, and would repoint this
# project's compile_commands.json at whatever built last, so clangd would
# quietly index the wrong tree. Override with BUILD_DIR=... if you need to.
#
# Board name is the upstream Zephyr one: arduino_uno_q. No Arduino tooling
# is involved - this is stock Zephyr plus the Zephyr SDK.
set -euo pipefail

WS="${ZEPHYR_WORKSPACE:-$HOME/zephyrproject}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BOARD="${BOARD:-arduino_uno_q}"
SDK="${ZEPHYR_SDK:-$HOME/zephyr-sdk-1.0.1}"

export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
export ZEPHYR_SDK_INSTALL_DIR="$SDK"

APP="${1:?usage: zbuild.sh <app-path> [extra west args]}"; shift || true

# Accept an app path relative to your cwd, or relative to the Zephyr tree
# (e.g. samples/basic/blinky). Resolve to absolute BEFORE the cd below - west
# runs from $WS, so a relative path would otherwise resolve against the wrong
# directory and fail with a confusing "source directory does not exist".
if [ -d "$APP" ]; then
  APP="$(cd "$APP" && pwd)"
elif [ -d "$WS/zephyr/$APP" ]; then
  APP="$(cd "$WS/zephyr/$APP" && pwd)"
else
  echo "no such app: $APP" >&2
  exit 1
fi

# See BUILD DIRECTORY above. OWN_APP also gates the compile_commands.json link.
case "$APP/" in
  "$PROJECT"/*) BUILD="$WS/build";                      OWN_APP=1 ;;
  *)            BUILD="$WS/build-$(basename "$APP")";   OWN_APP=0 ;;
esac
BUILD="${BUILD_DIR:-$BUILD}"

cd "$WS"
echo "building $APP for $BOARD"
echo "  build dir: $BUILD"
./.venv/bin/west build -b "$BOARD" -d "$BUILD" "$APP" "$@"

# clangd reads compile_commands.json from the workspace root. west writes it
# into build/, so link it into both folders you might have open: the Zephyr
# workspace, and this project.
if [ -f "$BUILD/compile_commands.json" ]; then
  ln -sf "$BUILD/compile_commands.json" "$WS/compile_commands.json"
  if [ "$OWN_APP" = 1 ]; then
    # Only this project's own app may repoint this project's clangd index.
    ln -sf "$BUILD/compile_commands.json" "$PROJECT/compile_commands.json"
    echo "linked compile_commands.json (zephyrproject + $(basename "$PROJECT"))"
  else
    echo "linked compile_commands.json (zephyrproject only - $APP is outside $PROJECT)"
  fi
fi

# If the app is built for MCUboot it links into slot0 and MUST be signed -
# MCUboot will refuse the raw image, and flashing zephyr.hex over the
# bootloader would brick the chain. Sign automatically so that cannot happen.
if grep -q "^CONFIG_BOOTLOADER_MCUBOOT=y" "$BUILD/zephyr/.config" 2>/dev/null; then
  VERSION="${IMAGE_VERSION:-0.0.0+$(date +%s 2>/dev/null || echo 0)}"
  echo "signing for MCUboot (version $VERSION)"
  "$WS/.venv/bin/west" sign -t imgtool -d "$BUILD" -p "$WS/.venv/bin/imgtool" -- \
      --key "$WS/bootloader/mcuboot/root-rsa-2048.pem" \
      --version "$VERSION" >/dev/null
  echo "  -> $(basename "$BUILD")/zephyr/zephyr.signed.bin  (upload with unoq.fota)"
  echo "  -> $(basename "$BUILD")/zephyr/zephyr.signed.hex  (flash to slot0 with flash.sh)"
fi

echo
if [ -f "$BUILD/zephyr/zephyr.signed.hex" ]; then
  # MCUboot build: the unsigned hex must NOT be flashed - it links into slot0
  # but has no image header, so the bootloader will refuse to boot it.
  ls -la "$BUILD/zephyr/zephyr.signed.hex" "$BUILD/zephyr/zephyr.signed.bin" 2>/dev/null || true
  echo
  echo "flash over SWD :  ~/hybrid/mcu/flash.sh $BUILD/zephyr/zephyr.signed.hex"
  echo "update over UART:  python -c \"from unoq import fota; \\"
  echo "                     fota.upload('$BUILD/zephyr/zephyr.signed.bin'); \\"
  echo "                     fota.test(); fota.reset()\"   # then fota.confirm()"
else
  ls -la "$BUILD/zephyr/zephyr.hex" "$BUILD/zephyr/zephyr.bin" 2>/dev/null || true
  echo
  echo "flash it:  ~/hybrid/mcu/flash.sh $BUILD/zephyr/zephyr.hex"
fi
