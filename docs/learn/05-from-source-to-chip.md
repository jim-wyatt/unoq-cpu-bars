<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# From source to a running chip

You have written C for the microcontroller. It is a text file on the Linux side.
Getting it running on the other chip involves two steps that do not exist in
ordinary programming: **cross-compiling** it, and **flashing** it.

## Cross-compiling

When you run `gcc hello.c` on this board, you get a program for *this* chip:
64-bit ARM, running Linux, using the system's C library.

The microcontroller is none of those things. It is a 32-bit Cortex-M33, running
no Linux, with a different instruction encoding and a different idea of what a
function call even looks like. A program compiled for the Linux side is not
merely slow on it — it is meaningless.

So you need a second compiler: one that *runs* on this machine but *produces
code for* the other. That is a **cross-compiler**, and by convention it is named
after its target:

```bash
~/zephyr-sdk-1.0.1/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc --version
```

Read the name backwards: `gcc`, for `eabi` (the calling convention), for
`zephyr`, on `arm`. Alongside it are `arm-zephyr-eabi-objdump`, `-gdb`, `-size`
and the rest — the whole toolchain, doubled.

**Try it.** The difference is visible:

```bash
cd ~/zephyrproject/build/zephyr
file zephyr.elf
```

```
ELF 32-bit LSB executable, ARM, EABI5 ... for the STM32
```

Compare that with any Linux program:

```bash
file /bin/ls        # ELF 64-bit LSB pie executable, ARM aarch64
```

Two different machines, one directory.

## Why `west` and not `make`

Zephyr is not one repository. It is Zephyr itself plus dozens of separate
projects — the hardware abstraction layer for STM32, the C library, the
bootloader, cryptography — each versioned independently.

**`west`** is the tool that manages that. It reads a *manifest* listing which
projects at which versions, fetches them, and then drives the actual build.

```bash
cd ~/zephyrproject
./.venv/bin/west list | head
```

The thing worth knowing: `west build` only works **from inside the workspace**.
It finds the workspace by looking at your current directory and walking upwards.
Run it from somewhere else and you get

```
west: unknown command "build"; do you need to run this inside a workspace?
```

which reads like west is broken but means "I cannot see a workspace from here".

This project wraps all of it:

```bash
zbuild ~/hybrid/mcu/app
```

That sets the board, points at the right workspace, builds, and signs the result
(more on signing next page). What comes out:

| File | What it is |
|---|---|
| `zephyr.elf` | Full binary with debug information — what the debugger reads |
| `zephyr.hex` | Addresses and bytes, in text — what the flasher usually wants |
| `zephyr.bin` | Raw bytes only, no addresses |
| `zephyr.signed.hex` | The same program with a signature the bootloader checks |

## Getting it onto the chip

The program is on the Linux filesystem. It needs to be in the microcontroller's
flash memory. There are two ways, and this project uses both.

### SWD — the wires

**SWD** (Serial Wire Debug) is a two-wire protocol built into ARM chips that
gives you near-total control from outside: halt the processor, read and write
any memory address, single-step, and write flash. It works even if the chip's
own program is broken, which is exactly when you need it.

This board has no separate debug probe. Instead, Linux **bit-bangs** SWD
directly on GPIO pins — driving the two wires in software, one edge at a time,
via `libgpiod`. The software doing it is **OpenOCD**:

```bash
zflash ~/zephyrproject/build/zephyr/zephyr.signed.hex
```

```
** Programming Started **
Info : device idcode = 0x30076482 (STM32U57/U58xx)
Info : flash size = 2048 KiB
** Programming Finished **
** Verify Started **
** Verified OK **
```

> Two errors always appear in that output — `Translation from khz to adapter
> speed not implemented` and `Execution of event reset-init failed`. They are
> harmless: the bit-bang adapter has no configurable clock speed, so the
> speed-setting step fails and the flash proceeds anyway. Noisy, not broken.
> [troubleshooting.md](troubleshooting.md) says so too, because everyone asks.

### Over the serial wire

Once a bootloader is installed, you can also send new firmware down the same
UART used for the shell — no debug wires, no halting the processor. That is
**FOTA**, and it is the whole of the next page.

The difference matters: SWD is how you recover a board with broken firmware,
because it does not depend on that firmware working. Serial updates are how you
update a *working* board conveniently.

## The first flash is different

An important wrinkle. This project's firmware is built to run **underneath a
bootloader**, which expects to live at the start of flash with the application
after it. So the very first time, you must write both:

```bash
~/hybrid/mcu/flash-all.sh        # bootloader + application, in order
```

Flash only the signed application onto a blank chip and nothing runs. The
application is sitting at an address nothing jumps to, with no bootloader in
front of it to do the jumping. The chip is fine; it just has no starting point.

## Try it: change something and watch it happen

```bash
sudo systemctl stop unoq-cpu-bars
cd ~/hybrid
zbuild mcu/app                                   # ~1 minute
zflash ~/zephyrproject/build/zephyr/zephyr.signed.hex
./.venv/bin/python -c "
from unoq import MCU
with MCU() as mcu: print(mcu.status())
"
sudo systemctl start unoq-cpu-bars
```

Look at `uptime_ms` in the output: it will be a few seconds. You just restarted a
computer.

## Check yourself

1. Why can't you run `gcc` on your MCU source and flash the result?
2. `west build` says "unknown command". The binary exists and works. Why?
3. You flash a signed application onto a completely blank chip. Verification
   passes and nothing runs. What is missing?

Next: what those 104 LEDs are actually doing, and why the number 962 matters.
