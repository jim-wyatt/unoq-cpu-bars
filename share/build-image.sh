#!/bin/bash
# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
# Build the FAT32 image the board hands out as a USB drive.
#
#   sudo bash ~/hybrid/share/build-image.sh            # create/refresh
#   sudo bash ~/hybrid/share/build-image.sh --rw       # leave it writable
#
# Idempotent: an image of the right size is reused and its contents synced.
#
# THE IMAGE IS THE ONLY COPY
# --------------------------
# It would be simpler to keep a staging directory and copy it into an image,
# but that means storing ~2 GB of VS Code installers twice on a board with a
# 10 GB rootfs. Instead the image IS the store: it is mounted read-only at
# $MOUNT for the web server to serve, and the same file is what
# usb_f_mass_storage exports. One copy, one source of truth, no chance of the
# USB drive and the web page disagreeing about what is on the board.
#
# FAT32 because it is the one filesystem Windows, macOS and Linux all mount
# with no driver and no prompting. Its 4 GB per-file limit is not a constraint
# here - the largest installer is ~530 MB.
#
# WHY READ-ONLY
# -------------
# The host and the board would otherwise both be writing the same blocks with
# neither one's page cache knowing about the other, which corrupts the
# filesystem in short order. The gadget exports it with ro=1 and the board
# mounts it ro; --rw is for updating content and is not how it normally runs.
set -uo pipefail
# shellcheck source=provision/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd)/provision/lib.sh"
need_root

# On the big partition: /home/arduino is its own 18 GB filesystem here, while
# / has under 5 GB spare once Zephyr is built.
IMG="${UNOQ_SHARE_IMG:-$TARGET_HOME/unoq-share.img}"
MOUNT="${UNOQ_SHARE_MOUNT:-/srv/unoq-share}"
SIZE_MB="${UNOQ_SHARE_SIZE_MB:-2600}"
STAGING="${UNOQ_SHARE:-/var/lib/unoq-share}"
LEAVE_RW=0
[ "${1:-}" = "--rw" ] && LEAVE_RW=1

step "tools"
apt_install dosfstools

step "image file"
mkdir -p "$(dirname "$IMG")"
if [ -f "$IMG" ]; then
  have_mb=$(($(stat -c %s "$IMG") / 1024 / 1024))
  skip "$IMG exists (${have_mb} MB)"
else
  # Sparse: the file reads as $SIZE_MB but only occupies the blocks actually
  # written, so an image sized for future content costs nothing until used.
  truncate -s "${SIZE_MB}M" "$IMG" || fail "could not create $IMG"
  chown "$TARGET_USER" "$IMG"
  did "created $IMG (${SIZE_MB} MB, sparse)"
fi

step "filesystem"
if blkid "$IMG" 2>/dev/null | grep -q 'TYPE="vfat"'; then
  skip "already FAT32"
else
  # -F 32 forces FAT32 (mkfs would pick FAT16 for smaller images), -n the
  # volume label the host shows in its file manager.
  mkfs.vfat -F 32 -n "UNO-Q" "$IMG" >/dev/null || fail "mkfs.vfat failed"
  did "formatted FAT32, label UNO-Q"
fi

step "mount"
mkdir -p "$MOUNT"
if mountpoint -q "$MOUNT"; then
  mount -o remount,rw "$MOUNT" 2>/dev/null || {
    umount "$MOUNT" && mount -o loop,rw "$IMG" "$MOUNT"
  } || fail "could not remount $MOUNT rw"
  skip "$MOUNT remounted rw for the update"
else
  # utf8 so accented filenames survive; the mask bits make everything readable
  # to the web server without making it executable.
  mount -o loop,rw,umask=0022,utf8 "$IMG" "$MOUNT" || fail "could not mount $IMG"
  did "mounted $IMG at $MOUNT"
fi

step "content"
# Learning content ships in the repo, so it is versioned with everything else.
if [ -d "$PROJECT/share/learn" ]; then
  rsync -a --delete "$PROJECT/share/learn/" "$MOUNT/" 2>/dev/null ||
    cp -r "$PROJECT/share/learn/." "$MOUNT/"
  did "learning content synced from share/learn/"
else
  warn "$PROJECT/share/learn missing - no landing page on the drive"
fi

# Installers are downloaded, not in the repo (they are Microsoft's, and ~2 GB).
if [ -d "$STAGING/vscode" ] && compgen -G "$STAGING/vscode/*" >/dev/null; then
  mkdir -p "$MOUNT/vscode"
  # Move rather than copy: the staging copy is on the small rootfs and there is
  # not room for both. After this the image is the only copy, as intended.
  if mv "$STAGING"/vscode/* "$MOUNT/vscode/" 2>/dev/null; then
    rmdir "$STAGING/vscode" "$STAGING" 2>/dev/null
    did "installers moved into the image ($(du -sh "$MOUNT/vscode" | cut -f1))"
  else
    cp -n "$STAGING"/vscode/* "$MOUNT/vscode/" && did "installers copied into the image"
  fi
elif [ -d "$MOUNT/vscode" ] && compgen -G "$MOUNT/vscode/*" >/dev/null; then
  skip "installers already in the image ($(du -sh "$MOUNT/vscode" | cut -f1))"
else
  warn "no installers found - run share/fetch-vscode.sh first"
fi

sync

step "remount read-only"
if [ "$LEAVE_RW" = 1 ]; then
  warn "left mounted rw (--rw). Do NOT attach the USB gadget while it is."
else
  mount -o remount,ro "$MOUNT" || fail "could not remount $MOUNT read-only"
  did "$MOUNT is read-only"
fi

step "result"
skip "image:   $IMG ($(du -h --apparent-size "$IMG" | cut -f1) apparent, $(du -h "$IMG" | cut -f1) on disk)"
skip "mounted: $MOUNT"
skip "free:    $(df -h "$MOUNT" | awk 'NR==2 {print $4}') left in the image"

summary
