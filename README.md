# Arduino UNO Q — hybrid MPU + MCU development

A Linux-first development environment for this board, built on stock upstream
tooling (Zephyr, west, OpenOCD, libgpiod) rather than the Arduino App framework.

## The hardware, honestly

The UNO Q is two computers on one board:

| | **MPU** (Linux side) | **MCU** (real-time side) |
|---|---|---|
| Part | Qualcomm QRB2210 (`arduino,imola`) | STM32U585 Cortex-M33 |
| Runs | Debian, Python, your services | Zephyr firmware |
| Memory | 3.6 GiB shared | 786 KB flash / 256 KB RAM |
| You reach it via | native Linux syscalls | SWD, or a serial link |

Most Arduino-header GPIO is wired to the **MCU**, not the MPU. The MPU has its
own separate GPIO/I²C/SPI, which is what `~/hybrid/.venv` talks to.

### How the MPU flashes the MCU

There is no external debug probe. The MPU bit-bangs SWD directly on its own
GPIO lines, using OpenOCD's `linuxgpiod` driver:

```
/dev/gpiochip1:  swclk = 26   swdio = 25   srst/trst = 38
```

Verified working:

```
Info : SWD DPIDR 0x0be12477
Info : [stm32u5.cpu] Cortex-M33 r0p4 processor detected
```

This needs no root — your user is in the `gpiod` group.

> **`/opt/openocd` is owned by no Debian package.** `dpkg -S /opt/openocd` finds
> nothing — it was placed there by an install script, so apt will never
> reinstall it, and it is the only way to flash this MCU. A verified-working
> copy is kept in `backup/opt-openocd`.
>
> It is also **reproducible from source** — see below — so this is no longer a
> single point of failure.

### Rebuilding OpenOCD

```bash
sudo bash ~/hybrid/build-openocd.sh              # build + self-test only
sudo bash ~/hybrid/build-openocd.sh --promote    # ...then replace /opt/openocd
```

`apt install openocd` will **not** work. The installed binary reports build
`ge6a2c12f4`, and that commit is not in `openocd-org/openocd` — it is in
**`arduino/OpenOCD`**:

```
e6a2c12f41c9  drivers/linuxgpiodv2: introduce new driver for libgpiod v2 API
```

This board ships libgpiod v2 (`libgpiod.so.3`); upstream OpenOCD master still
targets the v1 API. The fork is required for the *adapter driver* only — the
STM32U5 flash driver (`stm32l4x`) is upstream, and the three `.cfg` files are
plain TCL kept in `backup/mcu-firmware/`.

The script builds to `/opt/openocd-rebuilt`, **self-tests against the real MCU**
(it must see `Cortex-M33`), and only replaces `/opt/openocd` with `--promote` —
keeping the old install as `/opt/openocd.<timestamp>`. All tooling honours
`OCD_ROOT`, so you can trial the rebuild without replacing anything:

```bash
OCD_ROOT=/opt/openocd-rebuilt ~/hybrid/mcu/flash.sh build/zephyr/zephyr.signed.hex
```

### The two GPIOs nobody documents — read this before you debug anything

`arduino-router` used to drive two MPU GPIO lines that the MCU depends on.
Disabling that service breaks the board in ways that look like broken firmware:

| `gpiochip1` line | Function | Symptom when wrong |
|---|---|---|
| **37** | MCU **BOOT0** (latched at reset) | Firmware flashes and *verifies*, but never runs. PC sits around `0x0bf9xxxx` — the STM32 ROM bootloader. |
| **70** | **UART link enable** | MCU transmits fine (`LPUART1 CR1=0x2d`, TC/TXE set) but `/dev/ttyHS1` reads 0 bytes. |
| 25 / 26 / 38 | SWD swdio / swclk / srst | — |

Fix, run once per boot:

```bash
~/hybrid/mcu/link-up.sh      # BOOT0=0, link-enable=1
```

`flash.sh` calls it automatically. The pin state persists after the `gpioset`
process exits (SoC pinctrl holds the last driven value), which is why a
one-shot suffices. Install `mcu/unoq-link.service` to have it applied at boot.

### The two UARTs — this matters

The board has two serial ports and they are **not** interchangeable:

| Node | Pins | Goes to |
|---|---|---|
| `lpuart1` | PG7/PG8 + RTS/CTS on PG6/PG5 | **the Linux MPU** → `/dev/ttyHS1` |
| `usart1`  | PB6/PB7 | the Arduino header pins (D0/D1) |

Upstream Zephyr's `arduino_uno_q` board defaults `zephyr,console` to **`usart1`**,
so a stock `hello_world` prints to the *header pins* and you will see nothing
from Linux. To talk to the MPU, override the console in a board overlay — see
`mcu/app/boards/arduino_uno_q.overlay`. The RTS/CTS pair on `lpuart1` is the
giveaway: that is the board-to-board link.

Verified working — MCU firmware printing, read from Linux:

```
$ ~/hybrid/.venv/bin/python -c "import serial; ..."
mcu tick 1  uptime=1010ms
mcu tick 2  uptime=2012ms
```

## Layout

```
~/zephyrproject/      west workspace, Zephyr v4.4.1 (board: arduino_uno_q)
~/zephyr-sdk-1.0.1/   Zephyr SDK (arm-zephyr-eabi) — matches Zephyr 4.4.x
~/hybrid/
  .venv/              MPU-side Python: gpiod, smbus2, pyserial, spidev
  mcu/
    zbuild.sh         west build wrapper (+ links compile_commands.json)
    flash.sh          flash over SWD via OpenOCD/gpiod
    restore-arduino-firmware.sh   recovery -> stock Arduino firmware
  backup/             stock MCU firmware, remoteocd, OpenOCD configs
  optimize-board.sh   system memory tuning (needs sudo)
```

## MCU workflow

```bash
~/hybrid/mcu/zbuild.sh ~/hybrid/mcu/app          # the hybrid-link app
~/hybrid/mcu/zbuild.sh samples/basic/blinky      # or any Zephyr sample
~/hybrid/mcu/flash.sh ~/zephyrproject/build/zephyr/zephyr.hex
```

`mcu/app/` is a working starting point: it prints to the MPU over `lpuart1`
and toggles `led0`. Read it from Linux with:

```bash
~/hybrid/.venv/bin/python -c "import serial; s=serial.Serial('/dev/ttyHS1',115200,timeout=2); print(s.read(300).decode())"
```

Every flash prints two harmless errors first — `Translation from khz to adapter
speed not implemented` and `reset-init failed`. The `linuxgpiod` bitbang adapter
has no configurable speed, so that reset event cannot run. Programming and
verification still succeed; the flash is good.

Debugging: open `~/zephyrproject` in VS Code and use the **Debug (attach)** or
**Debug (flash then run)** launch configs. These drive OpenOCD on the board and
give you breakpoints, memory view, and peripheral registers.

## MPU workflow

```bash
~/hybrid/.venv/bin/python your_script.py
```

```python
import gpiod, smbus2, spidev, serial
```

## Recovery

The stock Arduino firmware is preserved in `backup/mcu-firmware/`. To go back:

```bash
~/hybrid/mcu/restore-arduino-firmware.sh
```

This restores the Router Bridge on `/dev/ttyHS1` and makes `arduino-app-cli`
behave as it originally did. It works even after `~/.arduino15` is deleted.

## What was removed, and why it was safe

The Arduino platform tree was a *build wrapper*, not the capability itself:

- the **compiler** it referenced was never installed (`arm-zephyr-eabi-0.16.8`)
- the **flasher** (`remoteocd`) is a Go wrapper around `/opt/openocd`, which is
  a separate system package
- the **board support** exists upstream at `boards/arduino/uno_q` in Zephyr

What Arduino added on top was the LLEXT "sketch" model: a resident Zephyr
firmware plus loadable modules at flash `0x08100000`. Building whole firmware
images with west replaces that outright.

## Workspace slimming

`west update` clones every vendor's HAL by default (~5 GB of hardware you do not
have). This workspace uses a manifest filter to keep only what an STM32U585
build needs:

```bash
cd ~/zephyrproject
./.venv/bin/west config manifest.project-filter
# -hal_.*,+hal_stm32,+hal_st,-lvgl,-cmsis-dsp,... (68 projects -> 25)
```

That took the tree from 7.0 GB to 3.3 GB. Verified afterwards: a pristine
rebuild produces a byte-identical binary, and an unrelated upstream sample
(`samples/subsys/shell/shell_module`) still builds.

**Never `rm -rf` a module directory without filtering it out first** — west
would try to manage a project whose checkout has vanished. Change the filter,
then delete. To get one back, add `+name` to the filter and run `west update`.

## Shell setup

```bash
echo 'source ~/hybrid/env.sh' >> ~/.bashrc
source ~/hybrid/env.sh
```

Gives you `west`, `zbuild`, `zflash`, `hpy` (MPU Python), and `mcucon`
(live MCU console). Also puts `/opt/openocd/bin` on PATH so `west flash`
and `west debug` work.

## Idiomatic west flash / debug

`west flash -r openocd` and `west debug` work, but needed a local fix:

- Zephyr's openocd runner resolves board support **in-tree**, and `uno_q`
  ships no `support/` directory. Without it the runner crashes on
  `samefile()` (`runners/openocd.py:92`) — an upstream bug, not a config error.
- The default flash runner is `stm32cubeprogrammer`, which is not installed.
  Always pass `-r openocd`.

The fix is `zephyr/boards/arduino/uno_q/support/openocd.cfg`. It is **not**
upstream; a canonical copy lives in `mcu/board-support/`. After a Zephyr
version bump, re-copy it:

```bash
cp -r ~/hybrid/mcu/board-support/support \
      ~/zephyrproject/zephyr/boards/arduino/uno_q/
```

`~/hybrid/mcu/flash.sh` does not depend on any of this and is the more
robust path.

## Debugging in VS Code

Open `~/zephyrproject`, pick **Debug (attach)** or **Debug (flash then run)**.
`.vscode/STM32U585.svd` (8 MB, 202 peripherals) drives the peripheral-register
viewer, so you get named register decoding for every peripheral on the chip.

## MCU shell + SMP over the MPU link

`mcu/app` runs a Zephyr shell **and** an SMP/MCUmgr endpoint over the single
`lpuart1` link. Both verified working simultaneously.

```bash
mcucon                                  # live console (from env.sh)
```

Drive it from Python — the shell is a plain line protocol:

```python
import serial
s = serial.Serial('/dev/ttyHS1', 115200, timeout=0.5)
s.write(b"app status\r\n")        # -> uptime_ms=12216 ticks=25 blink_ms=500
s.write(b"gpio conf gpioh 11 o\r\n")
```

Built-in command groups: `app` (yours), `gpio`, `i2c`, `device`, `kernel`,
`devmem`. Poke hardware without a rebuild.

Structured RPC via SMP (`smpclient` is installed in `.venv`):

```python
from smpclient import SMPClient
from smpclient.transport.serial import SMPSerialTransport
from smpclient.requests.os_management import EchoWrite
# -> echo reply: 'round-trip-ok'
```

SMP-over-shell registers **no** `mcumgr` command — the shell sniffs SMP frame
markers out of the byte stream. `mcumgr: command not found` is expected.

`CONFIG_MCUMGR_TRANSPORT_SHELL` silently disables itself without
`CONFIG_BASE64` and `CONFIG_CRC`. Kconfig warns; the build still succeeds.

**Not done:** firmware update over SMP. That needs MCUboot in `boot_partition`
and signed images in `slot0`, which changes the flash layout and the current
direct-SWD workflow. The partitions already exist in the board DTS.

## Fast iteration with native_sim

Zephyr builds for the host, so logic can be exercised with no flash cycle:

```bash
cd ~/zephyrproject
./.venv/bin/west build -b native_sim/native/64 zephyr/samples/hello_world -d /tmp/bnative
/tmp/bnative/zephyr/zephyr.exe
```

Use `native_sim/native/64` — plain `native_sim` is a 32-bit target and fails on
aarch64 with a `CONFIG_64BIT` error.

## Python tooling

Pylance is removed (~412 MB even in "light" mode). Ruff's LSP handles linting,
formatting and imports. **It does no type inference** — no hover types, no
go-to-definition into libraries. If you want those back cheaply, install
`basedpyright` and set `python.languageServer` accordingly.

## Firmware update over serial (MCUboot + SMP)

The MCU runs MCUboot, so app updates need **no SWD** — they go over the same
UART. Verified end to end, including the revert path.

```
0x08000000  boot_partition   64K   MCUboot (38K used)
0x08010000  slot0           416K   running signed app
0x08078000  slot1           416K   staged update
0x080e0000  storage         128K   NVS (settings, boot counter)
```

```python
from unoq import fota
fota.upload("~/zephyrproject/build/zephyr/zephyr.signed.bin")
fota.test()      # mark pending
fota.reset()     # MCUboot swaps slot1 -> slot0
fota.confirm()   # keep it
```

**The revert is the point.** An image that boots but is never confirmed is
rolled back on the next reset. Verified: swapped to v0.2.0, reset without
confirming, and the board came back on v0.0.0 by itself. Confirm, and it sticks.

`zbuild.sh` signs automatically when `CONFIG_BOOTLOADER_MCUBOOT=y`. **Never
flash the unsigned `zephyr.hex` over a MCUboot chain** — it links into slot0 but
has no image header, so the bootloader refuses it. Use `zephyr.signed.hex`, or
`mcu/flash-all.sh` to lay down bootloader + app together.

Recovery from anything: `mcu/flash-all.sh` over SWD.

## Python API

`~/hybrid/python/unoq` (installed editable into `.venv`):

```python
from unoq import MCU, fota, link_up, link_state

link_up()                      # BOOT0 low + UART enable
with MCU() as mcu:
    mcu.status()               # {'uptime_ms':…, 'ticks':…, 'boots':…, 'wdt':1}
    mcu.blink(250)
    mcu.devices()              # [('gpio@42021c00','READY'), …]
    mcu.gpio_get('gpioh', 11)
    mcu.echo('ping')           # via SMP, not the shell
```

`MCU` is a context manager on purpose — the UART is a single shared resource
and a stale handle blocks `tio`, `mcucon` and SMP alike.

Gotcha baked into the module: handing the port from the shell to SMP needs a
settle delay. Reopening immediately drops the first SMP frame and times out,
which looks exactly like a firmware fault but is a host-side race.

## Watchdog and persistent state

The app arms a 4 s task watchdog and keeps a boot counter in NVS.

```
$ app hang        # stops the feeder
# ~4s later: boots 5 -> 6, uptime reset
```

`app hang` must stop the **main** loop, not block the shell thread — blocking
the shell wedges only the shell while main keeps feeding, and nothing resets.

## Tests

```bash
~/hybrid/mcu/ztest.sh                    # native_sim, no hardware
~/hybrid/mcu/ztest.sh -p arduino_uno_q   # cross-compile for the board
```

Runs natively on the MPU — 3 cases in 0.038 s, no flash cycle. Use
`native_sim/native/64`; plain `native_sim` is 32-bit and fails on aarch64.
