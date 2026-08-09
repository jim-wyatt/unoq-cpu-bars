/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * LED 3 and LED 4 - the two RGB LEDs on the MCU side. See status_leds.h.
 */

#include "status_leds.h"

#include <zephyr/drivers/gpio.h>
#include <zephyr/kernel.h>

/* The board definition describes these as gpio-leds children. Using the node
 * labels rather than the led0/led1 aliases on purpose: the aliases only cover
 * two of the six channels (led3_green and led3_red), and colour is the whole
 * point here.
 */
#define LED_SPEC(node) GPIO_DT_SPEC_GET_OR(DT_NODELABEL(node), gpios, {0})

static const struct gpio_dt_spec led3[] = {
	LED_SPEC(led3_red),
	LED_SPEC(led3_green),
	LED_SPEC(led3_blue),
};
static const struct gpio_dt_spec led4[] = {
	LED_SPEC(led4_red),
	LED_SPEC(led4_green),
	LED_SPEC(led4_blue),
};

enum { CH_RED = 0, CH_GREEN = 1, CH_BLUE = 2 };

static bool ready;

/* Turning the blink off is deferred rather than slept through: this is called
 * from the shell thread, and a 40 ms sleep there would add 40 ms to every
 * command's round trip - measurable, and for a status LED, absurd.
 */
static void link_blink_off(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(link_off_work, link_blink_off);

static void set_chan(const struct gpio_dt_spec *spec, int on)
{
	if (spec->port == NULL) {
		return;
	}
	(void)gpio_pin_set_dt(spec, on);
}

static void set_rgb(const struct gpio_dt_spec *led, int r, int g, int b)
{
	set_chan(&led[CH_RED], r);
	set_chan(&led[CH_GREEN], g);
	set_chan(&led[CH_BLUE], b);
}

static bool claim(const struct gpio_dt_spec *led, size_t n)
{
	bool any = false;

	for (size_t i = 0; i < n; i++) {
		if (led[i].port == NULL) {
			continue;
		}
		if (!gpio_is_ready_dt(&led[i])) {
			continue;
		}
		if (gpio_pin_configure_dt(&led[i], GPIO_OUTPUT_INACTIVE) != 0) {
			continue;
		}
		any = true;
	}
	return any;
}

void status_leds_init(void)
{
	bool a = claim(led3, ARRAY_SIZE(led3));
	bool b = claim(led4, ARRAY_SIZE(led4));

	ready = a || b;
	if (!ready) {
		return;
	}
	set_rgb(led3, 0, 0, 0);
	set_rgb(led4, 0, 0, 0);
}

bool status_leds_present(void)
{
	return ready;
}

static void link_blink_off(struct k_work *work)
{
	ARG_UNUSED(work);
	set_rgb(led3, 0, 0, 0);
}

void status_leds_link_activity(void)
{
	if (!ready) {
		return;
	}
	set_rgb(led3, 0, 0, 1);
	/* Reschedule rather than stack: a burst of commands should look like a
	 * flicker that stays lit while the burst lasts, not a queue of work
	 * items each turning it off at its own moment.
	 */
	(void)k_work_reschedule(&link_off_work, K_MSEC(STATUS_LED_BLINK_MS));
}

void status_leds_set_io(bool busy)
{
	if (!ready) {
		return;
	}
	/* Green, not blue: LED 3 is already blue for link traffic, and two
	 * LEDs blinking the same colour next to each other are impossible to
	 * tell apart at a glance.
	 */
	set_rgb(led4, 0, busy ? 1 : 0, 0);
}
