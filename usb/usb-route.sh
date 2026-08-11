#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Default route out through whichever computer is on the other end of the USB
# cable. Called by usb-dhcp.sh on a lease event, not by you.
#
#   usb/usb-route.sh <add|old|del> <gateway-ip>
#
# WHY A LEASE HOOK
# ----------------
# The host's gateway address is not knowable in advance. Windows ICS uses
# 192.168.137.1, macOS Internet Sharing 192.168.2.1, a Linux host whatever it
# was configured with - and which computer is on the other end of the cable can
# change between one plug-in and the next. The lease is the only moment that
# address is authoritative, so the route is set from there rather than polled
# for or hardcoded.
#
# It took a <mac> second argument until recently, because it was a dnsmasq
# --dhcp-script back when the board could also be the DHCP server on this link.
# It has one caller now.
#
# WHAT THIS DOES NOT DO
# ---------------------
# It does not make the internet work by itself. It points the board's default
# route at the host; the host still has to be routing and NAT-ing for packets
# to go anywhere. On Windows that is Internet Connection Sharing, or
# New-NetNat from an elevated PowerShell. Without it you get a route and
# silence, which is why the metric below matters.
#
# THE METRIC
# ----------
# 700, chosen to lose to everything NetworkManager installs for a real link.
# The intent has always been that this route is a fallback of last resort: if
# the board has any genuine route to the internet, that keeps winning and this
# one sits unused. Only when the USB cable is the board's sole link should it
# take over. A USB gadget that silently stole the default route from a working
# network would be a nasty thing to debug.
#
# This was 500, which did not achieve that, and the reasoning is worth keeping
# because it is an easy mistake to repeat. NetworkManager does not give every
# connection the ~100 you see on ethernet - the default metric is per device
# type, and for wifi it is 600:
#
#   default via 192.168.0.1 dev wlan0 proto dhcp src 192.168.0.172 metric 600
#
# So on a board whose only uplink is wifi - which is the normal case for this
# one, and the configuration you are most likely to be developing over - 500
# beat the real connection instead of losing to it. Plugging the board into a
# computer would hand it the default route. SSH survived (that is a connected
# route on the LAN, not the default), so it looked fine, while every outbound
# connection went to a host that was almost certainly not NAT-ing: apt, git and
# anything else needing the internet simply stopped, with no error pointing
# anywhere near USB.
#
# Higher metric = lower priority, so 700 loses to wifi's 600 and to ethernet's
# 100, while still beating the 1024 the kernel hands an unconfigured route. If
# you would rather it never touched the default route at all, the escape hatch
# is UNOQ_USB_DEFAULT_ROUTE=0.
set -uo pipefail

ACTION="${1:-}"
HOST_IP="${2:-}"

BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"
METRIC="${UNOQ_USB_ROUTE_METRIC:-700}"
ENABLED="${UNOQ_USB_DEFAULT_ROUTE:-1}"

[ "$ENABLED" = "1" ] || exit 0

case "$ACTION" in
  add | old | del) ;;
  *) exit 0 ;;
esac

# An address is required, and it must look like one - this runs as root with a
# value that came off the wire, so it goes nowhere near a shell unquoted.
case "$HOST_IP" in
  [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
  *) exit 0 ;;
esac

# Only act while the bridge is actually there; on shutdown it may already be
# gone and every ip(8) call would just print noise into the journal.
ip link show "$BRIDGE" >/dev/null 2>&1 || exit 0

log() {
  logger -t unoq-usb-route "$*"
  echo "unoq-usb-route: $*"
}

case "$ACTION" in
  add | old)
    # `replace`, not `add`: the host renewing its lease, or coming back with
    # the same address, must not fail on "file exists" and must not stack a
    # second identical route.
    if ip route replace default via "$HOST_IP" dev "$BRIDGE" metric "$METRIC" 2>/dev/null; then
      log "default route -> $HOST_IP dev $BRIDGE metric $METRIC"
    else
      log "could not set default route via $HOST_IP"
    fi
    ;;
  del)
    # Only our own route, matched on all three fields, so a LAN default route
    # someone else installed is never touched.
    if ip route del default via "$HOST_IP" dev "$BRIDGE" metric "$METRIC" 2>/dev/null; then
      log "default route via $HOST_IP withdrawn (lease released)"
    fi
    ;;
esac
exit 0
