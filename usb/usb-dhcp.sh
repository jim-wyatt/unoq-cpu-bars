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
# WHY THE BOARD IS THE CLIENT
# ---------------------------
# Because the two hosts we do not control are not negotiable. Windows Internet
# Connection Sharing pins its shared adapter to 192.168.137.1/24 and runs its own
# DHCP server there; macOS Internet Sharing does the same at 192.168.2.1. Neither
# will ever ask us for a lease. A board that wants internet over the cable has to
# take the address, the gateway and the DNS servers from whatever the host is
# running, so that is what this does. Nothing here is hardcoded to Microsoft's
# numbering: the same code works for macOS, for a Linux host running its own
# dnsmasq, and for whatever ICS is changed to next.
#
# WHEN NOBODY IS SERVING - LINK-LOCAL
# -----------------------------------
# `leasefail` is not an error to log and forget. It is the cable plugged into a
# computer that is not sharing anything, and it used to be the case a static
# 10.55.0.1 on the bridge existed to cover.
#
# It is covered by IPv4 link-local instead, which is the same answer every
# desktop OS already reaches on its own: Windows, macOS and Linux all self-assign
# 169.254.x.y when their DHCP finds nothing. So both ends land on the same /16 by
# themselves, with no host configuration at all - where 10.55.0.1 needed a static
# route typed in at the other end, elevated, before anything could reach the
# board.
#
# avahi makes it typeable. <hostname>.local resolves to whichever address this
# link ended up with, leased or link-local, on all three OSes with nothing
# installed. That only works because there is now exactly ONE address on this
# bridge: avahi advertises every address an interface has, and the old pair meant
# two A records with the host free to pick the one it had no route to.
#
# So: link-local goes on when DHCP gives up, and comes off the moment a real
# lease arrives. Never both.
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
# udhcpc exports this; default it once here rather than at every use, because
# under `set -u` an unset $interface is a crash rather than a fallback, and the
# link-local helpers below are reached on the path where udhcpc is least happy.
interface="${interface:-${UNOQ_USB_BRIDGE:-br-usb}}"
# An absolute path, not `command -v`. avahi-autoipd installs to /usr/sbin, which
# is not on an ordinary user's PATH, so `command -v avahi-autoipd` reports it
# missing on a board where it is installed and working. status.sh keeps its own
# copy of this line for the same reason, and it is the one that matters most:
# that script is meant to run without root, where /usr/sbin is absent from PATH.
AUTOIPD="${UNOQ_AUTOIPD:-/usr/sbin/avahi-autoipd}"

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

# --- link-local, for when no DHCP server answers ----------------------------
#
# avahi-autoipd rather than picking a 169.254 address ourselves, because RFC 3927
# is more than choosing one: it probes with ARP before claiming, defends the
# claim afterwards, and gives up and re-picks on a conflict. A board that skipped
# that would occasionally collide with the very host it is plugged into - the
# host self-assigns from the same /16 for the same reason, at the same moment,
# on the same wire.
#
# It brings its own address up and takes it down again through the packaged
# action script, so there is nothing to clean up here beyond stopping it.
autoipd_start() {
  [ -x "$AUTOIPD" ] || {
    log "no avahi-autoipd - this link has no address until the host serves DHCP"
    return 1
  }
  # --check first: this runs again on every leasefail, and a second daemon would
  # be a second claimant defending the same address against the first.
  if "$AUTOIPD" --check "$interface" 2>/dev/null; then
    return 0
  fi
  # No --force-bind, deliberately. Its default is to refuse when the interface
  # already holds a routable address, which is exactly the check we want: if a
  # lease landed between the failure and here, the lease wins.
  if "$AUTOIPD" --daemonize --syslog "$interface" 2>/dev/null; then
    log "no DHCP server on $interface - claiming a link-local address instead"
  else
    log "could not start avahi-autoipd on $interface"
    return 1
  fi
}

autoipd_stop() {
  [ -x "$AUTOIPD" ] || return 0
  "$AUTOIPD" --check "$interface" 2>/dev/null || return 0
  # --kill runs the action script on the way out, so the 169.254 address is
  # removed rather than left alongside the lease we just took. Two addresses on
  # this bridge is the state mDNS cannot give a single answer for.
  "$AUTOIPD" --kill "$interface" 2>/dev/null &&
    log "link-local released on $interface - a real lease supersedes it"
}

# --- lease events ----------------------------------------------------------

case "${1:-}" in
  deconfig)
    # udhcpc's "I am starting, or I have lost the lease". Remove only the
    # address we ourselves put on, which is why it was written down: flushing
    # the interface would take a link-local address with it, and that is the
    # one keeping the board reachable in exactly this situation.
    ip link set "$interface" up 2>/dev/null
    if [ -r "$STATE" ]; then
      read -r old_cidr old_router <"$STATE"
      [ -n "${old_cidr:-}" ] && ip addr del "$old_cidr" dev "$interface" 2>/dev/null
      [ -n "${old_router:-}" ] && "$HERE/usb-route.sh" del "$old_router" >/dev/null 2>&1
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
    # Before the address goes on, not after: for the moment in between there
    # would be a lease and a link-local address on one bridge, which is the
    # two-A-record state that makes <hostname>.local a coin flip.
    autoipd_stop
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

    # The route, and therefore the metric, is usb-route.sh's business - one
    # place that decides how the gadget ranks against a real link.
    if [ "$ENABLED" = "1" ] && is_ipv4 "${router:-}"; then
      "$HERE/usb-route.sh" "$([ "$1" = bound ] && echo add || echo old)" "$router" >/dev/null
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
    # Normal while the cable is out or the host has not brought its shared
    # adapter up yet, and udhcpc keeps retrying by itself either way. What is
    # NOT normal is leaving the board with no address while it retries, so this
    # is where link-local comes up. If a lease turns up later, `bound` takes it
    # straight back down again.
    log "no DHCP offer on $interface yet - is the host sharing its connection?"
    autoipd_start
    ;;
esac
exit 0
