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

Fix: `~/hybrid/mcu/link-up.sh`, then re-flash. Check `unoq-link.service` is
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
re-enabled) `arduino-router`. Use `unoq.MCU` as a context manager.

## Serial output is wrong or missing

**A stock Zephyr sample prints nothing.**
Upstream defaults `zephyr,console` to `usart1`, which is the *Arduino header
pins*, not the MPU link. Override to `lpuart1` — see
[`mcu/app/boards/arduino_uno_q.overlay`](../mcu/app/boards/arduino_uno_q.overlay).

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
cp -r ~/hybrid/mcu/board-support/support ~/zephyrproject/zephyr/boards/arduino/uno_q/
```

Needed again after a Zephyr version bump.

**Two errors on every flash:**
`Translation from khz to adapter speed not implemented` and
`Execution of event reset-init failed`. Harmless — the bitbang adapter has no
configurable speed. Programming and verify still succeed.

**Board stops booting after flashing.**
You probably flashed the unsigned `zephyr.hex` over the MCUboot chain. It links
into slot0 with no image header, so the bootloader refuses it. Recover with
`~/hybrid/mcu/flash-all.sh`.

**`native_sim` fails with a `CONFIG_64BIT` error.**
Use `native_sim/native/64` — the plain target is 32-bit and this is aarch64.

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

## Toolchain

**`apt install openocd` does not work.**
Debian ships 0.12.0 (2023), predating libgpiod v2. Rebuild from upstream master:
`sudo bash ~/hybrid/tools/build-openocd.sh`.

**Packages look outdated but must not be upgraded.**
`cbor2` (<6 by `smp`), `pydantic-core` (pinned exactly by `pydantic`), and
Zephyr's own venv pins. See [maintenance.md](maintenance.md).

**An extension "update" will not install.**
`code --install-extension <id> --force` does not bump versions — name the
version explicitly. If that reports *"not found"*, the newer build is x64-only
and you are already current for arm64.

## Recovery

Back to stock Arduino firmware:

```bash
~/hybrid/mcu/restore-arduino-firmware.sh
```

Works even though `~/.arduino15` is gone — the image is in `backup/`.
