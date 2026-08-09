#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Take an address from the computer on the other end of the USB cable. Called
# by udhcpc, not by you.
#
#   busybox udhcpc -i br-usb -s /home/arduino/two-computers-one-board/usb/usb-dhcp.sh
#   argv: <deconfig|bound|renew|nak|leasefail>
#   env:  $interface $ip $subnet $router $dns $lease
#
# WHY THE BOARD WOULD EVER BE A DHCP CLIENT
# -----------------------------------------
# usb-net-up.sh's normal mode has this the other way round: the board is
# 10.55.0.1, runs dnsmasq, and hands the computer an address. That is right when
# the computer is a plain host you want to reach the board from.
#
# It stops working the moment the computer starts sharing its internet, which is
# exactly what you want when the board's wifi is off to save the power budget.
# Windows Internet Connection Sharing does not negotiate: it pins the shared
# adapter to 192.168.137.1/24 and runs its own DHCP server there. macOS Internet
# Sharing does the same at 192.168.2.1. Neither will ask us for a lease, so the
# board sits at 10.55.0.1 talking to a host on a different /24 - two addresses on
# one wire with no route between them, which looks exactly like a dead cable.
#
# So in client mode the board asks instead of answering, and takes the address,
# the gateway and the DNS servers from whatever the host is running. Nothing is
# hardcoded to Microsoft's numbering: the same code works for macOS, for a Linux
# host running its own dnsmasq, and for whatever ICS is changed to.
#
# THE STATIC ADDRESS STAYS
# ------------------------
# usb-net-up.sh leaves 10.55.0.1/24 on the bridge in this mode too, and this
# script only ever touches the address it was leased. That is deliberate: if the
# host's DHCP server is not running yet, or ICS is toggled off, 10.55.0.1 is the
# one address the board is guaranteed to still answer on, and one static route
# on the host side gets you back in:
#
#   route add 10.55.0.0 mask 255.255.255.0 192.168.137.1      (Windows, elevated)
#
# With wifi off that is the difference between a fixable board and a serial
# console, so it is worth the untidiness of two addresses on one bridge.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENABLED="${UNOQ_USB_DEFAULT_ROUTE:-1}"
STATE="/run/unoq-usb-dhcp.state"
# Survives a reboot, unlike the one above, and exists for one reason: so the
# board asks for the same address it had last time. "What do I ssh to?" has to
# have a durable answer on a board whose whole point is that wifi is off, and a
# lease that moves after every power cut - which on this board is every cable
# change - does not give you one. See usb-net-up.sh, which passes it to udhcpc.
LAST="${UNOQ_STATE_DIR:-/var/lib/unoq}/usb-dhcp-last"
RESOLV="${UNOQ_RESOLV_CONF:-/etc/resolv.conf}"

log() {
  logger -t unoq-usb-dhcp "$*" 2>/dev/null
  echo "unoq-usb-dhcp: $*"
}

# The lease arrives from a machine we do not control, and every value below is
# about to be handed to ip(8) as root. Anything that is not plainly an address
# is dropped rather than escaped - there is no legitimate lease that needs it.
is_ipv4() {
  case "$1" in
    '' | *[!0-9.]*) return 1 ;;
    *.*.*.*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- DNS -------------------------------------------------------------------
#
# Only when this link is actually carrying the board's traffic. NetworkManager
# owns /etc/resolv.conf on this image (dns=default, systemd-resolved is off), so
# writing it is taking something off NM - fine when the USB cable is the only
# uplink, and a regression if wifi is up, because unplugging the cable would
# then leave the board pointing at a nameserver it can no longer reach.
#
# "Actually carrying it" is decided by the routing table rather than by a flag:
# our route is metric 700 and loses to every real link (see usb-route.sh), so if
# no default route beats ours, there is no real link. That makes this
# self-correcting - turn wifi off and the next renew takes DNS over, turn it
# back on and the next one hands it back - and it is why wifi.sh kicks a renew
# rather than editing resolv.conf itself.
usb_route_is_the_default() {
  local best
  best="$(ip -4 route show default 2>/dev/null |
    sed -n 's/.*metric \([0-9]*\).*/\1/p' | sort -n | head -1)"
  [ -n "$best" ] && [ "$best" -ge "${UNOQ_USB_ROUTE_METRIC:-700}" ]
}

write_resolv() {
  local servers="$1" tmp added=0 s
  tmp="$(mktemp)" || return 1
  {
    echo "# Written by unoq usb-dhcp.sh - the USB gadget link is this board's"
    echo "# only uplink. NetworkManager takes this file back when wifi returns."
  } >"$tmp"
  for s in $servers; do
    is_ipv4 "$s" || continue
    echo "nameserver $s" >>"$tmp"
    added=$((added + 1))
  done
  # ICS proxies DNS on the gateway itself, so a lease with no option 6 is still
  # perfectly usable - fall back to the router rather than leaving no resolver.
  if [ "$added" = 0 ] && is_ipv4 "${router:-}"; then
    echo "nameserver $router" >>"$tmp"
    added=1
  fi
  if [ "$added" = 0 ]; then
    rm -f "$tmp"
    return 1
  fi
  if cmp -s "$tmp" "$RESOLV"; then
    rm -f "$tmp"
    return 0
  fi
  install -m 0644 "$tmp" "$RESOLV" && log "resolv.conf -> ${servers:-$router}"
  rm -f "$tmp"
}

# Hand the file back rather than leaving the board pointing at a gateway that
# has gone away. NM regenerates it from its own state, which is the correct
# content for whatever connections it still has - including none.
restore_resolv() {
  grep -q "^# Written by unoq usb-dhcp.sh" "$RESOLV" 2>/dev/null || return 0
  if command -v nmcli >/dev/null 2>&1 && nmcli general reload dns-rc 2>/dev/null; then
    log "resolv.conf handed back to NetworkManager"
  fi
}

# --- lease events ----------------------------------------------------------

case "${1:-}" in
  deconfig)
    # udhcpc's "I am starting, or I have lost the lease". Remove only the
    # address we ourselves put on, which is why it was written down: flushing
    # the interface here would take 10.55.0.1 with it and strand the board.
    ip link set "${interface:-br-usb}" up 2>/dev/null
    if [ -r "$STATE" ]; then
      read -r old_cidr old_router <"$STATE"
      [ -n "${old_cidr:-}" ] && ip addr del "$old_cidr" dev "$interface" 2>/dev/null
      [ -n "${old_router:-}" ] && "$HERE/usb-route.sh" del "" "$old_router" >/dev/null 2>&1
      rm -f "$STATE"
      log "lease released on $interface"
    fi
    restore_resolv
    ;;

  bound | renew)
    is_ipv4 "${ip:-}" || {
      log "ignoring lease with implausible address '${ip:-}'"
      exit 0
    }
    # busybox gives the mask as dotted quad; ip(8) wants a prefix length.
    mask="${subnet:-255.255.255.0}"
    case "$mask" in
      255.255.255.0) plen=24 ;;
      255.255.0.0) plen=16 ;;
      255.0.0.0) plen=8 ;;
      255.255.255.128) plen=25 ;;
      255.255.255.192) plen=26 ;;
      255.255.255.224) plen=27 ;;
      255.255.255.240) plen=28 ;;
      255.255.255.248) plen=29 ;;
      255.255.255.252) plen=30 ;;
      # Anything else is unusual enough on a point-to-point USB link that
      # guessing is worse than taking the common case and saying so.
      *)
        plen=24
        log "unrecognised netmask '$mask' - assuming /24"
        ;;
    esac

    # `replace`, so a renew of the same address is a no-op rather than an error.
    if ip addr replace "$ip/$plen" dev "$interface" 2>/dev/null; then
      [ "$1" = bound ] && log "$interface += $ip/$plen (leased by the host)"
    else
      log "could not set $ip/$plen on $interface"
    fi
    printf '%s %s\n' "$ip/$plen" "${router:-}" >"$STATE"
    mkdir -p "$(dirname "$LAST")" 2>/dev/null
    printf '%s\n' "$ip" >"$LAST"

    # The route, and therefore the metric, is usb-route.sh's business in both
    # modes - one place that decides how the gadget ranks against a real link.
    if [ "$ENABLED" = "1" ] && is_ipv4 "${router:-}"; then
      "$HERE/usb-route.sh" "$([ "$1" = bound ] && echo add || echo old)" "" "$router" >/dev/null
    fi

    if [ "$ENABLED" = "1" ] && usb_route_is_the_default; then
      write_resolv "${dns:-}" || log "lease carried no usable DNS server"
    else
      restore_resolv
    fi
    ;;

  nak)
    log "DHCP NAK from the host - the lease was refused"
    ;;

  leasefail)
    # Normal and uninteresting while the cable is out or the host has not
    # brought its shared adapter up yet. udhcpc keeps retrying by itself.
    log "no DHCP offer on ${interface:-br-usb} yet - is the host sharing its connection?"
    ;;
esac
exit 0
