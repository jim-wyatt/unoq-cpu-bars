# Arduino UNO Q — hybrid MPU + MCU development

A Linux-first development environment for the UNO Q, built on stock upstream
tooling — Zephyr, west, OpenOCD, libgpiod — instead of the Arduino App
framework.

The board is two computers: a Qualcomm QRB2210 running Debian, and an STM32U585
running Zephyr. This project covers the full loop across both:

**host tests → build → sign → flash (SWD) or update (serial) → interactive
shell → structured RPC → on-chip debug**, with automatic rollback if an update
goes bad.

---

## Quickstart

```bash
source ~/hybrid/env.sh          # already in ~/.bashrc

zbuild ~/hybrid/mcu/app         # build firmware (auto-signs for MCUboot)
zflash ~/zephyrproject/build/zephyr/zephyr.signed.hex
mcucon                          # watch the MCU console
```

```python
from unoq import MCU
with MCU() as mcu:
    print(mcu.status())         # {'uptime_ms': 12216, 'ticks': 25, 'boots': 7, 'wdt': 1}
```

In VS Code: **Ctrl-Shift-B** builds, and the Run panel has *Debug (attach)* and
*Debug (flash then run)*. **Terminal → Run Task** has flash, console, test and
FOTA tasks.

---

## Documentation

| | |
|---|---|
| **[hardware.md](docs/hardware.md)** | Board anatomy, the two undocumented GPIOs, the two UARTs, SWD, flash layout. **Read this first.** |
| **[mcu.md](docs/mcu.md)** | Build, flash, debug, FOTA, shell, tests, watchdog |
| **[mpu.md](docs/mpu.md)** | Linux-side hardware access and the `unoq` API |
| **[setup.md](docs/setup.md)** | Provisioning a board from scratch |
| **[maintenance.md](docs/maintenance.md)** | Version audit, dependency pins, rebuilding OpenOCD |
| **[troubleshooting.md](docs/troubleshooting.md)** | Symptom → cause |

---

## Layout

```
├── env.sh                  shell aliases + Zephyr env   (sourced by ~/.bashrc)
├── docs/                   see above
├── mcu/                    everything for the STM32U585
│   ├── app/                the firmware: shell + SMP + watchdog + NVS
│   ├── tests/              ztest suites (run on the host via native_sim)
│   ├── board-support/      OpenOCD cfg Zephyr's west runner needs (not upstream)
│   ├── link-up.sh          BOOT0 + UART enable   (referenced by systemd — do not move)
│   ├── zbuild.sh           west build + auto-sign + compile_commands
│   ├── flash.sh            flash over SWD
│   ├── flash-all.sh        bootloader + app, for recovery
│   ├── ztest.sh            twister on native_sim
│   └── restore-arduino-firmware.sh
├── python/unoq/            MPU-side package (editable install — do not move)
│   ├── link.py             the BOOT0 / link-enable GPIOs
│   ├── mcu.py              Zephyr shell + SMP client
│   └── fota.py             MCUboot firmware update
├── provision/              one-time root setup, numbered in order
├── tools/                  build-openocd.sh, check-versions.sh
└── backup/                 stock firmware + OpenOCD (not re-downloadable)
```

Three paths are load-bearing and must not move: `env.sh` (sourced by
`~/.bashrc`), `mcu/link-up.sh` (referenced by `unoq-link.service`), and
`python/` (the editable install target).

---

## The one thing that will bite you

Two MPU GPIO lines control the MCU and are documented nowhere:

| `gpiochip1` | Function | Symptom when wrong |
|---|---|---|
| **37** | MCU BOOT0 | firmware flashes and *verifies*, but never runs |
| **70** | UART link enable | MCU transmits, `/dev/ttyHS1` reads nothing |

`unoq-link.service` sets them at boot; `flash.sh` and `unoq.MCU` set them too.
Full detail in [hardware.md](docs/hardware.md).

---

## Recovery

```bash
~/hybrid/mcu/flash-all.sh                  # rebuild the MCUboot chain over SWD
~/hybrid/mcu/restore-arduino-firmware.sh   # back to stock Arduino firmware
```

Both work even though `~/.arduino15` is gone.
