/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The two RGB LEDs wired to the STM32 rather than to Linux.
 *
 * The board has four. Linux drives LED 1 and LED 2 through /sys/class/leds and
 * shows connectivity and unit health there; LED 3 and LED 4 are on this side,
 * named led3_red/green/blue and led4_* in Zephyr's board definition, and
 * nothing had ever driven them.
 *
 * They show the two things Linux is worst placed to report:
 *
 *   LED 3   traffic on the MPU<->MCU link. Blinks once per command actually
 *           handled here. Linux can tell you it SENT something; only this side
 *           knows whether anything arrived.
 *
 *   LED 4   eMMC activity, pushed down from Linux with `app io <busy>`. The
 *           kernel's own mmc0/disk-activity triggers are offered on this board
 *           and do not fire - measured at 0 of 400 samples under sustained
 *           writes - so the MPU samples /sys/block/mmcblk0/stat and forwards
 *           the answer. A round trip for something that should have been local,
 *           and a fair demonstration of the pattern: when one side cannot
 *           observe something, the other side tells it.
 */

#ifndef STATUS_LEDS_H
#define STATUS_LEDS_H

#include <stdbool.h>

/* Milliseconds a blink stays lit. Long enough for an eye, short enough that
 * back-to-back commands still read as separate flashes rather than a solid on.
 */
#define STATUS_LED_BLINK_MS 40

/** Claim the GPIOs. Safe to call when the board has no such LEDs: every entry
 *  point below then does nothing.
 */
void status_leds_init(void);

/** One blink of LED 3 - something arrived over the link and was handled. */
void status_leds_link_activity(void);

/** LED 4: true while Linux reports the eMMC as busy. */
void status_leds_set_io(bool busy);

/** True if the GPIOs were found and claimed. */
bool status_leds_present(void);

#endif /* STATUS_LEDS_H */
