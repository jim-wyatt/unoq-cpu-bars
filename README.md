# Two computers, one board

There are two computers on the Arduino UNO Q, and they do not get along by
default. This is a Linux-first development environment that makes them
cooperate, built on stock upstream tooling (Zephyr, west, OpenOCD, libgpiod)
rather than the Arduino App framework — plus a
[16-chapter course](https://jim-wyatt.github.io/two-computers-one-board/) that
teaches the whole stack from a factory-fresh board.

The two computers are a Qualcomm QRB2210 running Debian and an STM32U585
running Zephyr. This project covers the full loop across both:

**host tests → build → sign → flash (SWD) or update (serial) → interactive
shell → structured RPC → on-chip debug**, with automatic rollback if an update
goes bad.

The worked example is a CPU monitor: Linux reads `/proc/stat`, the STM32 draws
one bar per core on the LED matrix. It is the smallest thing that uses both
halves of the board for what each is actually good at.

---

## From a freshly flashed board

```bash
git clone https://github.com/jim-wyatt/two-computers-one-board.git ~/two-computers-one-board
cd ~/two-computers-one-board && ./bootstrap.sh
```

That is the whole bootstrap. It takes ~40–60 minutes on a cold board, almost
all of it the Zephyr workspace (~3.3 GB) and SDK (~1 GB), and it is
**idempotent** — re-running it is the recovery path for a run that died
halfway, not a fresh start. Run it as yourself; it calls `sudo` where it needs
to and keeps everything else owned by you.

Optional extras are opt-in, because each one costs you something:

```bash
./bootstrap.sh --with-cpu-bars     # LED matrix at boot   (holds /dev/ttyHS1)
./bootstrap.sh --with-usb-gadget   # IP over USB          (drops the USB host port)
./bootstrap.sh --with-learning     # web server on :8080
./bootstrap.sh --with-purge        # remove the Arduino debs
./bootstrap.sh --everything
```

---

## Quickstart

```bash
source ~/two-computers-one-board/env.sh          # already in ~/.bashrc

zbuild ~/two-computers-one-board/mcu/app         # build firmware (auto-signs for MCUboot)
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

Everything under `docs/` is both a folder you can read here on GitHub and the
source of a **rendered site** — served off the board at `http://<board>:8080/`,
and carried on the USB drive so it works with no network at all.

```bash
tools/build-docs.sh              # render docs/ -> share/learn/
tools/build-docs.sh --serve      # live preview on :8000 while you write
```

It is [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/), built
with `--strict`: a link that does not resolve is a build failure, and
`tools/check.sh docs` runs it as a gate. `share/learn/` is generated output and
is not in the repository.

### The course

**[docs/learn/](docs/learn/start-here.md)** is a course in hybrid MPU + MCU
development for someone who can program and has never done embedded work. Start
at [Start here](docs/learn/start-here.md).

### Reference

| | |
|---|---|
| **[hardware.md](docs/reference/hardware.md)** | Board anatomy, the two undocumented GPIOs, the two UARTs, SWD, flash layout. **Read this first.** |
| **[mcu.md](docs/reference/mcu.md)** | Build, flash, debug, FOTA, shell, firmware tests |
| **[mpu.md](docs/reference/mpu.md)** | Linux-side hardware access, the `unoq` API, and the CPU-bars demo end to end |
| **[usb.md](docs/reference/usb.md)** | IP over USB, the fileshare drive, and why the role cannot be switched from software |
| **[troubleshooting.md](docs/reference/troubleshooting.md)** | Symptom → cause |
| **[clean-board-findings.md](docs/reference/clean-board-findings.md)** | What taking a factory-restored board through `bootstrap.sh` actually turned up, and what is still unvalidated |

---

## Layout

```
├── bootstrap.sh            stock board -> working board, one command
├── env.sh                  shell aliases + Zephyr env   (sourced by ~/.bashrc)
├── mkdocs.yml              the documentation site: theme, nav, offline rules
├── docs/                   see above
│   ├── learn/              the course, in reading order
│   └── reference/          the detail, for someone who already knows
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
├── status/                 the two RGB LEDs Linux can drive, and their unit
│                           (NOT under usb/ — they report on the whole board)
├── tests/                  bats suites for the shell — see tests/README.md
├── python/                 MPU-side package (editable install — do not move)
│   ├── unoq/               link.py (GPIOs), mcu.py (shell), fota.py,
│   │                       cpu.py (/proc/stat), cpubars.py + learn.py (daemons)
│   └── tests/              pytest suite, all against fakes — no hardware
├── usb/                    the composite USB gadget: network + fileshare
│   ├── gadget-up.sh        build the configfs gadget, bind when a UDC appears
│   ├── usb-net-up.sh       br-usb, 10.55.0.1, and DHCP in either direction
│   ├── usb-dhcp.sh         client mode: take an address from a sharing host
│   ├── bind-guard.sh       stop a brownout loop becoming permanent
│   ├── uplink-fallback.sh  wifi back on if USB gives no internet after boot
│   ├── wifi.sh             radio off, once the USB link can carry the traffic
│   ├── status.sh           the whole USB picture in one read-only command
│   └── *.rules, *.service  udev-driven, because there is no UDC until you
│                           plug into a computer — see usb.md
├── share/                  what the board hands out
│   ├── learn/              the rendered site — GENERATED, gitignored
│   ├── fetch-vscode.sh     download the installers (not redistributed)
│   └── build-image.sh      build the FAT32 image both USB and HTTP serve
├── provision/              root setup, numbered in order; all idempotent
│   ├── lib.sh              the primitives that make them so
│   └── user/               the non-root half: uv, SDK, workspace, venv, env
└── tools/                  check.sh (all gates), install-dev-tools.sh,
                            build-docs.sh, mkdocs_hooks.py,
                            build-openocd.sh, check-versions.sh
```

Two paths are load-bearing within a checkout and must not move: `python/` (the
editable install target) and `provision/lib.sh` (every script sources it by
relative path). `env.sh` and the scripts named by unit files may move *with*
the checkout — `user/50-shell-env.sh` repoints `~/.bashrc`, and `install_unit`
rewrites the unit paths — but not independently of it.

---

## The one thing that will bite you

Two MPU GPIO lines control the MCU and are documented nowhere:

| `gpiochip1` | Function | Symptom when wrong |
|---|---|---|
| **37** | MCU BOOT0 | firmware flashes and *verifies*, but never runs |
| **70** | UART link enable | MCU transmits, `/dev/ttyHS1` reads nothing |

`unoq-link.service` sets them at boot; `flash.sh` and `unoq.MCU` set them too.
Full detail in [hardware.md](docs/reference/hardware.md).

---

## Provisioning a board

`bootstrap.sh` runs all of these in order — you rarely need to invoke them
individually. They are separate, numbered and individually runnable so you can
see exactly what changes, and every step has its revert command in the comment
above it.

**All of them are idempotent.** That is a stronger claim than "safe to re-run":
a second run reports `0 changed, 14 already correct` and touches nothing — it
does not reinstall, does not rewrite files whose content already matches, and
does not restart services that are already correct.

```bash
sudo bash ~/two-computers-one-board/provision/10-optimize-board.sh
sudo bash ~/two-computers-one-board/provision/20-dev-tools.sh
bash      ~/two-computers-one-board/provision/user/10-host-tools.sh      # NOT root
bash      ~/two-computers-one-board/provision/user/20-zephyr-sdk.sh
bash      ~/two-computers-one-board/provision/user/30-zephyr-workspace.sh
bash      ~/two-computers-one-board/provision/user/40-python-venv.sh
bash      ~/two-computers-one-board/provision/user/50-shell-env.sh
sudo bash ~/two-computers-one-board/provision/30-mcu-link.sh             # needs the venv above
sudo bash ~/two-computers-one-board/provision/40-purge-arduino.sh        # optional
sudo bash ~/two-computers-one-board/provision/50-cpu-bars.sh             # optional - holds ttyHS1
sudo bash ~/two-computers-one-board/provision/60-usb-gadget.sh           # optional - see usb.md
sudo bash ~/two-computers-one-board/provision/70-learning-web.sh         # optional
```

| Script | Does |
|---|---|
| `10-optimize-board.sh` | Drops the X11 desktop stack (~218 MB — `DP-1` is disconnected), ModemManager, fwupd, unattended apt, and the ~2 GB of Arduino container images. Runs the one `apt-get upgrade` a restored board needs (`UNOQ_SKIP_APT_UPGRADE=1` to skip). Adds the `i2c`/`spi`/`gpiod` group memberships and a spidev udev rule. `UNOQ_TIER2=1` also drops Bluetooth and udisks2. |
| `20-dev-tools.sh` | Installs `clangd` (version discovered, not pinned), disables the Arduino services and Docker (~210 MB), verifies `/dev/ttyHS1` is released. |
| `user/10-host-tools.sh` | `uv`, then `cmake`, `ninja` and `west` as uv tools. |
| `user/20-zephyr-sdk.sh` | Zephyr SDK, `arm-zephyr-eabi` only. ~1 GB. |
| `user/30-zephyr-workspace.sh` | `west init` + `update` with the manifest filter. ~3.3 GB, the slow one. |
| `user/40-python-venv.sh` | The `.venv`, the hardware libraries, `unoq` editable, and the dev tooling. |
| `user/50-shell-env.sh` | `env.sh` into `~/.bashrc`, and the git pre-commit hook. |
| `30-mcu-link.sh` | Installs `tio`, and `unoq-link.service` so BOOT0 + UART-enable are applied at boot. **Without this the board looks dead after a reboot.** |
| `40-purge-arduino.sh` | Removes the remaining Arduino debs. Backs up the stock MCU firmware first, and verifies `/opt/openocd` survives before and after. |
| `50-cpu-bars.sh` | Installs `unoq-cpu-bars.service`. Optional, because it claims the serial port — see [mpu.md](docs/reference/mpu.md#at-every-boot). |
| `60-usb-gadget.sh` | IP over USB + the fileshare drive. Optional, because the USB-C port cannot be a host and a device at once — see [usb.md](docs/reference/usb.md). |
| `70-learning-web.sh` | Serves `share/learn` and the installers on `:8080`. |

Paths and the owning user are **derived**, not hardcoded: `install_unit`
substitutes `$PROJECT` and `$SUDO_USER` into the unit files at install time, so
the repo works cloned anywhere and under any account.

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
cd ~/two-computers-one-board && uv venv .venv
uv pip install --python .venv/bin/python gpiod smbus2 pyserial spidev smpclient
uv pip install --python .venv/bin/python -e python

# 5. shell env
echo 'source ~/two-computers-one-board/env.sh' >> ~/.bashrc
```

The manifest filter keeps the workspace at ~3.3 GB instead of ~7 GB by skipping
vendor HALs for hardware you do not have. **Never `rm -rf` a module directory
without filtering it out first** — west would then manage a project whose
checkout has vanished. Change the filter, then delete.

---

## Quality gates

One command runs everything:

```bash
~/two-computers-one-board/tools/check.sh              # all gates
~/two-computers-one-board/tools/check.sh --fast       # skip the MCU suite (~70s of Zephyr build)
~/two-computers-one-board/tools/check.sh --fix        # reformat in place, then check
~/two-computers-one-board/tools/check.sh python       # one area: python | shell | c | docs | mcu
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
~/two-computers-one-board/tools/install-dev-tools.sh   # no sudo, no apt
~/two-computers-one-board/tools/install-hooks.sh       # pre-commit -> check.sh --fast
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
cd ~/two-computers-one-board/python && ../.venv/bin/pytest      # 93 tests, 100% coverage
../.venv/bin/pytest -m hardware                # opt-in: needs a live MCU
~/two-computers-one-board/mcu/ztest.sh                          # MCU suites on native_sim (26 cases)
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

`.github/workflows/ci.yml` runs two jobs on push and pull request, so green CI
means the same thing as a clean local run:

| job | what it does |
|---|---|
| `checks` | `tools/check.sh python shell c docs` — ~30 seconds |
| `firmware` | cross-compiles `mcu/app` for `arduino_uno_q`, reports the image size against the 416K slot, then runs the MCU suites on `native_sim` |

They are separate so a missing comma fails in thirty seconds rather than behind
a toolchain download.

The Zephyr version is pinned in **two** places — `provision/user/30-zephyr-workspace.sh`
for the board's standalone workspace, and `west.yml` for CI, which needs the repo
to be its own manifest repo. `tools/check-zephyr-pin.sh` is a gate that fails if
they disagree, because a CI job compiling a different Zephyr from the board is
worse than no CI job at all.

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
~/two-computers-one-board/tools/check-versions.sh      # audit everything; reports only
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
sudo bash ~/two-computers-one-board/tools/build-openocd.sh              # build + self-test only
sudo bash ~/two-computers-one-board/tools/build-openocd.sh --promote    # then replace /opt/openocd
```

`/opt/openocd` is owned by no Debian package, so apt can never reinstall it —
this script removes that as a single point of failure.

It builds **upstream `openocd-org/openocd` master** (pinned, overridable via
`OPENOCD_COMMIT`). Master is required: `configure.ac` checks
`libgpiod >= 2.0` and `linuxgpiod.c` uses the v2 API, while the newest release
predates that. Everything else needed is upstream too — the STM32U5 flash
driver is `stm32l4x`, and the two STM32 target scripts are taken from the
OpenOCD tree the script just built, so they always match the binary. The only
config this repo supplies is `mcu/board-support/openocd_gpiod.cfg`, which names
the UNO Q's SWD pins.

Only the `jimtcl` submodule is cloned; `libjaylink` is the J-Link probe driver
and `--disable-jlink` means it is never compiled.

The script builds to `/opt/openocd-rebuilt` and **self-tests against the real
MCU** — it must see `Cortex-M33` or it exits non-zero and leaves `/opt/openocd`
alone. `--promote` keeps the old install as `/opt/openocd.<timestamp>`.

All tooling honours `OCD_ROOT`, so you can trial it first:

```bash
OCD_ROOT=/opt/openocd-rebuilt ~/two-computers-one-board/mcu/flash.sh \
    ~/zephyrproject/build/zephyr/zephyr.signed.hex
```

Upgrading Zephyr has its own checklist — see
[mcu.md](docs/reference/mcu.md#upgrading-zephyr).

### Keep your own copies

Two things on a provisioned board cannot be re-downloaded, and neither is this
project's to redistribute (see [THIRD-PARTY.md](docs/third-party.md)). Copy both
aside **before** running `provision/40-purge-arduino.sh`:

```bash
mkdir -p ~/uno-q-backup
cp -a /opt/openocd ~/uno-q-backup/                       # rebuildable, but slow
cp ~/.arduino15/packages/arduino/hardware/zephyr/*/variants/*/*.hex ~/uno-q-backup/
```

The `.hex` is what `restore-arduino-firmware.sh` wants in `STOCK_FW`.
`/opt/openocd` is rebuildable from source with `tools/build-openocd.sh`, so
losing it costs time rather than capability.

Push after meaningful changes — the hardware findings in
[hardware.md](docs/reference/hardware.md) are not written down anywhere else.

---

## Recovery

```bash
~/two-computers-one-board/mcu/flash-all.sh                  # rebuild the MCUboot chain over SWD
~/two-computers-one-board/mcu/restore-arduino-firmware.sh   # back to stock Arduino firmware
```

Both work even though `~/.arduino15` is gone — the second needs the stock image
you copied aside, via `STOCK_FW`.

---

## License

MIT — see [LICENSE](LICENSE). Every first-party file carries an
`SPDX-License-Identifier: MIT` header.

A few files belong to other projects and keep their own terms — ST's SVD,
Zephyr's `.clang-format`, and the panel wiring `matrix.c` reads out of
ArduinoCore-zephyr. They are listed in [THIRD-PARTY.md](docs/third-party.md).

## Trademarks and affiliation

**This is an independent project. It is not affiliated with, authorised by,
sponsored by, or endorsed by any of the companies or projects named in it.**

Product, company and project names used here — Arduino® and UNO®, Qualcomm® and
Snapdragon®, STMicroelectronics® and STM32®, Arm® and Cortex®, Zephyr®, Linux®,
Debian®, Python®, Microsoft®, Windows®, Visual Studio Code, GitHub®, macOS®,
Qwiic® — are the property of their respective owners and may be registered
trademarks in some jurisdictions.

They appear here for one reason: **to say accurately what this software runs
on, builds with, and talks to.** You cannot describe a Zephyr application that
flashes an STM32 over SWD without naming Zephyr and STM32. That is descriptive
use, not a claim on the names, and nothing here should be read as suggesting
that any of these organisations produced, reviewed or endorsed this project.

Specifically:

- No vendor logos, icons or brand artwork are used or redistributed. The mark
  on this site is [`docs/assets/logo.svg`](docs/assets/logo.svg) — four LED bars,
  drawn for this project and MIT-licensed like the rest of it.
- No vendor binaries or firmware images are redistributed. See
  [Not included](docs/third-party.md#not-included) for what was deliberately
  removed and why.
- Where third-party *files* are included, they keep their own licence headers
  and are listed in [THIRD-PARTY.md](docs/third-party.md).

If you own one of these marks and object to how it is used here, open an issue
and it will be changed.
