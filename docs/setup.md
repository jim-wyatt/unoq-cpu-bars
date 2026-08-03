# Provisioning a board

These have already been run on this board. They are here so the setup is
reproducible, and so you can see exactly what was changed — every step has its
revert command in the comment above it.

Run in order, as root:

```bash
sudo bash ~/hybrid/provision/10-optimize-board.sh
sudo bash ~/hybrid/provision/20-dev-tools.sh
sudo bash ~/hybrid/provision/30-mcu-link.sh
sudo bash ~/hybrid/provision/40-purge-arduino.sh    # optional, last
```

| Script | Does |
|---|---|
| `10-optimize-board.sh` | Drops the X11 desktop stack (~218 MB — `DP-1` is disconnected), ModemManager, fwupd, unattended apt. Adds the `i2c`/`spi` groups and a spidev udev rule. |
| `20-dev-tools.sh` | Installs `clangd-19`, disables the Arduino services and Docker (~210 MB), releases `/dev/ttyHS1`. |
| `30-mcu-link.sh` | Installs `tio`, and `unoq-link.service` so BOOT0 + UART-enable are applied at boot. **Without this the board looks dead after a reboot.** |
| `40-purge-arduino.sh` | Removes the remaining Arduino debs. Verifies `/opt/openocd` survives before and after. |

`10-optimize-board.sh` has a Tier 2 section, commented out, for things that
depend on your usage (Bluetooth, adbd, udisks2).

> Qualcomm platform services — `rmtfs`, `tqftpserv`, `qbootctl` — are marked
> do-not-touch. Disabling them can leave the board unbootable. `zramswap` also
> stays; it provides the compressed swap.

## User-level setup (no root)

Already done here; listed for reproducibility.

```bash
# 1. uv, then the host tools
curl -LsSf https://astral.sh/uv/install.sh | sh
uv tool install cmake && uv tool install ninja && uv tool install west

# 2. Zephyr SDK 1.0.1 (arm-zephyr-eabi) into ~/zephyr-sdk-1.0.1
#    then: ./setup.sh -t arm-zephyr-eabi -c

# 3. Zephyr workspace
mkdir -p ~/zephyrproject && cd ~/zephyrproject
uv venv --python 3.13 .venv
uv pip install --python .venv/bin/python west imgtool
.venv/bin/west init -m https://github.com/zephyrproject-rtos/zephyr --mr v4.4.1 .
.venv/bin/west config manifest.project-filter -- \
  '-hal_.*,+hal_stm32,+hal_st,-lvgl,-cmsis-dsp,-cmsis-nn,-lora-basics-modem,-loramac-node,-acpica,-hostap,-openthread,-nrf_wifi,-trusted-firmware-m,-trusted-firmware-a,-tf-m-tests,-psa-arch-tests,-nrf_hw_models,-edtt,-net-tools'
.venv/bin/west update --narrow -o=--depth=1
.venv/bin/west zephyr-export
uv pip install --python .venv/bin/python -r zephyr/scripts/requirements.txt

# 4. MPU python
cd ~/hybrid && uv venv .venv
uv pip install --python .venv/bin/python gpiod smbus2 pyserial spidev smpclient
uv pip install --python .venv/bin/python -e python

# 5. shell env
echo 'source ~/hybrid/env.sh' >> ~/.bashrc
```

The manifest filter keeps the workspace at ~3.3 GB instead of ~7 GB by skipping
vendor HALs for hardware you do not have. **Never `rm -rf` a module directory
without filtering it out first** — west would then manage a project whose
checkout has vanished. Change the filter, then delete.

## Bootstrapping the MCU chain

```bash
~/hybrid/mcu/flash-all.sh     # builds MCUboot if needed, flashes bootloader + app
```
