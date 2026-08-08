#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Break the boot loop that a bad USB bind can put this board into.
#
#   bind-guard.sh check     # before binding: count the attempt, refuse after N
#   bind-guard.sh confirm   # once the board is demonstrably healthy: reset
#
# WHY THIS EXISTS
# ---------------
# usb.md's model is that plugging in is an occasional event: a UDC appears,
# udev fires, the gadget binds. That is true on a bench. It is not true of a
# board powered over the same USB-C cable that carries the gadget, which is the
# normal way this one is used - there, the cable is NEVER unplugged, so a UDC
# is present within seconds of every boot and the bind runs on every boot.
#
# That turns a survivable one-off failure into an unsurvivable repeating one.
# Binding re-enumerates the port. If the board is a sink at
# power_operation_mode=default - USB default current, no PD contract, which is
# what a laptop port gives you and is not much for four cores plus an MCU -
# re-enumerating under load can brown it out. It reboots, the UDC is still
# there, udev fires the bind, and it browns out again.
#
# The loop has no SSH window in it. Nothing to log into, wifi never finishes
# coming up, and the only way out is a factory restore. The cost of being
# wrong here is the whole board, which is what justifies a guard at all.
#
# HOW IT BREAKS THE LOOP
# ----------------------
# `check` increments a counter on disk and fails once it exceeds MAX, which
# stops the bind from running at all. `confirm` clears it, and is run by
# unoq-usb-confirm.service a couple of minutes into a boot that actually got
# as far as having a network. So:
#
#   healthy boot -> bind, counter 1, ... confirm clears it -> next boot starts at 0
#   brownout loop -> bind, counter 1, reset, 2, reset, 3, reset, 4 > MAX
#                    -> bind refuses -> board boots clean -> wifi -> ssh
#
# The board gives up the gadget and keeps the network, which is the right way
# round: the gadget is the thing being experimented with, the network is how
# you get in to fix it.
#
# This is the same shape as the MCU's FOTA rollback - try the new thing, and
# fall back automatically if it does not confirm itself - applied to the half
# of the board that can also strand you.
#
# RECOVER by hand after the guard has tripped:
#
#   sudo rm -f /var/lib/unoq/usb-bind-attempts
#   sudo systemctl start unoq-usb-bind.service
set -uo pipefail

STATE_DIR="${UNOQ_STATE_DIR:-/var/lib/unoq}"
COUNTER="$STATE_DIR/usb-bind-attempts"
MAX="${UNOQ_USB_BIND_MAX_ATTEMPTS:-3}"

log() {
  logger -t unoq-bind-guard "$*" 2>/dev/null
  echo "unoq-bind-guard: $*"
}

read_count() {
  local n
  n="$(cat "$COUNTER" 2>/dev/null)"
  # Anything that is not a plain number is treated as zero rather than as an
  # error: a truncated file from a reset mid-write must not be able to wedge
  # the guard permanently in either direction.
  case "$n" in
    '' | *[!0-9]*) echo 0 ;;
    *) echo "$n" ;;
  esac
}

case "${1:-}" in
  check)
    mkdir -p "$STATE_DIR" 2>/dev/null
    count="$(read_count)"
    if [ "$count" -ge "$MAX" ]; then
      log "REFUSING to bind: $count consecutive unconfirmed attempts (max $MAX)."
      log "  The board has been rebooting without ever staying up long enough"
      log "  to confirm a bind. Suspect USB power - check the cable is on a"
      log "  powered hub or PD supply, not a 0.5 A port."
      log "  Clear with: sudo rm -f $COUNTER"
      exit 1
    fi
    # Written BEFORE the bind, not after. If the bind is what kills the board
    # there is no "after" in which to record that it was tried.
    echo "$((count + 1))" >"$COUNTER" 2>/dev/null
    sync -f "$COUNTER" 2>/dev/null || sync
    log "bind attempt $((count + 1))/$MAX"
    ;;
  confirm)
    count="$(read_count)"
    if [ "$count" = "0" ]; then
      log "already confirmed"
    else
      rm -f "$COUNTER" 2>/dev/null
      log "boot confirmed healthy - bind attempt counter cleared (was $count)"
    fi
    ;;
  status)
    echo "attempts: $(read_count)/$MAX  ($COUNTER)"
    ;;
  *)
    echo "usage: $(basename "$0") {check|confirm|status}" >&2
    exit 2
    ;;
esac
exit 0
