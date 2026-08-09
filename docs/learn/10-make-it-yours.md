<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Make it yours

You have been through the whole stack: two processors, the wire between them, the
toolchain, the display, safe updates, the USB gadget, and how to find out what is
wrong. This page is about what to do next, because reading about embedded
development is not the same as doing any.

## What you actually learned

Worth naming, because most of it is not about this board:

- **Which half a job belongs on.** Timing determinism versus throughput and
  convenience. This is the transferable skill.
- **Two computers with no shared memory** must serialise, frame, and tolerate
  failure — the same discipline as any distributed system, at 2 cm.
- **Cross-compilation**: the machine you build on need not be the machine you run
  on, and the toolchain is named after its target.
- **Bootloaders and probation**: try the new thing, fall back if it does not
  confirm itself. You saw the identical pattern in firmware updates and in the USB
  bind guard.
- **Testing what has no hardware in it.** `bars.c` is tested on a laptop because
  the arithmetic was kept separate from the pins.
- **Checks that cannot fail are not checks.**

## Things to build, roughly by effort

### Small — an afternoon

**Put the CPU temperature on the matrix.** The zones are already there:

```bash
cat /sys/class/thermal/thermal_zone3/temp
```

`unoq/cpu.py` shows the shape: read a file, turn it into a number, send bar
heights. Do it as a second mode of the existing demo.

**Use the board's LEDs.** Six of them, unused:

```bash
ls /sys/class/leds/
```

Wire one to something meaningful — the USB link being up, the guard having
tripped — and you have status you can read across a room with no terminal at all.

**Scroll text on the matrix.** 8×13 is enough for a font if you are careful, and
it makes you think hard about where the frame buffer lives and who owns the
timing.

### Medium — a weekend

**Read a real sensor over I²C.** The Qwiic connector is right there, the buses are
enabled, and `smbus2` is already installed. A temperature or distance sensor sampled
by the *microcontroller* at an exact interval, with Linux only displaying it, is
this project's architecture applied to something new.

**Add a serial console over USB.** The kernel has a CDC-ACM gadget function. Add
it and your laptop gets a COM port that is the MCU's console — no SSH needed.

**Make the microcontroller do something Linux cannot.** Generate a precise pulse
train; measure a pulse width to the microsecond; bit-bang a protocol. Anything
where being 2 ms late is a failure.

### Larger — a project

**Something with a real deadline.** A closed-loop controller: read, decide, act,
every N milliseconds without exception. This is where determinism stops being an
abstraction.

**Arm the watchdog.** `/dev/watchdog0` exists and is unused. Everything protecting
this board today is userspace, and none of it helps if the kernel wedges.

**Use the empty microcontroller.** The application is 82 KB of 2048 KB. The chip
is 96% empty.

## Where the open work is

The repository's [issues](https://github.com/jim-wyatt/unoq-cpu-bars/issues) list
real gaps, each written up with what was measured and why it matters — the
watchdog, the LEDs, the CDC-ACM console, the unused I²C and SPI, the thermal
zones, and the mostly-empty MCU flash.

They are deliberately not just "TODO: do X". Each says what is there now, what it
would buy, and what to be careful of. Several have a defensible *opposite*
answer — the I²C one argues that if nothing is going to use those libraries, the
honest move is to remove them rather than keep installing a C extension nobody
imports.

## Before you change anything

The project has quality gates, and running them is faster than finding out later:

```bash
~/hybrid/tools/check.sh              # everything
~/hybrid/tools/check.sh --fast       # skip the slow MCU suite
~/hybrid/tools/check.sh python       # one area
```

Lint, formatting, strict type checking, tests at 100% coverage, shell linting, C
formatting, and the MCU test suites. The coverage gate is a ratchet: new code
needs a test.

If you add a page to this course, it is markdown in `docs/learn/`, and:

```bash
./.venv/bin/unoq-build-docs
```

renders it into the site the board serves and the drive carries. **Test every
command you write down.** One of the pages in this course claimed a measurement
that turned out to be wrong the first time it was actually run, and it was only
caught because someone ran it.

## Where things are

| | |
|---|---|
| `mcu/app/` | The firmware: `main.c`, `matrix.c` (the driver), `bars.c` (the arithmetic) |
| `mcu/app/include/app_proto.h` | The contract both sides agree on |
| `python/unoq/` | The Linux side: `cpu.py`, `mcu.py`, `fota.py`, `link.py` |
| `usb/` | The gadget, the guards, `status.sh` |
| `provision/` | Turning a factory board into this one, one numbered step at a time |
| `docs/` | This course, and the reference it links into |

## Finally

The reference documentation — [hardware.md](hardware.md), [mcu.md](mcu.md),
[mpu.md](mpu.md), [usb.md](usb.md), [troubleshooting.md](troubleshooting.md) —
will read very differently now than it would have on day one. It is written for
someone who knows what you now know, and it contains things that cost real days
to discover, like the two undocumented GPIO lines that make the difference
between a working board and one that looks dead.

That is the point of a learning path: not to replace the hard material, but to
get you to where it makes sense.

Go and build something that has to happen on time.
