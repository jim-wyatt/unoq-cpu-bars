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
val "dnsmasq" "$(pgrep -f "interface=$BRIDGE" >/dev/null 2>&1 && echo running || echo "not running")"
val "host lease" "$(awk '{print $3, $4}' /run/unoq-usb-dnsmasq.leases 2>/dev/null | tr '\n' ' ')"

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
  -t unoq-bind-guard -t unoq-usb-route -n 15 --no-pager -o short 2>/dev/null |
  sed 's/^/  /' || echo "  <no journal access>"

cat <<EOF

If the board reset and you are looking for why, the evidence is in the
PREVIOUS boot, not this one:

  journalctl -b -1 -u unoq-usb-bind -t unoq-bind-guard
  journalctl --list-boots
EOF
