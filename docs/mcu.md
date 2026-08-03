# MCU workflow

Firmware for the STM32U585, built with stock Zephyr + west. No Arduino tooling.

```
~/zephyrproject/      west workspace, Zephyr v4.4.1, board `arduino_uno_q`
~/zephyr-sdk-1.0.1/   Zephyr SDK (arm-zephyr-eabi)
```

## Build

```bash
zbuild ~/hybrid/mcu/app                      # this project's app
zbuild samples/basic/blinky                  # any upstream Zephyr sample
zbuild ~/hybrid/mcu/app -p always            # pristine rebuild
```

(`zbuild` / `zflash` are aliases from [`env.sh`](../env.sh); the scripts are
`mcu/zbuild.sh` and `mcu/flash.sh`.)

`zbuild` signs automatically when `CONFIG_BOOTLOADER_MCUBOOT=y`, and links
`compile_commands.json` into both this project and the Zephyr workspace so
clangd works in either.

**Each app gets its own build directory.** This project's app builds into
`~/zephyrproject/build` — the path named by every doc, VS Code task and
`launch.json`. Anything else builds into `~/zephyrproject/build-<name>`:

```bash
zbuild ~/hybrid/mcu/app       # -> ~/zephyrproject/build
zbuild samples/basic/blinky   # -> ~/zephyrproject/build-blinky
```

So switching between apps never forces a pristine rebuild, and building a
sample never repoints this project's `compile_commands.json` at foreign code —
which would leave clangd quietly indexing the wrong tree. Only this project's
own app updates its index. Override the directory with `BUILD_DIR=...`.

## Flash over SWD

```bash
zflash ~/zephyrproject/build/zephyr/zephyr.signed.hex
```

> **Never flash the unsigned `zephyr.hex` over a MCUboot chain.** It links into
> slot0 but has no image header, so the bootloader refuses it and the board
> stops booting. Use `zephyr.signed.hex`.

Full recovery — bootloader + app together:

```bash
~/hybrid/mcu/flash-all.sh
```

Every flash prints two harmless errors first:

```
Error: Translation from khz to adapter speed not implemented
Error: [stm32u5.cpu] Execution of event reset-init failed
```

The `linuxgpiod` bitbang adapter has no configurable speed, so that reset event
cannot run. Programming and verification still succeed.

## Update over serial (no SWD)

The MCU runs MCUboot, so routine updates go over the UART.

```python
from unoq import fota
fota.upload("~/zephyrproject/build/zephyr/zephyr.signed.bin")
fota.test()      # mark pending
fota.reset()     # MCUboot swaps slot1 -> slot0
fota.confirm()   # keep it
```

**The revert is the point.** An image that boots but is never confirmed is
rolled back on the next reset — verified: swapped to v0.2.0, reset without
confirming, and the board returned to v0.0.0 by itself.

## Interactive shell

The app runs a Zephyr shell on the same UART.

```bash
tio /dev/ttyHS1 -b 115200      # Ctrl-T then q to exit
mcucon                         # or the env.sh helper (Ctrl-C)
```

```
unoq:~$ app status
uptime_ms=12216 ticks=25 blink_ms=500 boots=7 wdt=1 flip=0 sweeps=1043712
unoq:~$ app bars 100 50 25 0
ok bars=4
```

`sweeps` counts LED-matrix refresh passes — see [cpu-bars.md](cpu-bars.md).

Command groups: `app` (yours), `gpio`, `i2c`, `device`, `kernel`, `devmem` —
poke hardware without rebuilding. Drive it from Python via [`unoq.MCU`](mpu.md).

SMP/MCUmgr shares this UART. It registers **no** `mcumgr` command — the shell
detects SMP frames in the byte stream, so `mcumgr: command not found` is
expected, not a fault.

## Debugging

Open this folder in VS Code and pick **Debug (attach)** or **Debug (flash then
run)**. OpenOCD runs on the board; you get breakpoints, memory view, and
peripheral registers decoded from `.vscode/STM32U585.svd` (202 peripherals).

## Tests

```bash
~/hybrid/mcu/ztest.sh                    # native_sim - runs on the MPU, no flashing
~/hybrid/mcu/ztest.sh -p arduino_uno_q   # cross-compile for the board
```

Use `native_sim/native/64`; plain `native_sim` is 32-bit and fails on aarch64
with a `CONFIG_64BIT` error.

Two suites run: `link_protocol` and `bars`. The second compiles
[`mcu/app/src/bars.c`](../mcu/app/src/bars.c) — the firmware's own rasteriser,
not a copy — and checks the drawing rules on the host, because a charlieplexed
panel cannot be read back on the board.

The suite tests [`mcu/app/include/app_proto.h`](../mcu/app/include/app_proto.h)
— the MPU↔MCU contract that `main.c`, the tests and `unoq/mcu.py` all depend on
agreeing. It includes the same header the firmware does, so a change to the
status format or the blink range fails here rather than silently breaking the
Python side. **Editing that header is a protocol change**: update
`unoq/mcu.py` and its tests in the same commit.

See [quality.md](quality.md) for the full gate list and `tools/check.sh`.

## Watchdog and persistent state

The app arms a 4 s task watchdog and keeps a boot counter in NVS
(`storage_partition`).

```
unoq:~$ app hang     # stops the feeder
# ~4s later: boots 5 -> 6, uptime reset
```

`app hang` stops the **main** loop's feeding. Blocking the shell thread instead
would wedge only the shell while main kept feeding, and nothing would reset.

## Gotchas

- `CONFIG_MCUMGR_TRANSPORT_SHELL` **silently disables itself** without
  `CONFIG_BASE64` and `CONFIG_CRC`. Kconfig warns; the build still succeeds.
- `west flash -r openocd` needs `zephyr/boards/arduino/uno_q/support/openocd.cfg`,
  which is **not** upstream — Zephyr's runner resolves board support in-tree and
  crashes on `samefile()` without it (`runners/openocd.py:92`). A canonical copy
  lives in `mcu/board-support/`; re-copy it after a Zephyr version bump.
- The default flash runner is `stm32cubeprogrammer`, which is not installed.
  Always pass `-r openocd`, or just use `zflash`.
