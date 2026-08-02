#!/bin/bash
# Final root-level steps for the west-based dev environment.
#
#   sudo bash ~/hybrid/finish-setup.sh
#
# Safe to run now: the west toolchain has been verified end-to-end
# (build -> flash -> verified -> running) with the Arduino tree already
# deleted. Every step has its revert in the comment above it.
set -uo pipefail

echo "== Before =="; free -h | sed -n 2p; echo

# --- 1. clangd: C/C++ IntelliSense. VS Code settings already point at
# --- /usr/bin/clangd-19 and expect compile_commands.json (west emits it).
# REVERT: apt-get remove -y clangd-19
apt-get install -y clangd-19
ln -sf /usr/bin/clangd-19 /usr/bin/clangd

# --- 2. Arduino services. The MCU no longer runs Arduino firmware, so the
# --- Router Bridge has nothing to talk to. arduino-router also holds
# --- /dev/ttyHS1 open, which blocks you from reading the Zephyr console.
# --- Frees ~105 MB and releases the UART.
# REVERT: systemctl enable --now arduino-router arduino-app-cli
systemctl disable --now arduino-router arduino-router-serial \
                        arduino-app-cli arduino-avahi-serial 2>/dev/null

# --- 3. Docker: you pruned all images; it now serves nothing. ~105 MB.
# REVERT: systemctl enable --now docker docker.socket containerd
systemctl disable --now docker docker.socket containerd 2>/dev/null

# --- 4. OPTIONAL: purge the Arduino debs entirely (~uninstalls the App
# --- framework, App Lab web UI, arduino-cli and the router).
# ---
# --- SAFE: /opt/openocd is owned by NO package (`dpkg -S` finds nothing),
# --- so apt will not remove it. It is also backed up at
# --- ~/hybrid/backup/opt-openocd in case anything ever does.
# ---
# --- Uncomment to remove. REVERT: apt-get install -y arduino-app-cli ...
# apt-get remove -y arduino-app-cli arduino-app-lab arduino-router arduino-cli
# apt-get autoremove -y

echo; echo "== After =="; free -h | sed -n 2p
echo
echo "Verify the console is now readable:"
echo "  ~/hybrid/.venv/bin/python -c \"import serial; s=serial.Serial('/dev/ttyHS1',115200,timeout=2); print(s.read(200))\""
echo "  ~/hybrid/mcu/flash.sh ~/zephyrproject/build/zephyr/zephyr.hex   # re-flash to see boot banner"
