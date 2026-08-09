#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# IP over USB, plus the fileshare drive, when the board is plugged into a PC.
#
#   sudo bash ~/hybrid/provision/60-usb-gadget.sh
#
# Idempotent, and safe to run over SSH: it does NOT change the USB role. On
# this board it cannot - dwc3 is dr_mode="otg" with no writable role switch,
# and the Type-C controller picks host or device from the CC lines. Installing
# this only arranges for a gadget to be bound IF a USB Device Controller shows
# up, which happens when you plug the USB-C port into a computer.
#
# WHAT YOU GET, once plugged into a computer
# ------------------------------------------
#   board          10.55.0.1        static
#   your computer  10.55.0.10-.100  by DHCP, no configuration needed
#   a USB drive    "UNO-Q", read-only, with the VS Code installers on it
#   the web page   http://10.55.0.1:8080/
#
# WHAT YOU GIVE UP
# ----------------
# The USB-C port is the board's only USB data port. While it is a device, it
# is not a host: anything plugged into a hub or dock on it - network dongles,
# storage, keyboards - is gone until you unplug from the computer.
#
# REVERT: systemctl disable --now unoq-usb-gadget.service &&
#         rm /etc/systemd/system/unoq-usb-gadget.service \
#            /etc/udev/rules.d/99-unoq-usb-gadget.rules &&
#         systemctl daemon-reload && udevadm control --reload
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
need_root

IMG="${UNOQ_SHARE_IMG:-$TARGET_HOME/unoq-share.img}"

step "kernel support"
for mod in libcomposite usb_f_ncm usb_f_rndis usb_f_mass_storage bridge; do
  if modprobe "$mod" 2>/dev/null; then
    skip "$mod available"
  else
    warn "$mod could not be loaded - the gadget may not come up"
  fi
done
# Loaded on demand by the gadget, but listing them here means a board that
# lacks one says so now rather than at 2am with a cable in it.
if write_file 0644 /etc/modules-load.d/unoq-usb-gadget.conf <<'MODS'; then
libcomposite
bridge
MODS
  skip "modules will load at boot"
fi

step "DHCP server"
apt_install dnsmasq-base
# The packaged dnsmasq service is not used: usb-net-up.sh runs its own
# instance bound to br-usb only, so it cannot interfere with anything else on
# the box - or be interfered with.
if unit_exists dnsmasq.service; then
  disable_unit dnsmasq.service
else
  skip "no packaged dnsmasq service to disable"
fi

step "link configuration"
# Written once and then left alone, unlike everything else here. It is the one
# file on this board a person is expected to edit, and a provisioning run that
# reset the mode every time would undo the change on the next bootstrap - most
# likely while the board is running on the very link the setting controls.
# REVERT: rm /etc/default/unoq-usb  (the scripts default to server mode anyway)
if [ -f /etc/default/unoq-usb ]; then
  skip "/etc/default/unoq-usb exists (mode: $(sed -n 's/^UNOQ_USB_MODE=//p' /etc/default/unoq-usb | tail -1))"
else
  write_file 0644 /etc/default/unoq-usb <<'CONF'
# Which end of the USB link runs DHCP.
# Read by unoq-usb-gadget.service and unoq-usb-bind.service.
#
#   server   the board is 10.55.0.1 and leases the computer an address.
#            Right when the computer is just something you reach the board from.
#
#   client   the board asks the computer for an address instead. Use this when
#            the computer is SHARING ITS INTERNET: Windows ICS pins its shared
#            adapter to 192.168.137.1 and runs its own DHCP server, and will
#            never take a lease from us. Also right for macOS Internet Sharing.
#            10.55.0.1 stays on the bridge either way.
#
# After changing:  sudo systemctl restart unoq-usb-gadget
UNOQ_USB_MODE=server

# Uncomment to stop the gadget ever touching the board's default route. It is
# installed at metric 700, so it already loses to wifi (600) and ethernet (100).
#UNOQ_USB_DEFAULT_ROUTE=0

# If wifi has been turned off (usb/wifi.sh off) and the USB link has produced no
# route to the internet this many seconds after boot, turn the radio back on and
# leave it on. Set UNOQ_UPLINK_FALLBACK=0 to let the board sit there with no
# uplink instead.
#UNOQ_UPLINK_FALLBACK=1
#UNOQ_UPLINK_DEADLINE=240
CONF
fi

step "fileshare image"
if [ -f "$IMG" ]; then
  skip "$IMG present ($(du -h "$IMG" | cut -f1) on disk)"
else
  warn "$IMG missing - the drive will appear empty."
  warn "  build it:  sudo bash $PROJECT/share/fetch-vscode.sh"
  warn "             sudo bash $PROJECT/share/build-image.sh"
fi

step "adbd"
# adbd's ExecStartPost binds its OWN gadget to the first free UDC. With this
# installed there would be two gadgets racing for one controller, and which
# one wins is a coin toss. adb over USB and this are mutually exclusive; the
# network link is the more useful of the two, and adb still works over TCP.
# REVERT: systemctl enable --now adbd
if unit_exists adbd.service; then
  disable_unit adbd.service
  skip "adb over TCP still works:  adb connect 10.55.0.1:5555"
else
  skip "adbd not present"
fi

step "udev rule"
if write_file 0644 /etc/udev/rules.d/99-unoq-usb-gadget.rules \
  <"$PROJECT/usb/99-unoq-usb-gadget.rules"; then
  udevadm control --reload-rules
  did "udev rules reloaded"
fi

step "systemd units"
install_unit "$PROJECT/usb/unoq-usb-gadget.service"
# The bind half is a separate unit on purpose - see the comment in it.
install_unit "$PROJECT/usb/unoq-usb-bind.service"
# And the confirm half, which is what makes the bind guard's counter mean
# "boots survived" rather than just "boots attempted". Without this enabled the
# guard would trip after three normal boots and refuse to bind ever again.
install_unit "$PROJECT/usb/unoq-usb-confirm.service"
# The other half of turning wifi off: the guard covers a bind that kills the
# board, this covers a bind that works and still leaves it with no way out.
install_unit "$PROJECT/usb/unoq-uplink-fallback.service"
# The status LEDs. Installed here because everything they report - the gadget
# being bound, a computer answering, the guard having tripped - is defined by
# the scripts in usb/, and because the moment they matter is a moment nobody can
# log in to start them.
install_unit "$PROJECT/usb/unoq-leds.service"
# enable, but do not --now start it blindly: starting is harmless (no UDC
# means it builds the definition and exits) and proves the scripts run.
if systemctl is-enabled --quiet unoq-usb-gadget.service 2>/dev/null; then
  skip "already enabled"
else
  systemctl enable unoq-usb-gadget.service >/dev/null 2>&1 ||
    fail "could not enable unoq-usb-gadget.service"
  did "enabled at boot"
fi
# Enabled separately and unconditionally: a board that already had the gadget
# enabled from before the guard existed still needs the confirm unit turning
# on, or its counter would climb every boot until the guard refused to bind.
if systemctl is-enabled --quiet unoq-usb-confirm.service 2>/dev/null; then
  skip "bind guard confirm already enabled"
else
  systemctl enable unoq-usb-confirm.service >/dev/null 2>&1 ||
    fail "could not enable unoq-usb-confirm.service"
  did "bind guard confirm enabled at boot"
fi
# Harmless on a board whose wifi is on - it looks, sees a radio already up, and
# exits - so it is enabled unconditionally rather than only when someone has
# turned wifi off. The moment it is needed is the moment nobody can enable it.
if systemctl is-enabled --quiet unoq-uplink-fallback.service 2>/dev/null; then
  skip "wifi fallback already enabled"
else
  systemctl enable unoq-uplink-fallback.service >/dev/null 2>&1 ||
    fail "could not enable unoq-uplink-fallback.service"
  did "wifi fallback enabled at boot"
fi
# Started as well as enabled: unlike the gadget units there is nothing to wait
# for, and a board that has just been provisioned should light up now rather
# than at the next reboot.
if systemctl is-enabled --quiet unoq-leds.service 2>/dev/null &&
  systemctl is-active --quiet unoq-leds.service; then
  skip "status LEDs already running"
else
  systemctl enable --now unoq-leds.service >/dev/null 2>&1 ||
    warn "could not start unoq-leds.service - check: journalctl -u unoq-leds"
  did "status LEDs enabled and started ($PROJECT/usb/leds.sh explain)"
fi

step "build the gadget now (no bind without a host)"
if systemctl restart unoq-usb-gadget.service 2>/dev/null; then
  did "service ran"
else
  warn "service failed - check: journalctl -u unoq-usb-gadget -n 40"
fi

step "verify"
G=/sys/kernel/config/usb_gadget/unoq
names() { # basenames of a glob, space separated, "<none>" if it matched nothing
  local out=""
  for p in "$@"; do
    [ -e "$p" ] || continue
    out="$out $(basename "$p")"
  done
  echo "${out# }"
}
if [ -d "$G" ]; then
  skip "gadget defined, configs: $(names "$G"/configs/*)"
  skip "functions: $(names "$G"/functions/*)"
  attached="$(cat "$G/functions/mass_storage.0/lun.0/file" 2>/dev/null)"
  skip "drive backing file: ${attached:-<none>}"
else
  warn "no gadget at $G - check the journal"
fi
udcs="$(names /sys/class/udc/*)"
if [ -n "$udcs" ]; then
  skip "UDC present: $udcs - bound"
else
  skip "no UDC: the board is not plugged into a computer yet (expected)"
fi

summary
cat <<EOF

Plug the board's USB-C port into your computer, then on the computer:

  ssh $TARGET_USER@10.55.0.1
  http://10.55.0.1:8080/            learning content + installers
  the "UNO-Q" drive                 same files, no network needed

Your computer configures itself by DHCP. If you would rather set it by hand,
give its USB ethernet interface 10.55.0.2/24 - no gateway, no DNS.
EOF
