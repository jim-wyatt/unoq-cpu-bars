#!/bin/bash
# Memory optimization for a headless Arduino UNO Q used as a Linux+MCU dev board.
#
#   sudo bash ~/hybrid/optimize-board.sh
#
# sudo needs a password and this box sets `use_pty`, so it must be run from a
# real terminal. Every change has its revert command in the comment above it.
#
# TIER 1 is safe on any headless board. TIER 2 depends on what you actually use
# and is commented out by default - uncomment what applies to you.
set -uo pipefail

echo "== Before =="; free -h | sed -n 2p; echo

# ===================== TIER 1 - safe when headless ==========================

# --- X11 desktop stack. /sys/class/drm/card0-DP-1/status = disconnected. ----
# Xorg ~90 MB + lightdm-gtk-greeter ~87 MB + lightdm ~8 MB, plus the greeter's
# orphaned pipewire+wireplumber pair ~33 MB. Total ~218 MB for zero users.
# REVERT: systemctl set-default graphical.target && systemctl enable --now lightdm
systemctl set-default multi-user.target
systemctl disable lightdm
systemctl stop lightdm

# --- ModemManager: no cellular modem on this board. ~11 MB -----------------
# REVERT: systemctl enable --now ModemManager
systemctl disable --now ModemManager

# --- fwupd: on-demand firmware updater, resident at ~44 MB. ----------------
# Restarts by itself whenever you actually run fwupdmgr.
# REVERT: systemctl unmask fwupd && systemctl start fwupd
systemctl stop fwupd
systemctl mask fwupd

# --- Unattended apt: causes multi-hundred-MB spikes at random times, which
# --- is what pushes a 3.6 GB board into swap mid-build.
# REVERT: systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer

# --- I2C access. Currently: PermissionError on /dev/i2c-{0,1,2} ------------
# REVERT: gpasswd -d arduino i2c
getent group i2c >/dev/null || groupadd -r i2c
usermod -aG i2c arduino

# --- SPI access. /dev/spidev0.0 is root:root 0600 by default. --------------
# REVERT: rm /etc/udev/rules.d/91-spidev-local.rules && udevadm control --reload
getent group spi >/dev/null || groupadd -r spi
usermod -aG spi arduino
printf 'SUBSYSTEM=="spidev", GROUP="spi", MODE="0660"\n' \
  > /etc/udev/rules.d/91-spidev-local.rules
udevadm control --reload-rules
udevadm trigger --subsystem-match=spidev

# --- Build headers for the `spidev` Python module (the only lib that failed
# --- to install; it needs Python.h).
apt-get install -y python3.13-dev

# ===================== TIER 2 - uncomment if unused =========================

# --- Bluetooth. ~5 MB + blueman-mechanism. Uncomment if you never use BT.
# REVERT: systemctl enable --now bluetooth blueman-mechanism
# systemctl disable --now bluetooth blueman-mechanism

# --- adbd: USB-gadget Android Debug Bridge. Only needed if you drive the
# --- board over `adb` from a PC. You are on SSH, so probably not.
# REVERT: systemctl enable --now adbd
# systemctl disable --now adbd

# --- udisks2: automounts removable media. ~16 MB.
# REVERT: systemctl enable --now udisks2
# systemctl disable --now udisks2

# --- Docker + containerd: ~105 MB resident. These exist ONLY to run Arduino
# --- Brick container images. If you are dropping the Arduino app framework,
# --- they are dead weight. WARNING: this also removes the Bricks runtime.
# REVERT: systemctl enable --now docker containerd
# systemctl disable --now docker docker.socket containerd

# --- Arduino app framework: arduino-app-cli daemon ~35 MB + the router.
# --- KEEP arduino-router if you want the MPU<->MCU RPC bridge on /dev/ttyHS1.
# --- Dropping arduino-app-cli alone is safe; it is just the App manager.
# REVERT: systemctl enable --now arduino-app-cli
# systemctl disable --now arduino-app-cli

# --- DO NOT TOUCH: rmtfs, tqftpserv, qbootctl are Qualcomm platform services
# --- (remote filesystem for the DSP, firmware loading, boot slot control).
# --- Disabling them can leave the board unbootable. zramswap is also giving
# --- you the 1.8 GB of compressed swap - keep it.

echo; echo "== After =="; free -h | sed -n 2p
echo
echo "Run 'newgrp i2c' or log out and back in for group changes to apply."
