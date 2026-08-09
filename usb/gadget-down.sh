#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Tear the USB gadget down: unbind, stop DHCP, remove the configfs tree.
#
#   sudo ~/two-computers-one-board/usb/gadget-down.sh            # unbind, keep the definition
#   sudo ~/two-computers-one-board/usb/gadget-down.sh --purge    # and delete it from configfs
#
# Idempotent. This is the revert path for provision/60-usb-gadget.sh, and the
# thing to run before rebuilding the fileshare image - the host must not be
# holding the image open while share/build-image.sh remounts it read-write.
#
# configfs will not let you rmdir a directory that is still referenced, so the
# order below matters: unbind the UDC, unlink functions from configs, remove
# strings, then configs, then functions, then the gadget.
set -uo pipefail

CONFIGFS=/sys/kernel/config/usb_gadget
G="$CONFIGFS/unoq"
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"
PIDFILE=/run/unoq-usb-dnsmasq.pid
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

log() { echo "unoq-gadget: $*"; }

[ "$(id -u)" = 0 ] || {
  echo "must run as root" >&2
  exit 1
}

# --- unbind ----------------------------------------------------------------

if [ -d "$G" ]; then
  if [ -s "$G/UDC" ]; then
    echo "" >"$G/UDC" 2>/dev/null && log "unbound from the UDC"
  else
    log "already unbound"
  fi
else
  log "no gadget at $G"
fi

# --- DHCP ------------------------------------------------------------------

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  kill "$(cat "$PIDFILE")" && rm -f "$PIDFILE"
  log "dnsmasq stopped"
fi

# --- bridge ----------------------------------------------------------------

if ip link show "$BRIDGE" >/dev/null 2>&1; then
  ip link set "$BRIDGE" down
  ip link delete "$BRIDGE" type bridge
  log "$BRIDGE removed"
fi

# --- configfs --------------------------------------------------------------

if [ "$PURGE" = 1 ] && [ -d "$G" ]; then
  # Links first: a config holding a function symlink cannot be removed, and a
  # function still linked from any config cannot be removed either.
  rm -f "$G/os_desc/c.1" 2>/dev/null
  for cfg in "$G"/configs/*; do
    [ -d "$cfg" ] || continue
    find "$cfg" -maxdepth 1 -type l -exec rm -f {} + 2>/dev/null
    rmdir "$cfg"/strings/* 2>/dev/null
    rmdir "$cfg" 2>/dev/null
  done
  for fn in "$G"/functions/*; do
    [ -d "$fn" ] || continue
    rmdir "$fn" 2>/dev/null || log "WARNING: could not remove $(basename "$fn")"
  done
  rmdir "$G"/strings/* 2>/dev/null
  if rmdir "$G" 2>/dev/null; then
    log "gadget definition removed"
  else
    log "WARNING: $G is still referenced - reboot to clear it"
  fi
fi

log "done"
