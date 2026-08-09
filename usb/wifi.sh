#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Turn the board's wifi radio off, once the USB link can carry the traffic.
#
#   ~/two-computers-one-board/usb/wifi.sh status      # what is on, and what would be left
#   sudo ~/two-computers-one-board/usb/wifi.sh off    # checks the USB link first, then off
#   sudo ~/two-computers-one-board/usb/wifi.sh on     # back on, whatever state anything is in
#
# WHY
# ---
# As a device the board is a power sink, and a host port with no PD contract
# gives it USB default current - not much for four cores plus an MCU. The wifi
# radio is the largest thing on the board that can simply be switched off, and
# on a board that is plugged into a computer anyway, it is also the most
# redundant: the NCM link is already there and is faster.
#
# WHY THIS IS NOT JUST `nmcli radio wifi off`
# -------------------------------------------
# Because that command, run at the wrong moment, is how you lose the board.
#
# You are almost certainly typing it over the wifi it is about to turn off. If
# the USB link is not carrying traffic - the gadget did not bind, the cable is
# charge-only, the host is not sharing its connection, the board is in server
# mode in front of a host that pins its own address - then the moment the radio
# goes down there is no path to the board at all. Not slow: absent. The next
# step is a serial console or a factory restore.
#
# So `off` refuses unless it can see the link actually working, and says which
# check failed. --force skips the checks for when you know better (a serial
# console open, or you are not on wifi in the first place).
#
# WHAT `off` DOES BEYOND THE RADIO
# --------------------------------
# It kicks the DHCP client into renewing. NetworkManager owns /etc/resolv.conf
# on this image and rewrites it when the radio goes down, taking the board's
# nameservers with it; usb-dhcp.sh puts them back, but only on a lease event.
# Without the kick the board would route fine and resolve nothing until the
# lease next renewed, which on a Windows ICS lease is days away. That symptom -
# ping 8.8.8.8 works, apt does not - is a genuinely annoying one to chase.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"
METRIC="${UNOQ_USB_ROUTE_METRIC:-700}"
UDHCPC_PID=/run/unoq-usb-udhcpc.pid
DNSMASQ_PID=/run/unoq-usb-dnsmasq.pid
G="${UNOQ_GADGET_DIR:-/sys/kernel/config/usb_gadget/unoq}"

# pid_is <pidfile> <acceptable comm>... - is that daemon actually running?
#
# /proc rather than `kill -0`, because kill -0 against a root-owned process
# fails with EPERM for an ordinary user: it would report a perfectly healthy
# daemon as stopped in exactly the read-only paths that are meant to need no
# privileges. The comm check is what makes a stale pidfile safe - a recycled pid
# is not far-fetched on a board that reboots as often as this one - and it is
# also why this does not go looking for command lines with pgrep, which matched
# udhcpc's own --interface=br-usb when it went hunting for dnsmasq's.
pid_is() {
  local pidfile="$1" pid comm want
  shift
  pid="$(cat "$pidfile" 2>/dev/null)"
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || return 1
  for want in "$@"; do
    [ "$comm" = "$want" ] && return 0
  done
  return 1
}

FORCE=0
ACTION=""
for arg in "$@"; do
  case "$arg" in
    off | on | status | check) ACTION="$arg" ;;
    -f | --force) FORCE=1 ;;
    *)
      echo "usage: $(basename "$0") {status|check|off|on} [--force]" >&2
      exit 2
      ;;
  esac
done
[ -n "$ACTION" ] || {
  echo "usage: $(basename "$0") {status|check|off|on} [--force]" >&2
  exit 2
}

say() { printf '  %s\n' "$*"; }
die() {
  printf 'wifi.sh: %s\n' "$*" >&2
  exit 1
}
need_root() { [ "$(id -u)" = 0 ] || die "run this with sudo"; }

command -v nmcli >/dev/null 2>&1 || die "nmcli not found - this board is not on NetworkManager"

# The default route via the bridge is the single best proof that the USB link is
# not merely up but usable: usb-route.sh only installs it from a real lease, in
# either mode, and only when there is a gateway on the other end.
usb_gateway() {
  ip -4 route show default dev "$BRIDGE" 2>/dev/null |
    sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1
}

# In server mode there is no gateway at all - the board offers the host none -
# so the thing to prove is simply that a host took a lease and is still there.
usb_peer() {
  local gw
  gw="$(usb_gateway)"
  if [ -n "$gw" ]; then
    echo "$gw"
    return 0
  fi
  awk '{print $3}' /run/unoq-usb-dnsmasq.leases 2>/dev/null | head -1
}

# Whether the computer on the other end is actually there.
#
# Not by ping alone: Windows blocks ICMP to its ICS adapter by default, so the
# gateway that is routing the board's traffic perfectly well does not answer,
# and refusing on that basis would refuse in the normal case. The ping is worth
# trying because it succeeds outright on macOS and Linux hosts - and when it
# fails it has still forced ARP, which is the check that matters. A resolved
# neighbour means frames cross the wire and get answered, which is exactly the
# property "will I still be able to reach this board" depends on.
peer_reachable() {
  local peer="$1" entry
  ping -c1 -W2 -I "$BRIDGE" "$peer" >/dev/null 2>&1 && return 0
  entry="$(ip neigh show "$peer" dev "$BRIDGE" 2>/dev/null)"
  case "$entry" in
    *FAILED* | *INCOMPLETE*) return 1 ;;
    *lladdr*) return 0 ;;
    *) return 1 ;;
  esac
}

val() { printf '  %-22s %s\n' "$1" "${2:-<none>}"; }

show_status() {
  printf '\n== wifi ==\n'
  val "radio" "$(nmcli radio wifi 2>/dev/null)"
  val "wlan0" "$(ip -br addr show wlan0 2>/dev/null | tr -s ' ')"
  printf '\n== what would be left ==\n'
  val "gadget bound to" "$(cat "$G/UDC" 2>/dev/null)"
  val "$BRIDGE" "$(ip -br addr show "$BRIDGE" 2>/dev/null | tr -s ' ')"
  val "dhcp mode" "$(pid_mode)"
  val "gateway over USB" "$(usb_gateway)"
  val "nameservers" "$(sed -n 's/^nameserver //p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
  printf '\n== default routes (lowest metric wins) ==\n'
  ip route show default | sed 's/^/  /' || val "routes"
}

# Everything that has to be true before the radio can go off, and the address
# to reconnect on if it does. Each failure names the thing to fix, because
# "refused" on its own would only send you to usb/status.sh anyway.
preflight() {
  local peer
  [ -n "$(cat "$G/UDC" 2>/dev/null)" ] ||
    die "the gadget is not bound to a UDC - nothing would be left. Check usb/status.sh, then --force if you are sure."
  ip link show "$BRIDGE" >/dev/null 2>&1 ||
    die "$BRIDGE does not exist - run usb/usb-net-up.sh first."
  peer="$(usb_peer)"
  [ -n "$peer" ] ||
    die "no computer on $BRIDGE: no gateway in client mode, and no DHCP lease
       in server mode. Plug the cable in, check usb/status.sh, and if the
       host is sharing its connection make sure the mode is client."
  peer_reachable "$peer" ||
    die "$peer is on the routing table but does not answer on $BRIDGE - the
       link is configured and not working, which is the one state where
       turning the radio off strands the board. --force to override."
  say "gadget bound, and $peer answers on $BRIDGE"

  # Internet is a warning, not a refusal. There are good reasons to want the
  # board reachable from one computer without wanting a route to the world, and
  # that choice is not this script's to make.
  if ping -c1 -W3 -I "$BRIDGE" "${UNOQ_PROBE_IP:-1.1.1.1}" >/dev/null 2>&1; then
    say "the host is NAT-ing: the board keeps its internet over USB"
  else
    say "WARNING: no internet through $peer. The board will be reachable from"
    say "         that computer but will not reach anything else. On Windows"
    say "         that means ICS is off, or shared to the wrong adapter."
    say "         apt and git will stop working."
  fi

  # The last thing printed before the radio goes, because it is the thing you
  # will need thirty seconds later and cannot look up once wifi is down.
  say ""
  say "RECONNECT ON:  $(reconnect_address)"
}

# What to ssh to afterwards.
#
# The leased address, and deliberately not the mDNS name. avahi advertises every
# address on this bridge, which in client mode is both the leased one and
# 10.55.0.1 - so a host resolving <hostname>.local gets two A records and picks
# one, and half the time it picks the address it has no route to. Printing a
# name that works half the time, at the moment the radio is about to go off, is
# worse than printing nothing.
reconnect_address() {
  local leased
  leased="$(ip -4 -br addr show "$BRIDGE" 2>/dev/null |
    tr ' ' '\n' | grep -v '^10\.55\.0\.1/' | grep '/' | head -1)"
  leased="${leased%%/*}"
  if [ -n "$leased" ]; then
    printf '%s@%s' "${SUDO_USER:-$USER}" "$leased"
  else
    printf '%s@10.55.0.1  - server mode, the host reaches the board here' "${SUDO_USER:-$USER}"
  fi
}

pid_mode() {
  if pid_is "$UDHCPC_PID" busybox udhcpc; then
    echo "client (udhcpc, the host leases us an address)"
  elif pid_is "$DNSMASQ_PID" dnsmasq; then
    echo "server (dnsmasq, we lease the host an address)"
  else
    echo "<neither running>"
  fi
}

case "$ACTION" in
  status)
    show_status
    ;;

  on)
    need_root
    nmcli radio wifi on >/dev/null 2>&1 || die "could not enable the radio"
    echo "wifi radio on. NetworkManager will reconnect and take back the default"
    echo "route (metric 600) and /etc/resolv.conf; the USB route stays as the"
    echo "fallback at metric $METRIC."
    ;;

  check)
    preflight
    echo
    echo "Safe to turn the radio off:  sudo $HERE/wifi.sh off"
    ;;

  off)
    need_root
    if [ "$FORCE" = 0 ]; then
      preflight
    else
      say "checks skipped (--force)"
    fi

    nmcli radio wifi off >/dev/null 2>&1 || die "could not disable the radio"
    say "wifi radio off (persists across reboot)"

    # NM has just rewritten resolv.conf without our nameservers. A renew makes
    # usb-dhcp.sh reassert address, route and DNS now rather than in days.
    if pid_is "$UDHCPC_PID" busybox udhcpc; then
      kill -USR1 "$(cat "$UDHCPC_PID")" 2>/dev/null &&
        say "asked udhcpc to renew, so DNS comes back on this link"
      sleep 2
    fi

    show_status
    cat <<EOF

The gadget is now the only way in. If it stops binding, the bind guard turns
this radio back on by itself after $((${UNOQ_USB_BIND_MAX_ATTEMPTS:-3})) unconfirmed boots - see bind-guard.sh.
To undo by hand:  sudo $HERE/wifi.sh on
EOF
    ;;
esac
