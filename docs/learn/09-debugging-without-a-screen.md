<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Debugging without a screen

The microcontroller has no display, no error dialog, and no way to tell you it
has crashed. It either does the thing or it does not.

This page is the most useful one in the course, because the habits here apply
long after you have forgotten which GPIO does what.

## The only question that matters

When something does not work, the instinct is to change the code and try again.
Resist it. Ask instead:

> **How would I know if this were working?**

If you cannot answer, changing the code is guessing. You will change five things,
one of which fixes it, and you will not know which — and you will not have
learned anything transferable.

Most tools below exist purely to answer that question.

## The ladder

Work up it. Each rung costs more effort than the one before, so do not start at
the top.

### 1. Is it running at all?

```bash
systemctl status unoq-cpu-bars       # Linux side
./.venv/bin/python -c "from unoq import MCU; print(MCU().status())"
```

`uptime_ms` climbing means the microcontroller is alive. If it is *small*, the
chip reset recently — which is itself a large clue.

### 2. What did it say?

```bash
journalctl -u unoq-cpu-bars -n 50 --no-pager
journalctl -b -1 -u unoq-usb-bind          # the PREVIOUS boot
```

That second one matters more than it looks. If something reset the board, the
evidence is in the boot *before* the one you are in. `journalctl --list-boots`
shows you what is available.

### 3. Talk to the chip directly

```bash
sudo systemctl stop unoq-cpu-bars
tio /dev/ttyHS1
```

A prompt means the firmware is running and its shell thread is scheduled. That
single fact eliminates an enormous amount.

### 4. `printf`, honestly

`Serial.print` / `printk` is not beneath you; it is the most-used embedded
debugger there is. Its limits are worth knowing, though: printing takes time, so
it *changes the timing of the thing you are debugging*. A bug that disappears
when you add a print is usually a timing bug, and the print is the cause of the
disappearance.

### 5. A real debugger

Because SWD is wired up, you can halt the processor and inspect it — set
breakpoints, read variables, single-step, look at registers.

In VS Code, the Run panel has **Debug (attach)** and **Debug (flash then run)**.
Underneath, OpenOCD talks SWD over GPIO and `arm-zephyr-eabi-gdb` connects to it.

This is the rung people skip, and it is the one that answers questions the others
cannot: *where exactly* is it stuck.

## Failure modes that look like nothing

Embedded failures are often silent. A catalogue of the ones this board actually
produces:

| Symptom | Very likely cause |
|---|---|
| Flashes and verifies, never runs | BOOT0 pin — chip is in the factory bootloader |
| MCU clearly alive, `/dev/ttyHS1` empty | UART enable pin |
| Terminal shows `ÿ?ÿ<` | Baud rate mismatch, not a fault |
| Serial port busy | `unoq-cpu-bars.service` holds it — stop it |
| Board "dead" after a reboot | `unoq-link.service` did not run |
| Flashed a signed app to a blank chip, nothing | No bootloader in front of it |

Notice how many are *configuration*, not code. On embedded, that ratio is normal.

## The lesson this project learned the hard way

While preparing this board from a factory restore, twelve real bugs were found in
the setup scripts — and **five of them reported success**. A check looked for a
file at a path that had moved. An identity check parsed its input wrongly and
never matched anything, on any board, ever. A verification tested three of the
five things it installed.

They are written up in [clean-board-findings.md](clean-board-findings.md), and
the pattern is worth carrying with you:

> **A check that cannot fail is indistinguishable from a check that always
> passes.** You only find out by running it somewhere it should have failed.

The practical version, for your own code:

- If a check has never failed, you do not know it works. Break something on
  purpose and confirm it complains.
- A warning that scrolls past in a hundred lines of output is not a warning.
- Prefer "refuse to continue" to "warn and carry on" whenever continuing does
  something irreversible.

## Make the invisible visible

The general technique: when you cannot observe the thing, arrange for it to leave
a trace.

- **Counters.** The `sweeps` counter exists so Linux can prove the panel is being
  refreshed without seeing it. Counters cost almost nothing and answer "is this
  loop running?" definitively.
- **A pin and a scope.** Toggle a spare GPIO at the start and end of a routine and
  you can measure its duration exactly, without changing its timing much.
- **An LED.** Crude, always available, needs no host.
- **One status command.** `usb/status.sh` prints everything about the USB stack in
  a fixed order. When you cannot watch a failure happen, a consistent snapshot
  afterwards is the next best thing.

## Try it: break something deliberately

The best way to trust a diagnostic is to see it react. Take the serial port away
and watch the error:

```bash
sudo systemctl start unoq-cpu-bars      # the service grabs /dev/ttyHS1
cd ~/hybrid
./.venv/bin/python -c "
from unoq import MCU
with MCU() as mcu: print(mcu.status())
"
```

It fails, because something else holds the port. Now confirm *that* is the
reason, rather than assuming:

```bash
sudo fuser -v /dev/ttyHS1
sudo systemctl stop unoq-cpu-bars
./.venv/bin/python -c "
from unoq import MCU
with MCU() as mcu: print(mcu.status())
"
sudo systemctl start unoq-cpu-bars
```

You have just practised the whole method: observe the failure, form a specific
hypothesis, test *it* rather than changing code, confirm.

## Check yourself

1. Your firmware works until you remove a `printk`, then fails. What kind of bug
   is this, and why does the print "fix" it?
2. A setup script prints "all packages already current" every time. What would
   convince you that it is true?
3. The board reset five minutes ago and you want to know why. Which command?

Next: what to build once the tour is over.
