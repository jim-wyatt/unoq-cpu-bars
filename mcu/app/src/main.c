/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * MCU side of the UNO Q hybrid link.
 *
 * Console + interactive shell + SMP/MCUmgr all share lpuart1, the UART wired
 * to the Linux MPU (/dev/ttyHS1). See boards/arduino_uno_q.overlay.
 *
 * The whole firmware is an "app" shell command group the MPU drives over that
 * link, plus one piece of state (panel orientation) persisted in NVS so it
 * survives power cycles and firmware updates.
 *
 * `app bars` is the MCU half of the CPU monitor: the MPU measures
 * (python/unoq/cpu.py), this side draws. See docs/mpu.md.
 *
 * There is no main loop. Everything that runs after init runs on its own:
 * the shell has a thread, and the panel is refreshed from a timer ISR inside
 * matrix.c. A loop here would have nothing to do but sleep, and printing from
 * one would fight the shell prompt.
 */
#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <zephyr/settings/settings.h>
#include <stdlib.h>
#include <string.h>

#include "app_proto.h"
#include "bars.h"
#include "matrix.h"
#include "status_leds.h"

/* Panel state. `frame` is the last thing drawn, kept so a command that changes
 * orientation can redraw it rather than blanking the display. */
static uint8_t frame[APP_MATRIX_LEDS];
static uint8_t bar_pct[APP_BARS_MAX];
static int bar_count;
static uint8_t flip; /* 0/1, persisted - see APP_SETTINGS_FLIP */

/* --- persistent settings ------------------------------------------------- */

static int app_settings_set(const char *name, size_t len, settings_read_cb read_cb, void *cb_arg)
{
	if (settings_name_steq(name, "flip", NULL) && len == sizeof(flip)) {
		return read_cb(cb_arg, &flip, sizeof(flip)) > 0 ? 0 : -EINVAL;
	}
	return -ENOENT;
}

SETTINGS_STATIC_HANDLER_DEFINE(app, "app", NULL, app_settings_set, NULL, NULL);

/* --- shell commands: the MPU drives these over the serial link ----------- */

/* Every command handler starts here. LED 3 is the MCU saying "something
 * arrived and I dealt with it" - which is a different claim from Linux's "I
 * sent something", and the difference is exactly what you want when the link
 * has gone quiet and you are trying to work out which end stopped.
 */
static int cmd_app_status(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_activity();
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	shell_print(sh, APP_STATUS_FMT, k_uptime_get(), flip != 0, matrix_sweeps());
	return 0;
}

/* --- the LED panel -------------------------------------------------------- */

/* Redraw whatever is currently meant to be on screen. Called after anything
 * that changes how a frame maps to pixels, so orientation takes effect
 * immediately instead of at the next update from the MPU. */
static void redraw(void)
{
	if (bar_count > 0) {
		app_bars_render(bar_pct, bar_count, flip != 0, frame);
		matrix_draw(frame);
	}
}

static int cmd_app_bars(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_activity();
	int n = (int)argc - 1;

	if (!app_bars_count_valid(n)) {
		shell_error(sh, "usage: app bars <pct> [pct ...] (1..%d values)", APP_BARS_MAX);
		return -EINVAL;
	}

	/* Validate everything before drawing anything: a partly-applied update
	 * would show a frame that never corresponded to a real measurement. */
	for (int i = 0; i < n; i++) {
		int pct = atoi(argv[i + 1]);

		if (!app_bars_pct_valid(pct)) {
			shell_error(sh, "bar %d: %d outside 0..%d", i, pct, APP_BARS_PCT_MAX);
			return -EINVAL;
		}
		bar_pct[i] = (uint8_t)pct;
	}
	bar_count = n;

	redraw();
	shell_print(sh, "ok bars=%d", n);
	return 0;
}

/* Light exactly one LED. This is how you find out which corner row 0, column 0
 * really is on a board in front of you - the answer depends on which way round
 * it is mounted, so it is not something the firmware can assume. */
static int cmd_app_matrix_px(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_activity();
	int row = atoi(argv[1]);
	int col = atoi(argv[2]);
	int level = atoi(argv[3]);
	int idx;

	ARG_UNUSED(argc);

	if (!app_matrix_pixel_valid(row, col)) {
		shell_error(sh, "row 0..%d, col 0..%d", APP_MATRIX_ROWS - 1, APP_MATRIX_COLS - 1);
		return -EINVAL;
	}
	if (!app_matrix_level_valid(level)) {
		shell_error(sh, "level 0..%d", APP_MATRIX_MAX_LEVEL);
		return -EINVAL;
	}

	/* Same coordinates as `app bars`, flip included, so that once flip is
	 * right for the panel it is right for both. */
	idx = row * APP_MATRIX_COLS + col;
	if (flip) {
		idx = APP_MATRIX_LEDS - 1 - idx;
	}

	memset(frame, 0, sizeof(frame));
	frame[idx] = (uint8_t)level;
	bar_count = 0; /* the bars are gone; do not let a redraw resurrect them */
	matrix_draw(frame);

	shell_print(sh, "ok px row=%d col=%d level=%d", row, col, level);
	return 0;
}

static int cmd_app_matrix_flip(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_activity();
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	flip = !flip;
	settings_save_one(APP_SETTINGS_FLIP, &flip, sizeof(flip));
	redraw();

	shell_print(sh, "ok flip=%d", flip);
	return 0;
}

static int cmd_app_matrix_off(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_activity();
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	bar_count = 0;
	matrix_off();
	shell_print(sh, "ok matrix off");
	return 0;
}

/* Linux pushes eMMC activity down to us, because it cannot show it itself: the
 * kernel's mmc0, disk-activity and disk-write triggers are all offered on this
 * board and none of them fire. So the MPU samples /sys/block/mmcblk0/stat and
 * sends the verdict here. */
static int cmd_app_io(const struct shell *sh, size_t argc, char **argv)
{
	status_leds_link_activity();

	if (argc != 2) {
		shell_error(sh, "usage: app io <0|1>");
		return -EINVAL;
	}

	char *end = NULL;
	long busy = strtol(argv[1], &end, 10);

	if (end == argv[1] || *end != '\0' || busy < 0 || busy > 1) {
		shell_error(sh, "usage: app io <0|1>");
		return -EINVAL;
	}

	status_leds_set_io(busy != 0);
	shell_print(sh, "ok io=%ld", busy);
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(
	matrix_cmds,
	SHELL_CMD_ARG(px, NULL, "Light one LED: app matrix px <row> <col> <level>",
		      cmd_app_matrix_px, 4, 0),
	SHELL_CMD(flip, NULL, "Rotate the panel 180 degrees (persisted)", cmd_app_matrix_flip),
	SHELL_CMD(off, NULL, "Blank the panel and stop the refresh", cmd_app_matrix_off),
	SHELL_SUBCMD_SET_END);

SHELL_STATIC_SUBCMD_SET_CREATE(app_cmds,
			       SHELL_CMD(status, NULL, "uptime, panel orientation, refresh sweeps",
					 cmd_app_status),
			       SHELL_CMD_ARG(bars, NULL, "Draw CPU bars: app bars <pct> [pct ...]",
					     cmd_app_bars, 2, APP_BARS_MAX - 1),
			       SHELL_CMD(matrix, &matrix_cmds, "LED panel control", NULL),
			       SHELL_CMD_ARG(io, NULL, "eMMC activity from the host: app io <0|1>",
					     cmd_app_io, 2, 0),
			       SHELL_SUBCMD_SET_END);
SHELL_CMD_REGISTER(app, &app_cmds, "UNO Q application commands", NULL);

/* --- main ---------------------------------------------------------------- */

int main(void)
{
	printk("\n=== UNO Q MCU up: %s ===\n", CONFIG_BOARD_TARGET);

	/* Load the persisted panel orientation before the matrix comes up, so
	 * the first frame drawn is already the right way round. */
	if (settings_subsys_init() != 0 || settings_load() != 0) {
		printk("settings unavailable - panel orientation not persisted\n");
	}

	/* The panel stays dark until something draws on it, so a failure here
	 * costs the LED matrix and nothing else - the link and the shell both
	 * still come up. */
	/* LED 3 and LED 4. A board without them still runs everything else, so
	 * this only reports. */
	status_leds_init();
	printk("status LEDs %s\n", status_leds_present() ? "ready" : "unavailable");

	if (matrix_init() == 0) {
		printk("LED matrix ready (%dx%d, flip=%d)\n", APP_MATRIX_ROWS, APP_MATRIX_COLS,
		       flip != 0);
	} else {
		printk("LED matrix unavailable\n");
	}

	return 0;
}
