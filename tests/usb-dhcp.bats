#!/usr/bin/env bats
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
#
# usb/usb-dhcp.sh is udhcpc's handler script. These tests cover one thing it
# does: the remembered address in /var/lib/unoq/usb-dhcp-last, which is what
# `udhcpc --request` asks for at startup so the numeric address survives a
# reboot.
#
# The interesting case is the cable moving between a PC and a Mac. Windows ICS
# shares from 192.168.137.0/24 and macOS Internet Sharing from 192.168.2.0/24,
# and neither will lease an address out of the other's subnet - so the first
# request after a swap is refused. The running client recovers by itself, which
# is why this was easy to miss: the file is read ONCE, at startup, so a refusal
# left on disk is one the board repeats after every reboot until a lease
# happens to overwrite it.
#
# Three tests, because "a NAK deletes a file" is satisfiable by deleting the
# file at every opportunity. What makes it a behaviour is that `bound` writes
# it and `deconfig` - which runs on every stop and every start - leaves it
# alone.

setup() {
  load helpers/stub
  stub_setup

  PROJECT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DHCP="$PROJECT/usb/usb-dhcp.sh"

  stub logger
  stub ip

  # Everything the script touches outside its own directory, redirected into
  # the test's tmpdir: the remembered address, the volatile lease state, and
  # resolv.conf. UNOQ_AUTOIPD points at a file that does not exist, so the
  # link-local helpers take their "not installed" path rather than reaching for
  # a real daemon.
  export UNOQ_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export UNOQ_USB_DHCP_STATE="$BATS_TEST_TMPDIR/lease.state"
  export UNOQ_RESOLV_CONF="$BATS_TEST_TMPDIR/resolv.conf"
  export UNOQ_AUTOIPD="$BATS_TEST_TMPDIR/no-such-autoipd"
  export interface=br-usb

  LAST="$UNOQ_STATE_DIR/usb-dhcp-last"
  mkdir -p "$UNOQ_STATE_DIR"
  : >"$UNOQ_RESOLV_CONF"
}

@test "a lease is written down for the next startup to ask for" {
  run env ip=192.168.137.42 subnet=255.255.255.0 "$DHCP" bound
  [ "$status" -eq 0 ]
  [ "$(cat "$LAST")" = "192.168.137.42" ]
}

@test "a NAK forgets the remembered address" {
  # The Windows address, refused by the Mac the cable was just moved to.
  echo "192.168.137.42" >"$LAST"
  run "$DHCP" nak
  [ "$status" -eq 0 ]
  [ ! -e "$LAST" ]
}

@test "the NAK log names the address it gave up on" {
  # Not decoration. A board that quietly stopped asking for the address someone
  # had written on a sticky note should say so where `app logs` will show it.
  echo "192.168.137.42" >"$LAST"
  run "$DHCP" nak
  [[ "$output" == *"192.168.137.42"* ]]
}

@test "a NAK with nothing remembered is still a clean exit" {
  # The ordinary case on a board that has never held a lease on this link.
  [ ! -e "$LAST" ]
  run "$DHCP" nak
  [ "$status" -eq 0 ]
}

@test "deconfig keeps the remembered address" {
  # deconfig runs at every udhcpc startup and every shutdown. If it forgot the
  # address, the sticky address would never survive the one thing it exists to
  # survive - a reboot.
  echo "192.168.137.42" >"$LAST"
  run "$DHCP" deconfig
  [ "$status" -eq 0 ]
  [ "$(cat "$LAST")" = "192.168.137.42" ]
}

@test "a fresh lease after the refusal is the one remembered" {
  # The whole sequence: Windows address on disk, cable moved to a Mac, its
  # server refuses, its lease lands. What is left is the Mac's address, with no
  # trace of the PC's.
  echo "192.168.137.42" >"$LAST"
  run "$DHCP" nak
  [ "$status" -eq 0 ]
  run env ip=192.168.2.7 subnet=255.255.255.0 "$DHCP" bound
  [ "$status" -eq 0 ]
  [ "$(cat "$LAST")" = "192.168.2.7" ]
}
