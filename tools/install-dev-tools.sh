#!/bin/bash
# Install everything tools/check.sh needs. Idempotent; safe to re-run.
#
#   ~/hybrid/tools/install-dev-tools.sh
#
# No sudo and no apt. Debian's shellcheck/shfmt would need root, and this board
# is often used by a non-root user, so the two Go/Haskell binaries come from
# upstream releases into ~/.local/bin instead.
#
# Python tooling goes into the project venv rather than a uv tool install,
# because mypy has to import gpiod, pyserial and smpclient to check the code
# that uses them.
set -euo pipefail

VENV="${UNOQ_VENV:-$HOME/hybrid/.venv}"
BIN="$HOME/.local/bin"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$BIN"

echo "=== Python tooling -> $VENV ==="
# Installed from the [dev] extra so the versions live in pyproject.toml.
uv pip install --python "$VENV/bin/python" -q -e "$PROJECT/python[dev]"

echo "=== shellcheck -> $BIN ==="
if command -v shellcheck >/dev/null 2>&1; then
  echo "  already present: $(shellcheck --version | awk '/version:/ {print $2}')"
else
  tmp=$(mktemp -d)
  curl -sSL https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.aarch64.tar.xz |
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
  curl -sSL "https://github.com/mvdan/sh/releases/download/${ver}/shfmt_${ver}_linux_arm64" \
    -o "$BIN/shfmt"
  chmod +x "$BIN/shfmt"
  echo "  installed $("$BIN/shfmt" --version)"
fi

echo
echo "Done. Run the gates with:  ~/hybrid/tools/check.sh"
command -v shellcheck >/dev/null 2>&1 ||
  echo "NOTE: $BIN is not on your PATH - env.sh adds it."
