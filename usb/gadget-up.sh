#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Build and bind the composite USB gadget: network + the fileshare drive.
#
#   sudo ~/hybrid/usb/gadget-up.sh          # build, and bind if a UDC exists
#   sudo ~/hybrid/usb/gadget-up.sh --build  # build only, never bind
#
# Idempotent: an existing gadget is left alone and re-bound if it came unbound.
#
# WHEN THIS RUNS
# --------------
# Not at a fixed point in boot. This board's dwc3 is `dr_mode = "otg"` and has
# no writable role switch - the Type-C controller decides host vs device from
# the CC lines when you plug a cable in. So a USB Device Controller only exists
# while the board is plugged into a computer, and this script is driven by a
# udev rule that fires when one appears. See usb/99-unoq-usb-gadget.rules.
#
# WHAT THE HOST SEES
# ------------------
#   config 1  NCM    + UNO-Q drive   <- Windows 11, macOS, Linux all bind this
#   config 2  RNDIS  + UNO-Q drive   <- fallback for pre-1903 Windows
#
# Two configurations rather than two functions in one: a host must not bind two
# network interfaces to the same device, and each OS picks the config whose
# network function it actually supports. The drive is in both, so it is there
# either way.
set -uo pipefail

CONFIGFS=/sys/kernel/config/usb_gadget
G="$CONFIGFS/unoq"
IMG="${UNOQ_SHARE_IMG:-/home/arduino/unoq-share.img}"
BUILD_ONLY=0
[ "${1:-}" = "--build" ] && BUILD_ONLY=1

log() { echo "unoq-gadget: $*"; }
die() {
  echo "unoq-gadget: $*" >&2
  exit 1
}

[ "$(id -u)" = 0 ] || die "must run as root"

# --- prerequisites ---------------------------------------------------------

modprobe libcomposite 2>/dev/null
[ -d "$CONFIGFS" ] || die "no $CONFIGFS - is CONFIG_USB_CONFIGFS enabled?"

# --- build -----------------------------------------------------------------

if [ -d "$G" ]; then
  log "gadget already defined at $G"
else
  mkdir -p "$G" || die "could not create $G"

  # 0x1d6b/0x0104 is the Linux Foundation "Multifunction Composite Gadget"
  # id, which is what a configfs gadget is supposed to use. Borrowing
  # Arduino's VID for a device Arduino did not build would be wrong, and
  # would collide with their own udev rules.
  echo 0x1d6b >"$G/idVendor"
  echo 0x0104 >"$G/idProduct"
  echo 0x0200 >"$G/bcdUSB" # USB 2.0
  echo 0x0100 >"$G/bcdDevice"

  mkdir -p "$G/strings/0x409"
  echo "Arduino" >"$G/strings/0x409/manufacturer"
  echo "UNO Q hybrid dev board" >"$G/strings/0x409/product"
  # A stable serial matters more than it looks: Windows keys its per-adapter
  # network profile off it, so a serial that changes every boot leaves the
  # user with "Ethernet 2, 3, 4..." and a fresh unconfigured adapter each time.
  SERIAL="$(cat /sys/devices/soc0/serial_number 2>/dev/null ||
    sed 's/-//g' /etc/machine-id 2>/dev/null | cut -c1-16)"
  echo "${SERIAL:-0000000000000000}" >"$G/strings/0x409/serialnumber"

  # MACs derived from machine-id, for the same reason: a random MAC per boot
  # makes every host treat the board as a brand-new network.
  MAC_BASE="$(sed 's/-//g' /etc/machine-id 2>/dev/null | cut -c1-10)"
  MAC_BASE="${MAC_BASE:-0123456789}"
  fmt_mac() { # <local-bit-prefix> - build a locally-administered unicast MAC
    printf '%s:%s:%s:%s:%s:%s' "$1" \
      "${MAC_BASE:0:2}" "${MAC_BASE:2:2}" "${MAC_BASE:4:2}" \
      "${MAC_BASE:6:2}" "${MAC_BASE:8:2}"
  }
  DEV_MAC="$(fmt_mac 42)"  # the board's end
  HOST_MAC="$(fmt_mac 46)" # the host's end

  # --- functions ---
  for fn in ncm.usb0 rndis.usb0; do
    mkdir -p "$G/functions/$fn"
    echo "$DEV_MAC" >"$G/functions/$fn/dev_addr" 2>/dev/null
    echo "$HOST_MAC" >"$G/functions/$fn/host_addr" 2>/dev/null
  done

  # Windows will not bind RNDIS without these: they are what makes it load
  # its built-in driver instead of asking for a disk.
  echo "RNDIS" >"$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id"
  echo "5162001" >"$G/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id"

  mkdir -p "$G/functions/mass_storage.0"
  if [ -f "$IMG" ]; then
    # ro=1: the host and the board would otherwise both be writing the same
    # blocks with neither page cache aware of the other, which destroys a FAT
    # filesystem quickly. removable=1 so the host offers "eject" rather than
    # treating it as a fixed disk it should chkdsk.
    echo 1 >"$G/functions/mass_storage.0/lun.0/removable"
    echo 1 >"$G/functions/mass_storage.0/lun.0/ro"
    echo 0 >"$G/functions/mass_storage.0/lun.0/cdrom"
    echo "$IMG" >"$G/functions/mass_storage.0/lun.0/file" ||
      log "WARNING: could not attach $IMG - the drive will show as empty"
    echo "UNO-Q Share" >"$G/functions/mass_storage.0/lun.0/inquiry_string" 2>/dev/null
  else
    log "WARNING: $IMG missing - build it with share/build-image.sh"
  fi

  # --- configurations ---
  #
  # A host enumerates configuration 1 and stops, so whatever goes in c.1 is
  # what almost every computer will actually use. c.2 exists as a fallback you
  # can select by hand.
  #
  # NCM is the default primary, and RNDIS is NOT, which is the opposite of most
  # gadget recipes. Those recipes predate two changes at Microsoft's end:
  #
  #   - Windows ships a native NCM class driver (UsbNcm.sys) from Windows 10
  #     version 1903 onwards, so NCM needs no driver and no INF.
  #   - RNDIS is deprecated, and the driver has been removed from recent
  #     Windows 11 builds. A Windows 11 host offered RNDIS in c.1 binds nothing
  #     for networking - you get the drive and no IP, with no obvious error.
  #
  # macOS (NCM since Catalina) and Linux both prefer NCM too, so NCM-first is
  # the right default for every host that is not genuinely old.
  #
  # Set UNOQ_GADGET_PRIMARY=rndis for a pre-1903 Windows host.
  PRIMARY="${UNOQ_GADGET_PRIMARY:-ncm}"
  case "$PRIMARY" in
    ncm)
      C1_FN=ncm.usb0 C1_NAME="NCM + fileshare"
      C2_FN=rndis.usb0 C2_NAME="RNDIS + fileshare"
      ;;
    rndis)
      C1_FN=rndis.usb0 C1_NAME="RNDIS + fileshare"
      C2_FN=ncm.usb0 C2_NAME="NCM + fileshare"
      ;;
    *) die "UNOQ_GADGET_PRIMARY must be ncm or rndis, not '$PRIMARY'" ;;
  esac

  mkdir -p "$G/configs/c.1/strings/0x409"
  echo "$C1_NAME" >"$G/configs/c.1/strings/0x409/configuration"
  echo 250 >"$G/configs/c.1/MaxPower" # mA, i.e. 500mA
  ln -sf "$G/functions/$C1_FN" "$G/configs/c.1/"
  ln -sf "$G/functions/mass_storage.0" "$G/configs/c.1/"

  mkdir -p "$G/configs/c.2/strings/0x409"
  echo "$C2_NAME" >"$G/configs/c.2/strings/0x409/configuration"
  echo 250 >"$G/configs/c.2/MaxPower"
  ln -sf "$G/functions/$C2_FN" "$G/configs/c.2/"
  ln -sf "$G/functions/mass_storage.0" "$G/configs/c.2/"

  # The Microsoft OS descriptors carry the RNDIS compatible ID, so they belong
  # on whichever configuration actually holds rndis. They are harmless when
  # that is the fallback config - Windows simply never asks.
  echo 1 >"$G/os_desc/use"
  echo 0xcd >"$G/os_desc/b_vendor_code"
  echo MSFT100 >"$G/os_desc/qw_sign"
  if [ "$PRIMARY" = rndis ]; then
    ln -sf "$G/configs/c.1" "$G/os_desc/" 2>/dev/null
  else
    ln -sf "$G/configs/c.2" "$G/os_desc/" 2>/dev/null
  fi

  log "gadget built (c.1=$C1_FN, c.2=$C2_FN, both + mass_storage)"
fi

[ "$BUILD_ONLY" = 1 ] && {
  log "built only, not binding (--build)"
  exit 0
}

# --- bind ------------------------------------------------------------------

# Glob rather than `ls`: there is normally exactly one UDC, and the first is
# the one dwc3 registered.
UDC_NAME=""
for udc in /sys/class/udc/*; do
  [ -e "$udc" ] || break
  UDC_NAME="$(basename "$udc")"
  break
done
if [ -z "$UDC_NAME" ]; then
  # Not an error. On this board a UDC only exists while a host is plugged into
  # the USB-C port; the udev rule will call us again when one appears.
  log "no UDC present - the board is not plugged into a computer. Nothing bound."
  exit 0
fi

CURRENT="$(tr -d ' \n' <"$G/UDC" 2>/dev/null)"
if [ "$CURRENT" = "$UDC_NAME" ]; then
  log "already bound to $UDC_NAME"
else
  echo "$UDC_NAME" >"$G/UDC" || die "could not bind to $UDC_NAME"
  log "bound to $UDC_NAME"
fi
