#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# status/leds.sh decides what the two Linux-driven LEDs say about the board. It is
# the only thing that still reports when the network, the gadget and the shell
# have all gone - so a wrong colour here is worse than a dark board: it is a
# board confidently lying about its own health.
#
# The whole script is drivable from the environment already - the sysfs root,
# the gadget directory and the bridge name are all overridable - so these tests
# build a fake /sys/class/leds in a temporary directory and read the brightness
# files back afterwards. Nothing touches the real LEDs.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LEDSH="$PROJECT/status/leds.sh"

  export UNOQ_LED_DIR="$BATS_TEST_TMPDIR/leds"
  export UNOQ_GADGET_DIR="$BATS_TEST_TMPDIR/gadget"
  export UNOQ_USB_BRIDGE=br-test

  # A fake sysfs. Every channel starts with no trigger claimed and the light
  # off, which is what the board looks like after `leds.sh off`.
  for ch in unoq:user-red1 unoq:user-green1 unoq:user-blue1 \
    unoq:panic-red2 unoq:wlan-green2 unoq:bt-blue2; do
    mkdir -p "$UNOQ_LED_DIR/$ch"
    echo 0 >"$UNOQ_LED_DIR/$ch/brightness"
    echo "[none] mmc0 disk-activity" >"$UNOQ_LED_DIR/$ch/trigger"
  done

  mkdir -p "$UNOQ_GADGET_DIR"
  echo "4e00000.usb" >"$UNOQ_GADGET_DIR/UDC" # bound, by default

  # Healthy board by default; each test breaks one thing.
  stub ping 0                    # the internet is reachable
  stub systemctl 0 ""            # no failed units
  # `ip link show` must succeed AND `ip -4 route show default` must print
  # something, or usb_link_up() cannot tell "a computer is there" from
  # "nothing is there".
  stub_body ip <<'SH'
case "$1 $2" in
  "link show") exit 0 ;;
esac
case "$*" in
  *"route show default"*) echo "default via 192.168.137.1 dev br-test metric 700" ;;
esac
exit 0
SH
  stub logger
}

# colour_of LED1|LED2 -> the single colour lit, or "off", or "mixed:r,g,b"
colour_of() {
  local -n chans="$1"
  local r g b
  r="$(cat "$UNOQ_LED_DIR/${chans[0]}/brightness")"
  g="$(cat "$UNOQ_LED_DIR/${chans[1]}/brightness")"
  b="$(cat "$UNOQ_LED_DIR/${chans[2]}/brightness")"
  case "$r$g$b" in
    100) echo red ;;
    010) echo green ;;
    001) echo blue ;;
    110) echo yellow ;;
    000) echo off ;;
    *) echo "mixed:$r,$g,$b" ;;
  esac
}
LED1=(unoq:user-red1 unoq:user-green1 unoq:user-blue1)
LED2=(unoq:panic-red2 unoq:wlan-green2 unoq:bt-blue2)

# A bind guard that answers `status` however the test wants. leds.sh used to
# look for it beside itself, which made this untestable; UNOQ_BIND_GUARD was
# added for that, and is also what lets the two scripts stop being neighbours.
guard_says() {
  cat >"$BATS_TEST_TMPDIR/guard" <<EOF
#!/bin/bash
echo "$1"
EOF
  chmod +x "$BATS_TEST_TMPDIR/guard"
  export UNOQ_BIND_GUARD="$BATS_TEST_TMPDIR/guard"
}

# --- LED 1: can this board reach anything? ---------------------------------

@test "internet reachable is green" {
  run "$LEDSH" once
  [ "$status" -eq 0 ]
  [ "$(colour_of LED1)" = green ]
}

@test "no internet but a computer on the cable is blue, not red" {
  # The distinction that earns the third colour: "plugged in, host not sharing"
  # and "nothing there at all" are different problems with different fixes.
  stub ping 1
  run "$LEDSH" once
  [ "$(colour_of LED1)" = blue ]
}

@test "no internet and no gadget bound is red" {
  stub ping 1
  : >"$UNOQ_GADGET_DIR/UDC" # built but not bound
  run "$LEDSH" once
  [ "$(colour_of LED1)" = red ]
}

@test "no internet and no bridge is red even with the gadget bound" {
  stub ping 1
  stub ip 1 # `ip link show br-test` fails
  run "$LEDSH" once
  [ "$(colour_of LED1)" = red ]
}

# --- LED 2: does anything need a human? ------------------------------------

@test "a healthy board is green, not dark" {
  # Green is load-bearing. A dark LED cannot distinguish "nothing is wrong" from
  # "the thing that checks whether anything is wrong is not running".
  run "$LEDSH" once
  [ "$(colour_of LED2)" = green ]
}

@test "a failed systemd unit turns it red" {
  stub systemctl 0 "does-not-exist.service loaded failed failed Nonsense"
  run "$LEDSH" once
  [ "$(colour_of LED2)" = red ]
}

@test "a tripped bind guard turns it red" {
  guard_says "attempts: 3/3  (/var/lib/unoq/usb-bind-attempts)"
  run "$LEDSH" once
  [ "$(colour_of LED2)" = red ]
}

@test "a guard below its limit leaves it green" {
  guard_says "attempts: 2/3  (/var/lib/unoq/usb-bind-attempts)"
  run "$LEDSH" once
  [ "$(colour_of LED2)" = green ]
}

# --- refusing to fight the kernel ------------------------------------------

@test "a channel already owned by a kernel trigger is left alone" {
  # Writing to a triggered channel succeeds and is overwritten a moment later,
  # which reads as broken code rather than as a conflict. Refusing is clearer.
  echo "none [mmc0] disk-activity" >"$UNOQ_LED_DIR/unoq:user-green1/trigger"
  run "$LEDSH" once
  [ "$(cat "$UNOQ_LED_DIR/unoq:user-green1/brightness")" = 0 ]
}

@test "off turns every channel off" {
  run "$LEDSH" once
  [ "$(colour_of LED1)" = green ]
  run "$LEDSH" off
  [ "$status" -eq 0 ]
  [ "$(colour_of LED1)" = off ]
  [ "$(colour_of LED2)" = off ]
}

# --- the interface ----------------------------------------------------------

@test "explain works without root and without touching the LEDs" {
  run "$LEDSH" explain
  [ "$status" -eq 0 ]
  [[ "$output" == *"LED 1"* ]]
  [[ "$output" == *"LED 2"* ]]
  [ "$(colour_of LED1)" = off ]
}

@test "an unknown verb is a usage error" {
  run "$LEDSH" frobnicate
  [ "$status" -eq 2 ]
}
