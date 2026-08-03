# Arduino UNO Q — hybrid MPU + MCU development

A Linux-first development environment for the UNO Q, built on stock upstream
tooling — Zephyr, west, OpenOCD, libgpiod — instead of the Arduino App
framework.

The board is two computers: a Qualcomm QRB2210 running Debian, and an STM32U585
running Zephyr. This project covers the full loop across both:

**host tests → build → sign → flash (SWD) or update (serial) → interactive
shell → structured RPC → on-chip debug**, with automatic rollback if an update
goes bad.

The worked example is a CPU monitor: Linux reads `/proc/stat`, the STM32 draws
one bar per core on the LED matrix. It is the smallest thing that uses both
halves of the board for what each is actually good at.

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
    print(mcu.status())         # {'uptime_ms': 12216, 'flip': 0, 'sweeps': 1043712}
```

```bash
unoq-cpu-bars                   # host CPU load, one bar per core, on the LED matrix
```

> Run it at boot with `sudo bash provision/50-cpu-bars.sh` — but note it then
> holds `/dev/ttyHS1`, so stop the service before using the MCU shell.

```bash
tools/check.sh                  # lint, format, types, tests, coverage
```

In VS Code: **Ctrl-Shift-B** builds, and the Run panel has *Debug (attach)* and
*Debug (flash then run)*. **Terminal → Run Task** has flash, console, test and
FOTA tasks.

---

## Documentation

| | |
|---|---|
| **[hardware.md](docs/hardware.md)** | Board anatomy, the two undocumented GPIOs, the two UARTs, SWD, flash layout. **Read this first.** |
| **[mcu.md](docs/mcu.md)** | Build, flash, debug, FOTA, shell, firmware tests |
| **[mpu.md](docs/mpu.md)** | Linux-side hardware access, the `unoq` API, and the CPU-bars demo end to end |
| **[troubleshooting.md](docs/troubleshooting.md)** | Symptom → cause |

---

## Layout

```
├── env.sh                  shell aliases + Zephyr env   (sourced by ~/.bashrc)
├── docs/                   see above
├── mcu/                    everything for the STM32U585
│   ├── app/                the firmware: shell + SMP + NVS + LED matrix
│   │   ├── include/        app_proto.h - the MPU<->MCU contract, shared
│   │   └── src/            main.c, matrix.c (charlieplex driver), bars.c (rasteriser)
│   ├── tests/              ztest suites (run on the host via native_sim)
│   ├── board-support/      OpenOCD cfg Zephyr's west runner needs (not upstream)
│   ├── link-up.sh          BOOT0 + UART enable   (referenced by systemd — do not move)
│   ├── zbuild.sh           west build + auto-sign + compile_commands
│   ├── flash.sh            flash over SWD
│   ├── flash-all.sh        bootloader + app, for recovery
│   ├── ztest.sh            twister on native_sim
│   └── restore-arduino-firmware.sh
├── python/                 MPU-side package (editable install — do not move)
│   ├── unoq/               link.py (GPIOs), mcu.py (shell), fota.py,
│   │                       cpu.py (/proc/stat), cpubars.py (the daemon)
│   └── tests/              pytest suite, all against fakes — no hardware
├── provision/              one-time root setup, numbered in order
│                           (50-cpu-bars.sh is optional — see mpu.md)
├── tools/                  check.sh (all gates), install-dev-tools.sh,
│                           build-openocd.sh, check-versions.sh
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

## Provisioning a board

These have already been run on this board. They are here so the setup is
reproducible, and so you can see exactly what was changed — every step has its
revert command in the comment above it.

Run in order, as root:

```bash
sudo bash ~/hybrid/provision/10-optimize-board.sh
sudo bash ~/hybrid/provision/20-dev-tools.sh
sudo bash ~/hybrid/provision/30-mcu-link.sh
sudo bash ~/hybrid/provision/40-purge-arduino.sh    # optional, last
sudo bash ~/hybrid/provision/50-cpu-bars.sh         # optional - holds /dev/ttyHS1
```

| Script | Does |
|---|---|
| `10-optimize-board.sh` | Drops the X11 desktop stack (~218 MB — `DP-1` is disconnected), ModemManager, fwupd, unattended apt. Adds the `i2c`/`spi` groups and a spidev udev rule. |
| `20-dev-tools.sh` | Installs `clangd-19`, disables the Arduino services and Docker (~210 MB), releases `/dev/ttyHS1`. |
| `30-mcu-link.sh` | Installs `tio`, and `unoq-link.service` so BOOT0 + UART-enable are applied at boot. **Without this the board looks dead after a reboot.** |
| `40-purge-arduino.sh` | Removes the remaining Arduino debs. Verifies `/opt/openocd` survives before and after. |
| `50-cpu-bars.sh` | Installs `unoq-cpu-bars.service`. Optional, and numbered last because it claims the serial port — see [mpu.md](docs/mpu.md#at-every-boot). |

`10-optimize-board.sh` has a Tier 2 section, commented out, for things that
depend on your usage (Bluetooth, adbd, udisks2).

> Qualcomm platform services — `rmtfs`, `tqftpserv`, `qbootctl` — are marked
> do-not-touch. Disabling them can leave the board unbootable. `zramswap` also
> stays; it provides the compressed swap.

### User-level setup (no root)

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

---

## Quality gates

One command runs everything:

```bash
~/hybrid/tools/check.sh              # all gates
~/hybrid/tools/check.sh --fast       # skip the MCU suite (~70s of Zephyr build)
~/hybrid/tools/check.sh --fix        # reformat in place, then check
~/hybrid/tools/check.sh python       # one area: python | shell | c | mcu
```

Gates keep running after a failure, so one pass shows you all the work rather
than the first thing to break. Exit status is non-zero if any failed.

| Gate | Tool | Covers |
|---|---|---|
| lint | `ruff check` | `python/` |
| format | `ruff format` | `python/` |
| types | `mypy --strict` | `python/` incl. tests |
| tests | `pytest` + coverage | `python/`, gate at **100%** |
| shell lint | `shellcheck -x` | every tracked `*.sh` |
| shell format | `shfmt -i 2 -ci` | every tracked `*.sh` |
| C format | `clang-format` | `mcu/**/*.[ch]`, Zephyr's own style |
| MCU tests | `ztest` on `native_sim` | `mcu/app/include/app_proto.h`, `mcu/app/src/bars.c` |

Install the toolchain and the pre-commit hook with:

```bash
~/hybrid/tools/install-dev-tools.sh   # no sudo, no apt
~/hybrid/tools/install-hooks.sh       # pre-commit -> check.sh --fast
```

`install-dev-tools.sh` puts ruff, mypy, pytest and clang-format in the project
venv (mypy has to import `gpiod`/`pyserial`/`smpclient` to check the code that
uses them), and fetches `shellcheck` and `shfmt` from upstream releases into
`~/.local/bin` — Debian's packages would need root. It detects the
architecture, so the same script works on the board (aarch64) and in CI
(x86_64).

The pre-commit hook runs `--fast`; the MCU suite is too slow to sit in front of
every commit. Skip it once with `git commit --no-verify`.

> The `pre-commit` framework is deliberately not used. It fetches its own
> pinned copies of ruff and shellcheck — a second toolchain to keep in step
> with the one `check.sh` uses, on a board with 3.6 GiB of RAM.

### Tests

```bash
cd ~/hybrid/python && ../.venv/bin/pytest      # 93 tests, 100% coverage
../.venv/bin/pytest -m hardware                # opt-in: needs a live MCU
~/hybrid/mcu/ztest.sh                          # MCU suites on native_sim (26 cases)
```

**Nothing in the default suite touches hardware.** Every serial port and GPIO
chip is faked, because the suite has to be runnable on a board that is
mid-flash, and a test that quietly drove the real BOOT0 line would be worse
than no test. The fakes imitate the awkward parts of the real thing — the shell
echoes your command back, wraps output in ANSI, and dribbles bytes in so the
prompt rarely lands in the first read.

Three suites are not about behaviour at all:

- **The GPIO line numbers** (`test_link.py`) are pinned because nothing
  upstream records them. A "tidy up" has no source of truth to check against
  except that test.
- **The unsigned-image guard** (`test_fota.py`) is pinned because getting it
  wrong stops the board booting.
- **The panel constants** (`test_contract.py`) are pinned across languages: C
  macros cannot be imported into Python, so `unoq/mcu.py` holds a second copy
  of the LED matrix geometry. That test parses `app_proto.h` and fails if the
  two drift, which is what makes the duplication safe to have.

Coverage gates at 100%, which is where it currently sits. That is a deliberate
ratchet — new code needs a test — and it is one line in `pyproject.toml` if you
want it lower.

### CI

`.github/workflows/ci.yml` runs `tools/check.sh python shell c` on push and
pull request, so green CI means the same thing as a clean local run.

`ztest` is the one gate CI skips: it needs a Zephyr workspace and SDK (~5 GB)
that is not worth installing per job. Run it on the board with
`tools/check.sh mcu`.

The runner is x86_64 while the board is aarch64. That is fine here — `gpiod`
ships manylinux wheels for both, and the tests use fakes, so nothing in the job
depends on the architecture.

### Conventions worth knowing

- **`unoq/*` ignores the `PT` rules.** They are pytest-style checks and misfire
  on `fota.test()` — MCUboot's "mark this image pending", not a test.
- **`__all__` is not sorted** (`RUF022` off). It is grouped by meaning, which is
  the useful order for a reader.
- **Blind `except Exception` is `contextlib.suppress`**, with the reason in a
  comment at each site, on hardware paths where raising would make the API
  unusable on a board whose link is already up.
- **C follows Zephyr's own `.clang-format`**, copied from the Zephyr tree like
  `mcu/board-support/`. Re-copy it after a Zephyr version bump.

---

## Maintenance

```bash
~/hybrid/tools/check-versions.sh      # audit everything; reports only
```

Extension auto-update is deliberately **off** (background churn on a 3.6 GiB
board), so nothing updates itself. Run this occasionally.

### Things that look out of date but are not

| | Why |
|---|---|
| `cbor2` 5.x | `smp` requires `>=5.5.1,<6.0.0`. Upgrading breaks SMP/FOTA. |
| `pydantic-core` | `pydantic` pins it **exactly** (`==2.46.4`). Never bump alone. |
| Zephyr's venv | Zephyr pins its own tool versions per release. `pip list --outdated` flags them; they are deliberate. The `cryptography`/`setuptools` pins people spot live in `requirements-actions.txt`, which is **CI-only** and not part of `requirements.txt`. |
| OpenOCD `0.12.0+dev` | We build master on purpose — the newest *release* (0.12.0, 2023) predates libgpiod v2. |
| arm64 extensions | The Marketplace "latest" is frequently x64-only. If `--install-extension id@ver` says *"not found"*, there is no linux-arm64 build and you already have the newest usable one. |

`code --install-extension <id> --force` does **not** bump the version — it
reports "already installed". Name the version explicitly.

### Rebuilding OpenOCD

```bash
sudo bash ~/hybrid/tools/build-openocd.sh              # build + self-test only
sudo bash ~/hybrid/tools/build-openocd.sh --promote    # then replace /opt/openocd
```

`/opt/openocd` is owned by no Debian package, so apt can never reinstall it —
this script removes that as a single point of failure.

It builds **upstream `openocd-org/openocd` master** (pinned, overridable via
`OPENOCD_COMMIT`). Master is required: `configure.ac` checks
`libgpiod >= 2.0` and `linuxgpiod.c` uses the v2 API, while the newest release
predates that. Everything else needed is upstream too — the STM32U5 flash
driver is `stm32l4x` — and the three `.cfg` files live in `backup/mcu-firmware/`.

Only the `jimtcl` submodule is cloned; `libjaylink` is the J-Link probe driver
and `--disable-jlink` means it is never compiled.

The script builds to `/opt/openocd-rebuilt` and **self-tests against the real
MCU** — it must see `Cortex-M33` or it exits non-zero and leaves `/opt/openocd`
alone. `--promote` keeps the old install as `/opt/openocd.<timestamp>`.

All tooling honours `OCD_ROOT`, so you can trial it first:

```bash
OCD_ROOT=/opt/openocd-rebuilt ~/hybrid/mcu/flash.sh \
    ~/zephyrproject/build/zephyr/zephyr.signed.hex
```

Upgrading Zephyr has its own checklist — see
[mcu.md](docs/mcu.md#upgrading-zephyr).

### Backups

`backup/` holds the things that cannot be re-downloaded:

| | |
|---|---|
| `mcu-firmware/` | stock Arduino MCU firmware + the OpenOCD `.cfg` files |
| `opt-openocd/` | a verified copy of `/opt/openocd` (gitignored — it is a binary) |
| `remoteocd` | Arduino's flashing wrapper, kept for reference |

The repo also has an off-board remote. Push after meaningful changes — the
hardware findings in [hardware.md](docs/hardware.md) are not written down
anywhere else.

---

## Recovery

```bash
~/hybrid/mcu/flash-all.sh                  # rebuild the MCUboot chain over SWD
~/hybrid/mcu/restore-arduino-firmware.sh   # back to stock Arduino firmware
```

Both work even though `~/.arduino15` is gone.
