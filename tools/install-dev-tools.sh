#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Install everything tools/check.sh needs. Idempotent; safe to re-run.
#
#   ~/hybrid/tools/install-dev-tools.sh
#
# No sudo and no apt. Debian's shellcheck/shfmt would need root, and this board
# is often used by a non-root user, so those two come from upstream releases
# into ~/.local/bin instead.
#
# Python tooling goes into the project venv rather than a uv tool install,
# because mypy has to import gpiod, pyserial and smpclient to check the code
# that uses them.
#
# Arch is detected rather than assumed: the board is aarch64, but CI runs this
# same script on x86_64.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="${UNOQ_VENV:-$PROJECT/.venv}"
BIN="${UNOQ_BIN:-$HOME/.local/bin}"

case "$(uname -m)" in
  aarch64 | arm64)
    SC_ARCH=aarch64
    SHFMT_ARCH=arm64
    ;;
  x86_64 | amd64)
    SC_ARCH=x86_64
    SHFMT_ARCH=amd64
    ;;
  *)
    echo "unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "$BIN"

echo "=== Python tooling -> $VENV ==="
[ -x "$VENV/bin/python" ] || uv venv "$VENV"
# Installed from the [dev] extra so the versions live in pyproject.toml.
uv pip install --python "$VENV/bin/python" -q -e "$PROJECT/python[dev]"
echo "  ruff $("$VENV"/bin/ruff --version | awk '{print $2}'), mypy $("$VENV"/bin/mypy --version | awk '{print $2}')"

echo "=== shellcheck -> $BIN ==="
if command -v shellcheck >/dev/null 2>&1; then
  echo "  already present: $(shellcheck --version | awk '/version:/ {print $2}')"
else
  tmp=$(mktemp -d)
  curl -sSL "https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.${SC_ARCH}.tar.xz" |
    tar -xJ -C "$tmp"
  install -m 0755 "$tmp"/shellcheck-stable/shellcheck "$BIN/shellcheck"
  rm -rf "$tmp"
  echo "  installed $("$BIN/shellcheck" --version | awk '/version:/ {print $2}')"
fi

echo "=== shfmt -> $BIN ==="
if command -v shfmt >/dev/null 2>&1; then
  echo "  already present: $(shfmt --version)"
else
  ver=$(curl -sSL https://api.github.com/repos/mvdan/sh/releases/latest |
    grep -oP '"tag_name": "\K[^"]+')
  curl -sSL "https://github.com/mvdan/sh/releases/download/${ver}/shfmt_${ver}_linux_${SHFMT_ARCH}" \
    -o "$BIN/shfmt"
  chmod +x "$BIN/shfmt"
  echo "  installed $("$BIN/shfmt" --version)"
fi

echo
echo "Done. Run the gates with:  $PROJECT/tools/check.sh"
echo "Install the pre-commit hook with:  $PROJECT/tools/install-hooks.sh"
command -v shellcheck >/dev/null 2>&1 ||
  echo "NOTE: $BIN is not on your PATH - env.sh adds it."
