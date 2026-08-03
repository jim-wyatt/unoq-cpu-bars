# MCU workflow

Firmware for the STM32U585, built with stock Zephyr + west. No Arduino tooling.

```
~/zephyrproject/      west workspace, Zephyr v4.4.1, board `arduino_uno_q`
~/zephyr-sdk-1.0.1/   Zephyr SDK (arm-zephyr-eabi)
```

## Build

```bash
zbuild ~/hybrid/mcu/app                      # this project's app
zbuild samples/hello_world                   # any upstream Zephyr sample
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
zbuild ~/hybrid/mcu/app        # -> ~/zephyrproject/build
zbuild samples/hello_world     # -> ~/zephyrproject/build-hello_world
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

`fota.images()` reports the slot table, and the image version in it is how you
tell which build is actually running after a swap.

## Interactive shell

The app runs a Zephyr shell on the same UART.

```bash
tio /dev/ttyHS1 -b 115200      # Ctrl-T then q to exit
mcucon                         # or the env.sh helper (Ctrl-C)
```

```
unoq:~$ app status
uptime_ms=12216 flip=0 sweeps=1043712
unoq:~$ app bars 100 50 25 0
ok bars=4
```

`sweeps` counts LED-matrix refresh passes — see [mpu.md](mpu.md#is-it-actually-running).

Command groups: `app` (yours), `gpio`, `i2c`, `device`, `kernel`, `devmem` —
poke hardware without rebuilding. Drive any of them from Python with
[`unoq.MCU.cmd()`](mpu.md#the-unoq-package).

SMP/MCUmgr shares this UART. It registers **no** `mcumgr` command — the shell
detects SMP frames in the byte stream, so `mcumgr: command not found` is
expected, not a fault.

## What the firmware is

[`mcu/app/src/main.c`](../mcu/app/src/main.c) is the `app` shell command group
and nothing else. `main()` loads the persisted panel orientation, brings up the
matrix, and returns — there is no main loop, because everything that runs after
init runs on its own: the shell has its own thread, and the panel is refreshed
from a timer ISR inside `matrix.c`.

One byte of state is persisted in NVS (`storage_partition`): the panel
orientation set by `app matrix flip`. That is a property of how the board is
mounted rather than of the running session, so it survives power cycles and
firmware updates.

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

Two suites run, 26 cases in total:

- **`bars`** compiles [`mcu/app/src/bars.c`](../mcu/app/src/bars.c) — the
  firmware's own rasteriser, not a copy — and checks the drawing rules on the
  host, because a charlieplexed panel cannot be read back on the board. These
  are the only place the drawing rules are checked at all, so they assert
  properties (bars stay in their columns, height never falls as load rises,
  rotation is a true rotation) rather than a few remembered frames.
- **`link_protocol`** tests
  [`mcu/app/include/app_proto.h`](../mcu/app/include/app_proto.h), the contract
  that `main.c`, these tests and `unoq/mcu.py` all depend on agreeing.

### The MCU suite tests the firmware, not a copy of it

`app_proto.h` holds the MPU↔MCU contract: the `app status` format string, the
panel geometry, the bar limits, the settings key. Three parties depend on it
agreeing —

```
mcu/app/src/main.c        produces the status line, validates bars
mcu/tests/link_protocol/  tests these definitions directly
python/unoq/mcu.py        parses the status line, calls `app bars`
```

— so the test includes the same header `main.c` does. It used to keep its own
copy of the range check and format string, which meant it could not fail when
the firmware changed. Confirmed by mutation: renaming `uptime_ms=` in the header
now fails the suite.

**A change to that header is a protocol change.** Update `unoq/mcu.py` and its
tests in the same commit. On the Python side,
`python/tests/test_contract.py` parses the header and fails if the panel
constants in `unoq/mcu.py` drift from the firmware's.

See [the README](../README.md#quality-gates) for the full gate list.

## Upgrading Zephyr

After a version bump, re-copy the OpenOCD board support that Zephyr's runner
needs and that is not upstream:

```bash
cp -r ~/hybrid/mcu/board-support/support ~/zephyrproject/zephyr/boards/arduino/uno_q/
```

Also check the SDK requirement — Zephyr's `SDK_VERSION` file states it
(v4.4.x wants SDK 1.0.1; v4.3.0 wanted 0.17.4).

The C style is Zephyr's, copied into this repo the same way, so re-copy it too
and re-run the gate — upstream does change it between releases:

```bash
cp ~/zephyrproject/zephyr/.clang-format ~/hybrid/.clang-format
~/hybrid/tools/check.sh c
```

## Gotchas

- `CONFIG_MCUMGR_TRANSPORT_SHELL` **silently disables itself** without
  `CONFIG_BASE64` and `CONFIG_CRC`. Kconfig warns; the build still succeeds.
- `west flash -r openocd` needs `zephyr/boards/arduino/uno_q/support/openocd.cfg`,
  which is **not** upstream — Zephyr's runner resolves board support in-tree and
  crashes on `samefile()` without it (`runners/openocd.py:92`). The canonical
  copy lives in `mcu/board-support/`; re-copy it with the command under
  [Upgrading Zephyr](#upgrading-zephyr).
- The default flash runner is `stm32cubeprogrammer`, which is not installed.
  Always pass `-r openocd`, or just use `zflash`.
