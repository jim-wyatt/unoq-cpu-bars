#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Give the USB gadget link an address, and hand one to the host over DHCP.
#
#   sudo ~/hybrid/usb/usb-net-up.sh
#
# Idempotent.
#
# ADDRESSING
# ----------
#   board   10.55.0.1        always, static
#   host    10.55.0.10-.100  by DHCP, automatically
#
# The host needs NO configuration: every desktop OS asks for DHCP on a new
# wired interface by default. 10.55.0.0/24 is deliberately obscure - a board
# handing out 192.168.0.x or 10.0.0.x on a cable would collide with the
# network the laptop is already on and break its real connection.
#
# WHY A BRIDGE
# ------------
# The gadget offers two configurations, RNDIS and NCM, and the host picks one.
# Each has its own netdev on this side, and we cannot know in advance which
# one carries traffic. Bridging both onto br-usb puts the address in one place
# regardless of which the host chose, instead of racing to detect it.
#
# This deliberately does NOT provide a default route or NAT. The board is the
# thing you are connecting TO; silently becoming a laptop's default gateway is
# how you break its internet and spend an afternoon finding out why.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"
ADDR="${UNOQ_USB_ADDR:-10.55.0.1}"
PREFIX="${UNOQ_USB_PREFIX:-24}"
RANGE_LO="${UNOQ_USB_RANGE_LO:-10.55.0.10}"
RANGE_HI="${UNOQ_USB_RANGE_HI:-10.55.0.100}"
LEASE="${UNOQ_USB_LEASE:-12h}"
PIDFILE=/run/unoq-usb-dnsmasq.pid
LEASEFILE=/run/unoq-usb-dnsmasq.leases

log() { echo "unoq-usb-net: $*"; }
die() {
  echo "unoq-usb-net: $*" >&2
  exit 1
}

[ "$(id -u)" = 0 ] || die "must run as root"

# --- bridge ----------------------------------------------------------------

modprobe bridge 2>/dev/null
if ip link show "$BRIDGE" >/dev/null 2>&1; then
  log "$BRIDGE exists"
else
  ip link add name "$BRIDGE" type bridge || die "could not create $BRIDGE"
  # No STP: there is exactly one path here, and STP's forwarding delay would
  # make the host wait ~30s for DHCP on every plug-in.
  ip link set "$BRIDGE" type bridge stp_state 0 forward_delay 0
  log "created $BRIDGE"
fi

ip addr show dev "$BRIDGE" | grep -q "inet $ADDR/$PREFIX" ||
  ip addr replace "$ADDR/$PREFIX" dev "$BRIDGE"
ip link set "$BRIDGE" up

# --- enslave whatever the gadget created -----------------------------------

# usb0/usb1 are what rndis.usb0 and ncm.usb0 register as. Both are enslaved;
# only the one in the configuration the host selected will ever pass a frame.
enslaved=0
for iface in /sys/class/net/usb*; do
  [ -e "$iface" ] || continue
  name="$(basename "$iface")"
  master="$(basename "$(readlink -f "$iface/master" 2>/dev/null || echo none)")"
  if [ "$master" = "$BRIDGE" ]; then
    log "$name already on $BRIDGE"
    enslaved=$((enslaved + 1))
    continue
  fi
  # A gadget netdev cannot hold an address of its own while bridged.
  ip addr flush dev "$name" 2>/dev/null
  if ip link set "$name" master "$BRIDGE" 2>/dev/null; then
    ip link set "$name" up
    log "$name -> $BRIDGE"
    enslaved=$((enslaved + 1))
  else
    log "WARNING: could not enslave $name"
  fi
done

if [ "$enslaved" = 0 ]; then
  log "no gadget interfaces yet - the bridge is up and waiting"
fi

# --- DHCP for the host -----------------------------------------------------

command -v dnsmasq >/dev/null 2>&1 || die "dnsmasq not installed"

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  log "dnsmasq already running (pid $(cat "$PIDFILE"))"
else
  rm -f "$PIDFILE"
  # Our own instance, on this interface only. --bind-dynamic rather than
  # --bind-interfaces, for two reasons that both matter here:
  #
  #   1. SAFETY. This board normally also sits on a real network. A DHCP
  #      server that answered on that interface would be a rogue DHCP server
  #      on someone's home or office LAN, handing out addresses on a subnet
  #      that does not exist. --bind-dynamic binds per-interface rather than
  #      to 0.0.0.0, so it physically cannot reply on the wrong one.
  #   2. It copes with br-usb appearing, disappearing and regaining carrier as
  #      cables are plugged and unplugged, which --bind-interfaces does not:
  #      that one resolves interfaces once, at startup.
  #
  # --port=0 disables the DNS half entirely; this exists to answer one DHCP
  # request and nothing else. dhcp-option 3 and 6 are deliberately empty - no
  # router, no DNS - so the board never becomes the laptop's default gateway.
  # --dhcp-script runs usb-route.sh on every lease event, which is where the
  # board's default route out through the host gets set: the host's address is
  # whatever we just leased it, and the lease is the only moment that is
  # authoritative. dnsmasq also replays existing leases as `old` at startup, so
  # restarting it re-asserts the route rather than waiting for a renewal.
  dnsmasq \
    --conf-file=/dev/null \
    --pid-file="$PIDFILE" \
    --dhcp-leasefile="$LEASEFILE" \
    --dhcp-script="$HERE/usb-route.sh" \
    --interface="$BRIDGE" \
    --bind-dynamic \
    --except-interface=lo \
    --no-resolv \
    --no-hosts \
    --port=0 \
    --dhcp-range="$RANGE_LO,$RANGE_HI,$LEASE" \
    --dhcp-option=3 \
    --dhcp-option=6 \
    --dhcp-authoritative ||
    die "dnsmasq failed to start"
  log "dnsmasq serving $RANGE_LO-$RANGE_HI on $BRIDGE"
fi

log "board reachable at $ADDR (ssh, and http://$ADDR:8080/)"
