/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The two RGB LEDs wired to the STM32 rather than to Linux.
 *
 * The board has four. Linux drives LED 1 and LED 2 through /sys/class/leds and
 * shows connectivity and unit health there; LED 3 and LED 4 are on this side,
 * named led3_red/green/blue and led4_* in Zephyr's board definition.
 *
 * WHAT THEY SHOW, AND WHY NOT THE OBVIOUS THINGS
 * ----------------------------------------------
 * The first attempt used them for link traffic and eMMC activity. Both were
 * wrong, and the board made it obvious:
 *
 *   Blinking on every command received made LED 3 a CLOCK. cpubars sends a
 *   frame every 0.5s, so the LED blinked every 0.5s, forever, saying only
 *   "the demo is running" - which the matrix already says, in more detail.
 *   An indicator whose period is set by someone else's timer carries no
 *   information.
 *
 *   eMMC activity cannot be shown from here at any useful resolution. Linux
 *   samples the counter twice a second and pushes the answer down a 115200
 *   link; a real activity light flickers on individual transfers. What you got
 *   was a lamp that sat on through a copy and off otherwise - which the CPU
 *   bars beside it already imply.
 *
 * So both now show things ONLY THIS CHIP KNOWS, and that change slowly enough
 * that every transition means something:
 *
 *   LED 3   the firmware's own identity.
 *           green   running a CONFIRMED image - this is what stays after a reset
 *           yellow  running an UNCONFIRMED image, on MCUboot probation. The
 *                   next reset reverts it. Invisible otherwise unless you go
 *                   and read the slot table, and precisely what you want to see
 *                   on the hardware after an update.
 *           red     a subsystem failed to start (see main.c)
 *
 *   LED 4   whether the MPU is still talking.
 *           green   heard from Linux within the last few seconds
 *           red     silent for longer than that
 *
 * LED 4 is the inverse of the blink it replaces. A tick tells you nothing; the
 * tick STOPPING is the news, and it is news Linux cannot deliver - a host that
 * has stopped talking cannot report that it stopped talking. This is the only
 * indicator on the board that says something about the other chip's health.
 */

#ifndef STATUS_LEDS_H
#define STATUS_LEDS_H

#include <stdbool.h>

/* How long the MPU may be quiet before LED 4 calls the link stale.
 *
 * cpubars draws twice a second, and the MCU shell is also poked by hand, so a
 * few seconds of silence is comfortably abnormal without being twitchy about a
 * host that paused to do something else.
 */
#define STATUS_LINK_STALE_MS 4000

/** Claim the GPIOs. Safe on a board without them: everything below then does
 *  nothing, and status_leds_present() says so.
 */
void status_leds_init(void);

/** Note that something arrived from the MPU. Cheap - a timestamp, no I/O. */
void status_leds_link_seen(void);

/** LED 3: green for a confirmed image, yellow for one still on probation. */
void status_leds_set_image_confirmed(bool confirmed);

/** LED 3: red, and it stays red. For a subsystem that failed to come up. */
void status_leds_set_fault(void);

/** True if the GPIOs were found and claimed. */
bool status_leds_present(void);

#endif /* STATUS_LEDS_H */
