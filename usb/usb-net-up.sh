#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Give the USB gadget link an address, and hand one to the host over DHCP.
#
#   sudo ~/two-computers-one-board/usb/usb-net-up.sh
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
# WHICH END RUNS DHCP
# -------------------
# The above is UNOQ_USB_MODE=server, the default, and it is right whenever the
# computer is simply something you want to reach the board from.
#
# UNOQ_USB_MODE=client turns it around: no dnsmasq, and the board asks the
# computer for an address instead. That is the mode for a host that is sharing
# its internet, which is what you want once the board's wifi is off to save the
# power budget. Windows ICS and macOS Internet Sharing both pin their shared
# adapter to a fixed address and run their own DHCP server on it; they will
# never take a lease from us, so a board sitting at 10.55.0.1 in front of a host
# at 192.168.137.1 is two addresses on one wire with no route between them.
#
#   UNOQ_USB_MODE=server   board 10.55.0.1 -> leases the host an address
#   UNOQ_USB_MODE=client   board asks the host -> takes address, gateway, DNS
#
# 10.55.0.1 stays on the bridge in BOTH modes. In client mode it is the address
# the board still answers on when the host's DHCP server is not running, which
# with wifi off is the difference between a fixable board and a serial console.
# See usb-dhcp.sh.
#
# Set it in the unit's environment (see 60-usb-gadget.sh) or for one run:
#
#   sudo UNOQ_USB_MODE=client ~/two-computers-one-board/usb/usb-net-up.sh
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
MODE="${UNOQ_USB_MODE:-server}"
PIDFILE=/run/unoq-usb-dnsmasq.pid
LEASEFILE=/run/unoq-usb-dnsmasq.leases
UDHCPC_PID=/run/unoq-usb-udhcpc.pid

log() { echo "unoq-usb-net: $*"; }
die() {
  echo "unoq-usb-net: $*" >&2
  exit 1
}

[ "$(id -u)" = 0 ] || die "must run as root"

case "$MODE" in
  server | client) ;;
  *) die "UNOQ_USB_MODE must be 'server' or 'client', not '$MODE'" ;;
esac

# --- one DHCP daemon at a time ---------------------------------------------
#
# Switching modes has to stop the other one, and not merely decline to start
# it. Both would otherwise sit on the same bridge: our dnsmasq answering the
# board's own udhcpc with a 10.55.0.x lease while the host's server offers a
# real one, and the board taking whichever reply arrives first. That failure
# comes and goes with timing, which is the worst kind to be left with.
pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

stop_dnsmasq() {
  pid_alive "$PIDFILE" || {
    rm -f "$PIDFILE"
    return 0
  }
  kill "$(cat "$PIDFILE")" 2>/dev/null
  rm -f "$PIDFILE"
  log "stopped dnsmasq (mode is $MODE)"
}

stop_udhcpc() {
  pid_alive "$UDHCPC_PID" || {
    rm -f "$UDHCPC_PID"
    return 0
  }
  kill "$(cat "$UDHCPC_PID")" 2>/dev/null
  rm -f "$UDHCPC_PID"
  # udhcpc does not run its script on SIGTERM, so the leased address and the
  # route it installed would outlive it. Run the teardown by hand, which also
  # hands /etc/resolv.conf back to NetworkManager.
  interface="$BRIDGE" "$HERE/usb-dhcp.sh" deconfig >/dev/null 2>&1
  log "stopped udhcpc (mode is $MODE)"
}

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

# --- DHCP, in whichever direction this board is configured for -------------

if [ "$MODE" = client ]; then
  stop_dnsmasq

  # busybox rather than a package: this image ships no dhclient, dhcpcd or
  # standalone udhcpc, and busybox is already here. It is also about the right
  # size of tool for the job - one interface, one lease, a handler script.
  command -v busybox >/dev/null 2>&1 || die "busybox not installed (needed for udhcpc)"

  if pid_alive "$UDHCPC_PID"; then
    log "udhcpc already running (pid $(cat "$UDHCPC_PID"))"
  else
    rm -f "$UDHCPC_PID"
    # Ask for the address we had last time. A DHCP server is free to refuse,
    # and this changes nothing if it does - but Windows ICS and macOS both
    # honour it in practice, which turns "ssh to whatever it got this time"
    # into an address you can write down. It matters more here than it would
    # elsewhere: with wifi off there is no second way in to go and look.
    REQUEST=()
    LAST="${UNOQ_STATE_DIR:-/var/lib/unoq}/usb-dhcp-last"
    if [ -r "$LAST" ]; then
      read -r last_ip <"$LAST"
      case "$last_ip" in
        '' | *[!0-9.]*) ;;
        *.*.*.*)
          REQUEST=(--request="$last_ip")
          log "asking for $last_ip again (last address on this link)"
          ;;
      esac
    fi
    # -b: go to the background and keep trying rather than exiting, because at
    #     boot the host's shared adapter is usually not up yet. There is no
    #     failure here worth giving up on - the cable is either plugged in now
    #     or it will be.
    # -R: release the lease on a clean exit, so the host does not hold an
    #     address for a board that has gone away.
    # -t/-T: five tries three seconds apart before backing off, which keeps a
    #     normal plug-in feeling immediate without hammering a host that is
    #     not sharing anything.
    if busybox udhcpc \
      --interface="$BRIDGE" \
      --script="$HERE/usb-dhcp.sh" \
      --pidfile="$UDHCPC_PID" \
      -x "hostname:$(hostname)" \
      "${REQUEST[@]+"${REQUEST[@]}"}" \
      --background --release \
      --retries=5 --timeout=3 >/dev/null 2>&1; then
      log "udhcpc asking for an address on $BRIDGE (host is the DHCP server)"
    else
      die "udhcpc failed to start on $BRIDGE"
    fi
  fi

  log "board reachable at $ADDR, and at whatever the host leases it"
  exit 0
fi

stop_udhcpc

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
