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
> copy is kept in `backup/opt-openocd`. Do not delete either one.

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
