# Troubleshooting

Symptom → cause. Most of these cost real time to diagnose the first time.

## The board looks dead

**Firmware flashed and "Verified OK", but nothing runs.**
BOOT0 (`gpiochip1` line 37) is high or floating, so the STM32 booted its ROM
bootloader instead of your image. Confirm by reading the PC — anything around
`0x0bf9xxxx` is ROM, not flash:

```bash
/opt/openocd/bin/openocd -s /opt/openocd -f /opt/openocd/openocd_gpiod.cfg \
  -c init -c "reset run" -c "sleep 1000" -c halt -c "reg pc" -c shutdown
```

Fix: `~/two-computers-one-board/mcu/link-up.sh`, then re-flash. Check `unoq-link.service` is
enabled so it survives reboots.

**`/dev/ttyHS1` reads zero bytes, but the MCU seems fine.**
The UART link-enable (`gpiochip1` line 70) is not driven high. The MCU
transmits happily into a disconnected path. Same fix: `link-up.sh`.

To prove the MCU is actually alive and transmitting, check `LPUART1` — `CR1`
should show UE/TE/RE set (`0x2d`) and `ISR` should show TC/TXE:

```
mdw 0x46002400 1    # CR1
mdw 0x4600241c 1    # ISR
```

**The link was fine until I inspected it.**
You ran `gpioget` on line 37 or 70. It requests the line as an input, which drops
the drive — reading these pins breaks them. The values it returns (`37=active`,
`70=inactive`) look like a diagnosis but are just the floating state you created.
Fix: `link-up.sh`. Check them non-destructively instead:

```bash
gpioinfo -c gpiochip1 37 70      # both must say `output`
```

See [hardware.md](hardware.md#the-two-gpios-nobody-documents).

**`Device or resource busy` on `/dev/ttyHS1`.**
Something else holds it — `tio`, `mcucon`, a stale Python handle, or (if it were
re-enabled) `arduino-router`. Use `unoq.MCU` as a context manager. If nothing
appears to hold it, see
[the note on `tio` below](#tio-can-leave-the-port-unusable-after-it-exits).

## Serial output is wrong or missing

**A stock Zephyr sample prints nothing.**
Upstream defaults `zephyr,console` to `usart1`, which is the *Arduino header
pins*, not the MPU link. Override to `lpuart1` — see
[`mcu/app/boards/arduino_uno_q.overlay`](../../mcu/app/boards/arduino_uno_q.overlay).

**Shell prompt fights with application output.**
Do not `printk` on a timer when the shell is enabled. Expose a shell command
instead and let the MPU poll it.

## Build and flash

**`west flash` fails with `stm32cubeprogrammer not found`.**
That is the board's default runner and it is not installed. Use `-r openocd`,
or `zflash`.

**`west flash -r openocd` crashes in `samefile()`.**
Zephyr's runner resolves board support in-tree and `uno_q` ships no `support/`
directory (`runners/openocd.py:92`). Restore it:

```bash
cp -r ~/two-computers-one-board/mcu/board-support/support ~/zephyrproject/zephyr/boards/arduino/uno_q/
```

Needed again after a Zephyr version bump.

**Two errors on every flash:**
`Translation from khz to adapter speed not implemented` and
`Execution of event reset-init failed`. Harmless — the bitbang adapter has no
configurable speed. Programming and verify still succeed.

**Board stops booting after flashing.**
You probably flashed the unsigned `zephyr.hex` over the MCUboot chain. It links
into slot0 with no image header, so the bootloader refuses it. Recover with
`~/two-computers-one-board/mcu/flash-all.sh`.

**`native_sim` fails with a `CONFIG_64BIT` error.**
Use `native_sim/native/64` — the plain target is 32-bit and this is aarch64.

**`Error finding board: arduino_uno_q` / `No module named 'jsonschema'`.**
Something configured `mcu/app` with a bare `cmake` instead of `west`, so
`list_boards.py` ran under `/usr/bin/python`. Zephyr's script dependencies live
only in `~/zephyrproject/.venv`, which is the interpreter `west` uses.

Usually the culprit is the **CMake Tools extension**: it prompts on open, writes
`cmake.sourceDirectory` into `.vscode/settings.json` itself, and then configures
into a stray `two-computers-one-board/build/` on every window open. It is listed under
`unwantedRecommendations` — uninstall it, and delete both the setting and the
directory. Build with the **MCU: build** task (`zbuild.sh`); `clangd` needs
nothing from CMake Tools, only the `compile_commands.json` that build symlinks.

## SMP / MCUmgr

**`mcumgr: command not found` in the shell.**
Expected. SMP-over-shell registers no command; the shell sniffs SMP frames out
of the byte stream.

**SMP times out right after using the shell.**
The UART needs a settle delay between handles. `unoq` does this for you; raw
scripts must close, sleep, then open.

**MCUmgr features silently missing.**
`CONFIG_MCUMGR_TRANSPORT_SHELL` disables itself without `CONFIG_BASE64` and
`CONFIG_CRC`. Kconfig warns but the build succeeds — check the generated
`.config`, not just the build log.

## LED matrix

**The panel stays dark.**
It starts lazily — nothing is lit until the first `app bars` or `app matrix px`.
After that, check `sweeps` in `app status` is climbing by ~962/s: a count stuck
at zero means the refresh timer never started, and the boot log says `LED matrix
unavailable` if `gpiof` or `timers17` were missing from the devicetree.

**The bars hang from the top instead of standing on the bottom.**
The panel's orientation depends on how the board is mounted and the firmware
cannot know it. `app matrix flip` rotates 180° and stores that in NVS.

**`app bars` says `range` or `usage`.**
One to seven values, each 0..100. `unoq.MCU.bars()` clamps percentages for you
but raises on the wrong *number* of bars — see [mpu.md](mpu.md#cpu-bars-on-the-led-matrix).

**Something else on PF0..PF10 misbehaves.**
Those eleven pins are the matrix. The refresh ISR retakes them every 10 µs, so
any other user of them will lose. PF11–PF15 are untouched.

**`/dev/ttyHS1` is suddenly "device busy" — `mcucon`, `tio` and `unoq.MCU` all
fail.**
The boot service is probably running and holding the port open.
`sudo systemctl stop unoq-cpu-bars`. Flashing over SWD is unaffected.

Since [#55] `unoq.MCU` reports this properly — it names the process holding the
port and the command to stop it, instead of surfacing a bare `errno 16`.

> ### `tio` can leave the port unusable after it exits
>
> This is the confusing one, and it looks like a hardware fault.
>
> There are **two different locks** on a serial port and they do not see each
> other. `flock` — which is what pyserial's `exclusive=True` takes — is
> *advisory*: it stops another pyserial caller and nothing else. `TIOCEXCL` —
> which is what `tio` and `screen` set — is enforced by the kernel, and any
> later `open()` fails with `EBUSY`.
>
> **`TIOCEXCL` is per-tty state, cleared only when the *last* file descriptor
> closes.** `unoq-cpu-bars.service` holds the port open permanently. So a `tio`
> that is killed rather than quit cleanly can leave the flag set with nothing
> to show for it:
>
> ```console
> $ sudo lsof /dev/ttyHS1
> unoq-cpu- 255481 arduino 3uW CHR 237,1 0t0 149 /dev/ttyHS1
> $ hpy -c "import os; os.open('/dev/ttyHS1', os.O_RDWR)"
> OSError: [Errno 16] Device or resource busy
> ```
>
> The only process listed is the one that has always had it open and is not the
> cause. Nothing in `lsof` explains the `EBUSY`, because the flag outlives the
> process that set it.
>
> ```bash
> sudo systemctl restart unoq-cpu-bars   # closes every fd, clearing the flag
> ```
>
> `unoq.MCU` now sets `TIOCEXCL` itself, which mostly closes this off: `tio` can
> no longer open the port while the service is running, so it cannot flag it.
> `tio` **waits silently** rather than reporting the refusal — it retries by
> default, so it looks like a hang. That is the port being held, not a fault.

[#55]: https://github.com/jim-wyatt/two-computers-one-board/issues/55

**The panel is stuck showing an old frame.**
Something killed the daemon with SIGTERM instead of SIGINT, so the cleanup that
blanks it never ran. `app matrix off`, or `hpy -c "from unoq import MCU;
MCU().matrix_off()"`. The systemd unit sets `KillSignal=SIGINT` to avoid this.

**`unoq-cpu-bars: command not found`.**
The console script only appears after re-running the editable install.
`python -m unoq.cpubars` works regardless.

## Toolchain

**`apt install openocd` does not work.**
Debian ships 0.12.0 (2023), predating libgpiod v2. Rebuild from upstream master:
`sudo bash ~/two-computers-one-board/tools/build-openocd.sh`.

**Packages look outdated but must not be upgraded.**
`cbor2` (<6 by `smp`), `pydantic-core` (pinned exactly by `pydantic`), and
Zephyr's own venv pins. See [the README](../../README.md#things-that-look-out-of-date-but-are-not).

**An extension "update" will not install.**
`--install-extension <id> --force` does not bump versions — name the version
explicitly. If that reports *"not found"*, that version has no build for this
board (**linux-arm64**); publishers routinely ship x64 and Windows first.

Do **not** read "not found" as "already current" — a newer arm64 build may
exist *below* the version you tried. `check-versions.sh` reports the newest
arm64-installable version, which is the one to name. To see every build:

```bash
~/two-computers-one-board/tools/check-versions.sh          # arm64-correct
```

Use `…/server/bin/code-server` to install; the `remote-cli/code` binary needs a
live VS Code session and is not on `PATH`.

## Recovery

Back to stock Arduino firmware:

```bash
~/two-computers-one-board/mcu/restore-arduino-firmware.sh
```

Works even though `~/.arduino15` is gone, provided you copied the stock image
off the board first. It is Arduino's build, so this repository does not ship it
— see [THIRD-PARTY.md](../third-party.md). Point `STOCK_FW` at your copy.
