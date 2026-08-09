<!--
Copyright (c) 2026 Jim Wyatt
SPDX-License-Identifier: MIT
-->
# Start here

You have an Arduino UNO Q. It looks like an Arduino board, and it is one — but
there is a second, much larger computer on it, and that is what makes it
interesting.

This course teaches you **hybrid MPU + MCU development**: writing software that
runs across two very different processors that share one circuit board, and
getting them to cooperate.

If those letters mean nothing to you yet, good. That is what page one is for.

## Who this is for

Someone who has written programs before — a first or second year computing
student, or anyone comfortable in Python or C — and who has not done embedded
development.

Concretely, you will get the most from this if you already know:

- what a **variable**, a **function** and a **loop** are, in any language
- how to open a **terminal** and run a command in it
- roughly what an **operating system** does

You do **not** need to know: electronics, C, Linux administration, real-time
systems, how a compiler works, or what a "toolchain" is. Every one of those gets
introduced when it first matters, and never before.

## What you will be able to do at the end

- Explain what a microprocessor and a microcontroller each are, and argue about
  which one a given job belongs on.
- Build a program for a microcontroller on a completely different kind of
  computer, and load it onto the chip.
- Send data between the two processors and have each one do the half of the work
  it is suited to.
- Update the microcontroller's software over a wire, safely, so that a bad
  update undoes itself instead of leaving you with a dead board.
- Debug a program that has no screen, no keyboard and no error messages.

The worked example running through all of it is small enough to hold in your
head: **Linux measures how busy its four CPU cores are, and the microcontroller
draws that as four bars of light on an 8×13 LED grid.** It is deliberately
unglamorous. It is also using both halves of the board for exactly what each is
good at, which is the whole point.

## What is actually on the board

Two computers. Not one computer with a helper chip — two, each with its own
processor, its own memory, and its own software.

| | The big one (MPU) | The small one (MCU) |
|---|---|---|
| Chip | Qualcomm QRB2210 | STMicroelectronics STM32U585 |
| Processor | 4 cores, 64-bit | 1 core, 32-bit |
| Memory | ~2–4 GB | 786 KB |
| Runs | Debian Linux | Zephyr, or nothing at all |
| Good at | Networking, storage, AI, anything big | Doing one thing at an exact time |

The rest of this course is largely about that table: why a board would have both,
what changes when you write software for each, and how they talk.

## How to read this

Pages are numbered and meant to be read in order — each one assumes the one
before it. The sidebar tracks where you are.

Three kinds of thing appear on every page:

**Concepts** explain an idea before you use it. Read these.

**Try it** blocks are commands to run on the board. You learn embedded
development by watching real hardware do something, and being surprised.

> **Go deeper** boxes like this one point at the reference documentation —
> [hardware.md](hardware.md), [mcu.md](mcu.md), [usb.md](usb.md) and friends.
> Those pages are written for someone who already knows the material and wants
> the exact detail, including things that took days to work out. They will feel
> dense right now. Come back to them; that is what they are for.

## What you need

- The board, and a USB-C cable that carries **data** (charge-only cables look
  identical and are extremely common — if nothing works, suspect the cable
  first).
- A computer to plug it into.
- Nothing else. No soldering, no extra parts, no oscilloscope.

If your board has not been set up yet, that is what
[bootstrap.sh](../README.md) does, and the next-to-last page explains what it
did and why.

## A warning that will save you an afternoon

Everything in this course happens on real hardware. Real hardware fails in ways
software does not: a cable is faulty, a chip is held in reset, a program runs
but you cannot see any evidence of it.

When something does not work, resist the urge to change your code first. Ask
instead: **how would I know if this were working?** Most of the debugging tools
in this course exist to answer that question, and the habit of asking it is more
valuable than anything else here.

Ready? The board has two computers on it, and they are more different than they
look.
