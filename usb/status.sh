#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# The whole USB gadget picture, in one command.
#
#   ~/hybrid/usb/status.sh
#
# WHY THIS EXISTS
# ---------------
# This board is normally powered over the same cable that carries the gadget,
# so every cable change is also a power cut. You cannot watch a plug-in happen
# and you cannot keep a session open across one: whatever went wrong has always
# already finished by the time you can look. The post-mortem is the only view
# there is, so it is worth having it be one command that always prints the same
# things in the same order, rather than eight remembered ones.
#
# Everything here is read-only. It changes nothing and needs no root.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
G="${UNOQ_GADGET_DIR:-/sys/kernel/config/usb_gadget/unoq}"
BRIDGE="${UNOQ_USB_BRIDGE:-br-usb}"

hdr() { printf '\n== %s ==\n' "$*"; }
val() { printf '  %-22s %s\n' "$1" "${2:-<none>}"; }

hdr "role and power"
# The Type-C controller picks host vs device from the CC lines; software cannot
# override it. data_role is therefore the first thing to check, because in host
# mode there is no UDC and nothing else here can possibly work.
for f in data_role power_role power_operation_mode orientation; do
  [ -f "/sys/class/typec/port0/$f" ] &&
    val "$f" "$(cat "/sys/class/typec/port0/$f" 2>/dev/null)"
done
case "$(cat /sys/class/typec/port0/power_operation_mode 2>/dev/null)" in
  default)
    echo "  NOTE: 'default' means USB default current, no PD contract - not much"
    echo "        for four cores plus an MCU. Binding re-enumerates the port and"
    echo "        can brown the board out from here. Prefer a self-powered hub."
    ;;
esac

hdr "controller"
udc=""
for u in /sys/class/udc/*; do
  [ -e "$u" ] || continue
  udc="$udc $(basename "$u")"
done
udc="${udc# }"
val "UDC present" "${udc:-<none - board is not a device right now>}"
val "gadget bound to" "$(cat "$G/UDC" 2>/dev/null)"

hdr "gadget definition"
if [ -d "$G" ]; then
  for c in "$G"/configs/*/; do
    [ -d "$c" ] || continue
    fns=""
    for l in "$c"*; do
      [ -L "$l" ] && fns="$fns $(basename "$l")"
    done
    # c.1 is what almost every host actually enumerates, and it must contain
    # ncm - a Windows 11 host offered rndis here binds no network at all.
    val "$(basename "$c")" "${fns# }"
  done
  val "drive backing file" "$(cat "$G/functions/mass_storage.0/lun.0/file" 2>/dev/null)"
else
  val "definition" "<not built - is unoq-usb-gadget.service running?>"
fi

hdr "network"
val "$BRIDGE" "$(ip -br addr show "$BRIDGE" 2>/dev/null | tr -s ' ' || echo '<not created>')"
ports=""
for i in /sys/class/net/*/master; do
  [ -e "$i" ] || continue
  [ "$(basename "$(readlink -f "$i")")" = "$BRIDGE" ] &&
    ports="$ports $(basename "$(dirname "$i")")"
done
val "bridge ports" "${ports# }"
# Which end runs DHCP is the first thing to establish when the two sides cannot
# see each other: a board in server mode in front of a host that pins its own
# address (Windows ICS, macOS Internet Sharing) is two /24s on one wire, which
# looks exactly like a dead cable. See usb-net-up.sh.
# Liveness from /proc, not `kill -0`: this script is meant to run without root,
# and kill -0 against a root-owned daemon fails with EPERM for a normal user -
# it would report every one of these as stopped. The comm check also stops a
# stale pidfile with a recycled number reading as a running daemon.
pid_is() {
  local pid comm want
  pid="$(cat "$1" 2>/dev/null)"
  shift
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || return 1
  for want in "$@"; do
    [ "$comm" = "$want" ] && return 0
  done
  return 1
}
if pid_is /run/unoq-usb-udhcpc.pid busybox udhcpc; then
  val "dhcp mode" "client - udhcpc is asking the host for an address"
  val "leased address" "$(awk '{print $1}' /run/unoq-usb-dhcp.state 2>/dev/null)"
  val "gateway" "$(awk '{print $2}' /run/unoq-usb-dhcp.state 2>/dev/null)"
elif pid_is /run/unoq-usb-dnsmasq.pid dnsmasq; then
  val "dhcp mode" "server - dnsmasq is leasing the host an address"
  val "host lease" "$(awk '{print $3, $4}' /run/unoq-usb-dnsmasq.leases 2>/dev/null | tr '\n' ' ')"
else
  val "dhcp mode" "<neither dnsmasq nor udhcpc is running>"
fi
val "nameservers" "$(sed -n 's/^nameserver //p' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
val "wifi radio" "$(nmcli radio wifi 2>/dev/null)"

hdr "default routes (lowest metric wins)"
# The gadget route must LOSE to any real uplink. If a 10.55.0.x route is top of
# this list and the host is not NAT-ing, the board has no internet and the
# symptom will not look like USB.
ip route show default | sed 's/^/  /' || echo "  <none>"

hdr "bind guard"
"$HERE/bind-guard.sh" status 2>/dev/null | sed 's/^/  /' ||
  val "guard" "<bind-guard.sh not found>"

hdr "recent gadget log"
# -b covers this boot; the interesting one after an unexplained reset is
# usually `journalctl -b -1`, which the footer points at.
journalctl -b -u unoq-usb-gadget -u unoq-usb-bind -u unoq-usb-confirm \
  -t unoq-bind-guard -t unoq-usb-route -t unoq-usb-dhcp -n 15 --no-pager -o short 2>/dev/null |
  sed 's/^/  /' || echo "  <no journal access>"

cat <<EOF

If the board reset and you are looking for why, the evidence is in the
PREVIOUS boot, not this one:

  journalctl -b -1 -u unoq-usb-bind -t unoq-bind-guard
  journalctl --list-boots
EOF
