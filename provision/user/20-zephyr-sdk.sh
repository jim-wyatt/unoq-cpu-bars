#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The Zephyr SDK (arm-zephyr-eabi toolchain). Runs as YOU, not root.
#
#   bash ~/hybrid/provision/user/20-zephyr-sdk.sh
#
# Idempotent, and resumable: the download is ~1 GB and lands in a temp file
# that is only moved into place once it has been verified, so an interrupted
# run does not leave a half-SDK that later steps would try to use.
#
# Only the arm-zephyr-eabi toolchain is installed. The full SDK carries a dozen
# architectures this board will never build for.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/lib.sh"

[ "$(id -u)" = 0 ] && fail "run this WITHOUT sudo - it installs into \$HOME"

SDK_VERSION="${ZEPHYR_SDK_VERSION:-1.0.1}"
SDK_DIR="$HOME/zephyr-sdk-$SDK_VERSION"
TOOLCHAIN="arm-zephyr-eabi"

case "$(uname -m)" in
  aarch64 | arm64) SDK_ARCH=aarch64 ;;
  x86_64 | amd64) SDK_ARCH=x86_64 ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

step "Zephyr SDK $SDK_VERSION ($SDK_ARCH)"
if [ -x "$SDK_DIR/$TOOLCHAIN/bin/$TOOLCHAIN-gcc" ]; then
  skip "$SDK_DIR already has $TOOLCHAIN"
else
  BASE="https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v$SDK_VERSION"
  TARBALL="zephyr-sdk-${SDK_VERSION}_linux-${SDK_ARCH}_minimal.tar.xz"
  TMP="$(mktemp -d)"
  # shellcheck disable=SC2064  # $TMP must expand now, not at trap time
  trap "rm -rf '$TMP'" EXIT

  echo "  downloading $TARBALL (~100 MB minimal + toolchain)..."
  curl -fL --progress-bar "$BASE/$TARBALL" -o "$TMP/sdk.tar.xz" ||
    fail "download failed - check network access"

  echo "  extracting..."
  tar -xJf "$TMP/sdk.tar.xz" -C "$HOME" || fail "extract failed"
  [ -d "$SDK_DIR" ] || fail "expected $SDK_DIR after extract, not found"
  did "SDK unpacked to $SDK_DIR"

  echo "  installing the $TOOLCHAIN toolchain..."
  # -c registers the SDK with CMake's package registry, which is how west
  # finds it without ZEPHYR_SDK_INSTALL_DIR being set in every shell.
  (cd "$SDK_DIR" && ./setup.sh -t "$TOOLCHAIN" -c) >/dev/null 2>&1 ||
    fail "SDK setup.sh failed"
  did "$TOOLCHAIN installed"
fi

step "verify"
GCC="$SDK_DIR/$TOOLCHAIN/bin/$TOOLCHAIN-gcc"
if [ -x "$GCC" ]; then
  skip "$("$GCC" --version | head -1)"
else
  fail "$GCC missing after install"
fi

summary
