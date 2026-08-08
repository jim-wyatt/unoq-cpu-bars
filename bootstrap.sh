#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Take a stock, freshly flashed Arduino UNO Q to a working hybrid dev board.
#
#   git clone https://github.com/jim-wyatt/unoq-cpu-bars.git ~/hybrid
#   cd ~/hybrid && ./bootstrap.sh
#
# Run it as YOURSELF, not as root: it calls sudo for the parts that need it and
# keeps everything else owned by you. A bootstrap that runs wholly as root
# leaves a $HOME full of root-owned files, which is the most common way this
# kind of script half-works.
#
# IDEMPOTENT. Re-running is the recovery path: every step reports "changed" or
# "already correct", so a run that died halfway is fixed by running it again,
# not by unpicking what it did.
#
# WHAT IT DOES NOT DO
# -------------------
#   - purge the Arduino stack (--with-purge; it is the one step you cannot
#     casually undo, and the stock MCU firmware is not redistributable)
#   - claim /dev/ttyHS1 for the LED matrix demo (--with-cpu-bars)
#   - switch the USB port to peripheral mode (--with-usb-gadget; it drops the
#     USB host port and every device on it, including a network dongle)
#
# TIME AND SPACE: ~40-60 minutes on a cold board, almost all of it the Zephyr
# workspace (~3.3 GB) and SDK (~1 GB). Make sure you have ~6 GB free.
set -uo pipefail

PROJECT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT" || exit 1
# shellcheck source=provision/lib.sh
. "$PROJECT/provision/lib.sh"

WITH_PURGE=0
WITH_CPU_BARS=0
WITH_USB_GADGET=0
WITH_LEARNING=0
SKIP_MCU=0

usage() {
  sed -n '2,30p' "$0"
  cat <<'EOF'

Options:
  --with-purge        also remove the Arduino Debian packages (40)
  --with-cpu-bars     also run the LED-matrix demo at boot (50) - holds ttyHS1
  --with-usb-gadget   also enable IP-over-USB + the fileshare (60)
                      WARNING: drops the USB host port and anything on it
  --with-learning     also serve the learning content over HTTP (70)
  --everything        all of the above
  --skip-mcu          do not build or flash the MCU firmware at the end
  -h, --help          this
EOF
}

for arg in "$@"; do
  case "$arg" in
    --with-purge) WITH_PURGE=1 ;;
    --with-cpu-bars) WITH_CPU_BARS=1 ;;
    --with-usb-gadget) WITH_USB_GADGET=1 ;;
    --with-learning) WITH_LEARNING=1 ;;
    --everything)
      WITH_PURGE=1
      WITH_CPU_BARS=1
      WITH_USB_GADGET=1
      WITH_LEARNING=1
      ;;
    --skip-mcu) SKIP_MCU=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

[ "$(id -u)" = 0 ] && fail "run this as yourself, not with sudo - it calls sudo where needed"

# --- preflight -------------------------------------------------------------

step "preflight"

# `compatible` is a list of NUL-separated strings, most-specific first. It has
# to be split ON the NULs, not stripped OF them: `tr -d` concatenated the three
# tokens into "arduino,imolaqcom,qrb2210qcom,qcm2290", which matches neither
# board, so this check warned "unrecognised board" on every UNO Q and every
# VENTUNO Q it ever ran on - an identity check that had never once identified
# anything.
BOARD="$(tr '\0' '\n' </sys/firmware/devicetree/base/compatible 2>/dev/null | head -1)"
case "$BOARD" in
  arduino,imola) skip "board: Arduino UNO Q ($BOARD)" ;;
  arduino,monza) skip "board: Arduino VENTUNO Q ($BOARD)" ;;
  "") warn "cannot read the devicetree - this may not be an UNO Q. Continuing." ;;
  *) warn "unrecognised board '$BOARD' - written for arduino,imola. Continuing." ;;
esac

if sudo -n true 2>/dev/null; then
  skip "sudo available without a password"
else
  echo "  sudo will prompt for your password (once, cached for the run)."
  sudo -v || fail "sudo is required"
fi

FREE_MB=$(df -Pm "$HOME" | awk 'NR==2 {print $4}')
if [ "$FREE_MB" -lt 6000 ]; then
  warn "only ${FREE_MB} MB free in $HOME - the SDK and workspace need ~4.5 GB"
else
  skip "${FREE_MB} MB free in $HOME"
fi

curl -fsS --max-time 20 -o /dev/null https://github.com 2>/dev/null ||
  fail "no network access - the SDK, Zephyr and PyPI all need to be reachable"
skip "network reachable"

# --- run the steps ---------------------------------------------------------

# run_step <label> <sudo|user> <script> [args...]
run_step() {
  local label="$1" mode="$2" script="$3"
  shift 3
  printf '\n%s########## %s ##########%s\n' "$P_BOLD" "$label" "$P_OFF"
  if [ "$mode" = sudo ]; then
    sudo -E bash "$script" "$@" || fail "$label failed - fix it and re-run bootstrap.sh"
  else
    bash "$script" "$@" || fail "$label failed - fix it and re-run bootstrap.sh"
  fi
}

run_step "10  board optimisation (root)" sudo "$PROJECT/provision/10-optimize-board.sh"
run_step "20  dev tools (root)" sudo "$PROJECT/provision/20-dev-tools.sh"

run_step "u10 host tools: uv, cmake, ninja, west" user "$PROJECT/provision/user/10-host-tools.sh"
run_step "u20 Zephyr SDK" user "$PROJECT/provision/user/20-zephyr-sdk.sh"
run_step "u30 Zephyr workspace (~3.3 GB, slow)" user "$PROJECT/provision/user/30-zephyr-workspace.sh"
run_step "u40 python venv + unoq package" user "$PROJECT/provision/user/40-python-venv.sh"
run_step "u50 shell env + git hook" user "$PROJECT/provision/user/50-shell-env.sh"

# 30 needs the venv from u40 to verify the GPIO lines, so it runs after it.
run_step "30  MCU link GPIOs (root)" sudo "$PROJECT/provision/30-mcu-link.sh"

[ "$WITH_PURGE" = 1 ] &&
  run_step "40  purge Arduino packages (root)" sudo "$PROJECT/provision/40-purge-arduino.sh"

# --- MCU firmware ----------------------------------------------------------

if [ "$SKIP_MCU" = 0 ]; then
  printf '\n%s########## MCU firmware ##########%s\n' "$P_BOLD" "$P_OFF"
  step "build"
  if bash "$PROJECT/mcu/zbuild.sh" "$PROJECT/mcu/app" >/tmp/zbuild-bootstrap.log 2>&1; then
    did "firmware built (log: /tmp/zbuild-bootstrap.log)"
  else
    warn "build failed - see /tmp/zbuild-bootstrap.log. Skipping flash."
    SKIP_MCU=1
  fi
fi

if [ "$SKIP_MCU" = 0 ]; then
  step "flash"
  # An MCUboot build must be flashed as the full chain the first time: the
  # signed app alone lands in slot0 with no bootloader in front of it.
  # flash-all.sh derives the workspace itself.
  if bash "$PROJECT/mcu/flash-all.sh" >/tmp/zflash-bootstrap.log 2>&1; then
    did "MCUboot + application flashed"
  else
    warn "flash failed - see /tmp/zflash-bootstrap.log"
    warn "recover with: $PROJECT/mcu/flash-all.sh"
  fi
fi

# --- optional extras -------------------------------------------------------

[ "$WITH_CPU_BARS" = 1 ] &&
  run_step "50  CPU bars at boot (root)" sudo "$PROJECT/provision/50-cpu-bars.sh"
[ "$WITH_LEARNING" = 1 ] &&
  run_step "70  learning content web server (root)" sudo "$PROJECT/provision/70-learning-web.sh"
# Last, always: it takes the USB host port down with it.
[ "$WITH_USB_GADGET" = 1 ] &&
  run_step "60  USB gadget (root)" sudo "$PROJECT/provision/60-usb-gadget.sh"

# --- done ------------------------------------------------------------------

printf '\n%s########## done ##########%s\n' "$P_BOLD" "$P_OFF"
cat <<EOF

  source $PROJECT/env.sh          # or open a new shell
  $PROJECT/tools/check.sh         # all quality gates
  mcucon                          # watch the MCU console

  python -c "from unoq import MCU; print(MCU().status())"

EOF
[ "$WITH_CPU_BARS" = 0 ] &&
  echo "  LED matrix demo at boot:  sudo bash provision/50-cpu-bars.sh"
[ "$WITH_PURGE" = 0 ] &&
  echo "  Reclaim the Arduino disk: sudo bash provision/40-purge-arduino.sh"
[ "$WITH_USB_GADGET" = 0 ] &&
  echo "  IP over USB + fileshare:  sudo bash provision/60-usb-gadget.sh"
echo
