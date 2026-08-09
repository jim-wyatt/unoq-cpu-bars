#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# usb/usb-route.sh is a dnsmasq lease hook. It runs as root, with an address
# that came off the wire, and it decides whether to move the board's DEFAULT
# ROUTE - which is the setting most able to break a machine remotely while
# leaving it looking fine.
#
# It has broken one already. The metric was 500, which BEAT NetworkManager's
# 600 for wifi, so plugging the board into a computer silently handed that
# computer the default route. SSH survived (a connected route on the LAN, not
# the default), so nothing looked wrong, while apt, git and every other
# outbound connection went to a host that was not NAT-ing.
#
# The metric test below is that bug, written down.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ROUTE="$PROJECT/usb/usb-route.sh"

  stub logger
  # `ip link show br-usb` is the "is the bridge still there" probe; everything
  # else is the action under test.
  stub_body ip <<'SH'
exit 0
SH
}

# The hook's argv, as dnsmasq calls it: <action> <mac> <ip> [hostname]
lease() { run "$ROUTE" "$1" 02:00:00:00:00:01 "${2-}" "${3-}"; }

@test "a new lease points the default route at the host that issued it" {
  lease add 192.168.137.1
  [ "$status" -eq 0 ]
  ran "ip route replace default via 192.168.137.1 dev br-usb metric 700"
}

@test "the metric is 700, so a real uplink keeps winning" {
  # 700 loses to wifi (600) and ethernet (100) and beats the kernel's 1024.
  # If this number ever drops below 600 again, the board will quietly route
  # the internet down a USB cable to a machine that may not be forwarding.
  lease add 192.168.137.1
  ran_like 'ip route replace default via [0-9.]+ dev br-usb metric 700$'
}

@test "dnsmasq replaying an existing lease re-asserts the route" {
  # `old` is what dnsmasq emits for leases it already knew about when it
  # starts. Treating it as an event is what makes a dnsmasq restart restore the
  # route without waiting for a renewal.
  lease old 192.168.137.1
  [ "$status" -eq 0 ]
  ran "ip route replace default via 192.168.137.1 dev br-usb metric 700"
}

@test "replace, not add, so a renewing host does not stack routes or fail" {
  lease add 192.168.137.1
  ! ran_like 'ip route add default'
}

@test "a released lease withdraws only our own route" {
  # Matched on via, dev AND metric together, so a default route someone else
  # installed is never removed.
  lease del 192.168.137.1
  [ "$status" -eq 0 ]
  ran "ip route del default via 192.168.137.1 dev br-usb metric 700"
}

@test "the metric can be overridden" {
  export UNOQ_USB_ROUTE_METRIC=900
  lease add 192.168.137.1
  ran "ip route replace default via 192.168.137.1 dev br-usb metric 900"
}

@test "the bridge name can be overridden" {
  export UNOQ_USB_BRIDGE=br-test
  lease add 192.168.137.1
  ran "ip route replace default via 192.168.137.1 dev br-test metric 700"
}

# --- the escape hatch -------------------------------------------------------

@test "UNOQ_USB_DEFAULT_ROUTE=0 means the route is never touched" {
  # The documented way to say "give me the link, keep my routing". If this
  # regresses, the setting silently stops working, which is worse than not
  # offering it.
  export UNOQ_USB_DEFAULT_ROUTE=0
  lease add 192.168.137.1
  [ "$status" -eq 0 ]
  never_ran ip
}

@test "the escape hatch also covers lease release" {
  export UNOQ_USB_DEFAULT_ROUTE=0
  lease del 192.168.137.1
  never_ran ip
}

# --- events and inputs that must be ignored ---------------------------------

@test "dnsmasq events we do not care about are ignored" {
  # dnsmasq calls the same script for tftp and arp-* events. Acting on those
  # would mean running ip(8) with an argument that is not an address at all.
  for action in tftp arp-add arp-del init ""; do
    : >"$STUB_LOG"
    lease "$action" 192.168.137.1
    [ "$status" -eq 0 ]
    never_ran ip
  done
}

@test "a missing address is ignored rather than passed to ip" {
  lease add
  [ "$status" -eq 0 ]
  never_ran ip
}

@test "an address-shaped check rejects obvious rubbish" {
  for bad in "hello" "-Version" "../etc/passwd" ";reboot"; do
    : >"$STUB_LOG"
    lease add "$bad"
    [ "$status" -eq 0 ]
    never_ran ip
  done
}

@test "nothing runs when the bridge has already gone" {
  # On shutdown the bridge may be torn down before the lease is released. Every
  # ip(8) call would then just print failures into the journal.
  stub_body ip <<'SH'
case "$1 $2" in "link show") exit 1 ;; esac
exit 0
SH
  lease add 192.168.137.1
  [ "$status" -eq 0 ]
  ! ran_like 'ip route'
}

@test "a route that cannot be set is reported, not swallowed" {
  stub_body ip <<'SH'
case "$1 $2" in
  "link show") exit 0 ;;
  "route replace") exit 2 ;;
esac
exit 0
SH
  lease add 192.168.137.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not set default route"* ]]
}
