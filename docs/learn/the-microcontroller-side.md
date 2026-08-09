<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# The microcontroller side

Now the other chip. An STM32U585: one core, 32-bit, 786 KB of RAM, 2 MB of
flash. It is the computer with no screen, no filesystem, no users, and no
`apt`.

The mental adjustment is bigger than the numbers suggest, so this page is about
what *goes away* when you cross to this side, and what you get in return.

## What is not there

**No operating system in the sense you know.** Nothing schedules your program
against other people's programs, because there are no other programs. Your code
is the only code.

**No processes.** You cannot fork. There is nothing to fork into.

**No filesystem.** There is no `open("data.txt")`. If you want to store
something across a reboot, you write it to flash yourself, in a region you set
aside for it.

**No `printf` to a screen.** There is no screen. `printf` exists, but what it
does is push characters out a serial wire and hope somebody is listening.

**No memory protection, usually.** On Linux a bad pointer kills your process and
the system carries on. Here, a bad pointer corrupts something and the board
keeps running with a subtly wrong value, or reboots. There is no supervisor.

**Nothing gets cleaned up.** No garbage collector. Nothing frees your memory when
you are done. Most microcontroller programs never call `malloc` at all, and
allocate everything up front, because running out of memory at hour six is not a
failure you want.

## What you get instead

**Your program starts at power-on and runs until power-off.** Every time.

**Timing you can rely on.** Told to wait 100 microseconds, it waits 100
microseconds. Nothing pre-empts it, because there is nothing else.

**Direct hardware access.** A pin is a bit in a register at a fixed memory
address. You write the bit; the voltage changes. There is no driver, no kernel
call, no permission check — just an assignment.

## Zephyr: an operating system that admits it is small

Our microcontroller does run *something*: **Zephyr**, a real-time operating
system (RTOS).

"Real-time" does not mean fast. It means **predictable**: the system guarantees
an upper bound on how long things take. A slow system that always responds
within 1 ms is real-time; a fast one that usually responds in 10 μs but
occasionally takes 50 ms is not.

Zephyr gives you a few things worth having without giving up that property:

- **Threads**, so different jobs can be written separately, with priorities that
  are actually honoured.
- **Drivers** written to a common interface, so your code says "give me the GPIO
  device" instead of naming a memory address.
- **A device tree** describing what is wired to what, so the same code can build
  for a different board by changing a description rather than the code.
- Optional extras this project uses: a **shell** over the serial port, a
  **settings store** in flash, and an **update protocol**.

It is not Linux. Zephyr compiles into *one binary containing your application
and the OS together*. There is no kernel to boot separately, no init system, no
packages. The whole thing on this board is under 85 KB.

```bash
ls -l ~/zephyrproject/build/zephyr/zephyr.bin
```

```
84752 bytes
```

Eighty-five kilobytes: operating system, drivers, LED matrix code, serial shell,
update machinery, and the application. For comparison, the page you are reading
is about a tenth of that.

## Where the program lives

Two kinds of memory, and the distinction matters constantly here in a way it
never does on Linux:

| | Flash (2 MB) | RAM (786 KB) |
|---|---|---|
| Survives power off | yes | no |
| Holds | your program, constants, saved settings | variables, stack |
| Written | rarely, in blocks, slowly | constantly |

Your program is *executed directly out of flash* — it is not copied into RAM
first the way Linux loads an executable. That is why "flashing" the board means
writing to the chip's permanent storage, and why it takes a few seconds rather
than being instant.

Our application uses **82 KB of 2048 KB**. The chip is 96% empty.

## The shape of a Zephyr program

```c
#include <zephyr/kernel.h>

int main(void)
{
        setup_the_hardware();

        while (1) {
                do_the_work();
                k_msleep(10);   /* let other threads run for 10 ms */
        }
        return 0;
}
```

If you have used an Arduino, `setup()` and `loop()` are the same shape. The
difference is that `k_msleep()` genuinely yields to other threads rather than
spinning, and that there *are* other threads — the shell and the LED refresh are
running alongside your `main`.

## The contract between the two chips

Here is a problem that only exists because there are two computers: the LED
matrix is 8 rows by 13 columns, and **both sides need to know that**.

The C code needs it to drive the panel. The Python code needs it to work out how
tall a bar should be. But C constants cannot be imported into Python.

This project's answer is to write the numbers once, in a header both sides treat
as the source of truth:

```c
/* mcu/app/include/app_proto.h */
#define APP_MATRIX_ROWS      8
#define APP_MATRIX_COLS      13
#define APP_MATRIX_LEDS      (APP_MATRIX_ROWS * APP_MATRIX_COLS)
#define APP_MATRIX_MAX_LEVEL 7
```

Python keeps its own copy — it has no choice — and a **test parses the C header
and fails if the two ever disagree**. The duplication is unavoidable; the test is
what makes it safe. That pattern, a duplicated constant with an automated
argument about it, is worth stealing.

Notice `APP_MATRIX_MAX_LEVEL 7`. The panel is monochrome blue, but each LED has
**8 brightness levels** (0–7), which is why the bars can fade rather than just
being on or off.

## Try it: talk to it directly

The microcontroller runs a shell over the serial wire. You can type at it.

```bash
sudo systemctl stop unoq-cpu-bars    # take the serial port back
tio /dev/ttyHS1                      # or: mcucon
```

Press Enter and you get a prompt. Try:

```
help
kernel version
kernel uptime
app status
```

You are typing into a computer with 786 KB of RAM that has no operating system
in the sense you are used to, and it is answering. Leave with `Ctrl-t q`, then:

```bash
sudo systemctl start unoq-cpu-bars
```

> [!TIP]
> **Go deeper.** [mcu.md](../reference/mcu.md) covers building, flashing, debugging, the
> shell and the firmware tests. [hardware.md](../reference/hardware.md) has the flash layout
> and the pins.

## Check yourself

1. Your MCU program calls `malloc()` in a loop and never frees. On Linux, what
   happens? Here, what happens?
2. Why is 85 KB enough for an operating system here but not on the other chip?
3. The LED matrix dimensions are written in a C header and again in Python. Why
   is that not simply a bug?

Next: both chips are awake — but nothing you wrote runs for the first ten
seconds. What is in charge before that?
