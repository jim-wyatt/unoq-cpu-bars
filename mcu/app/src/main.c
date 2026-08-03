/*
 * MCU side of the UNO Q hybrid link.
 *
 * Console + interactive shell + SMP/MCUmgr all share lpuart1, the UART wired
 * to the Linux MPU (/dev/ttyHS1). See boards/arduino_uno_q.overlay.
 *
 * Demonstrates the three things a real deployment needs beyond blinking:
 *   - a hardware watchdog, fed from the work loop
 *   - persistent state in storage_partition (survives power loss)
 *   - an "app" shell command group the MPU can drive
 *
 * The `app bars` command is the MCU half of the CPU monitor: the MPU measures
 * (python/unoq/cpu.py), this side draws. See docs/cpu-bars.md.
 *
 * The main loop deliberately does NOT print on a timer - that would fight the
 * shell prompt.
 */
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/shell/shell.h>
#include <zephyr/settings/settings.h>
#include <zephyr/task_wdt/task_wdt.h>
#include <zephyr/drivers/watchdog.h>
#include <stdlib.h>
#include <string.h>

#include "app_proto.h"
#include "bars.h"
#include "matrix.h"

static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

static atomic_t blink_ms = ATOMIC_INIT(250); /* v2 marker for FOTA test */
static uint32_t ticks;
static uint32_t boot_count; /* persisted in NVS across power cycles */
static atomic_t feed_wdt = ATOMIC_INIT(1);
static int wdt_channel = -1;

/* Panel state. `frame` is the last thing drawn, kept so a command that changes
 * orientation can redraw it rather than blanking the display. */
static uint8_t frame[APP_MATRIX_LEDS];
static uint8_t bar_pct[APP_BARS_MAX];
static int bar_count;
static uint8_t flip; /* 0/1, persisted - see APP_SETTINGS_FLIP */

/* --- persistent settings ------------------------------------------------- */

static int app_settings_set(const char *name, size_t len, settings_read_cb read_cb, void *cb_arg)
{
	if (settings_name_steq(name, "boots", NULL) && len == sizeof(boot_count)) {
		return read_cb(cb_arg, &boot_count, sizeof(boot_count)) > 0 ? 0 : -EINVAL;
	}
	if (settings_name_steq(name, "flip", NULL) && len == sizeof(flip)) {
		return read_cb(cb_arg, &flip, sizeof(flip)) > 0 ? 0 : -EINVAL;
	}
	return -ENOENT;
}

SETTINGS_STATIC_HANDLER_DEFINE(app, "app", NULL, app_settings_set, NULL, NULL);

/* --- shell commands: the MPU drives these over the serial link ----------- */

static int cmd_app_status(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	shell_print(sh, APP_STATUS_FMT, k_uptime_get(), ticks, (int)atomic_get(&blink_ms),
		    boot_count, wdt_channel >= 0, flip != 0, matrix_sweeps());
	return 0;
}

static int cmd_app_blink(const struct shell *sh, size_t argc, char **argv)
{
	int ms;

	if (argc != 2) {
		shell_error(sh, "usage: app blink <ms>");
		return -EINVAL;
	}
	ms = atoi(argv[1]);
	if (!app_blink_ms_valid(ms)) {
		shell_error(sh, "range %d..%d", APP_BLINK_MS_MIN, APP_BLINK_MS_MAX);
		return -EINVAL;
	}
	atomic_set(&blink_ms, ms);
	shell_print(sh, "ok blink_ms=%d", ms);
	return 0;
}

/* Prove the watchdog bites: tell the *main* loop to stop feeding it.
 * Blocking this shell thread instead would not work - the main thread would
 * keep feeding happily and only the shell would wedge. */
static int cmd_app_hang(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	atomic_set(&feed_wdt, 0);
	shell_print(sh, "watchdog feeding stopped - reset expected within ~4s");
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
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);

	bar_count = 0;
	matrix_off();
	shell_print(sh, "ok matrix off");
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(
	matrix_cmds,
	SHELL_CMD_ARG(px, NULL, "Light one LED: app matrix px <row> <col> <level>",
		      cmd_app_matrix_px, 4, 0),
	SHELL_CMD(flip, NULL, "Rotate the panel 180 degrees (persisted)", cmd_app_matrix_flip),
	SHELL_CMD(off, NULL, "Blank the panel and stop the refresh", cmd_app_matrix_off),
	SHELL_SUBCMD_SET_END);

SHELL_STATIC_SUBCMD_SET_CREATE(
	app_cmds,
	SHELL_CMD(status, NULL, "uptime, ticks, blink period, boot count", cmd_app_status),
	SHELL_CMD_ARG(blink, NULL, "Set blink period: app blink <ms>", cmd_app_blink, 2, 0),
	SHELL_CMD_ARG(bars, NULL, "Draw CPU bars: app bars <pct> [pct ...]", cmd_app_bars, 2,
		      APP_BARS_MAX - 1),
	SHELL_CMD(matrix, &matrix_cmds, "LED panel control", NULL),
	SHELL_CMD(hang, NULL, "Stop feeding the watchdog (forces a reset)", cmd_app_hang),
	SHELL_SUBCMD_SET_END);
SHELL_CMD_REGISTER(app, &app_cmds, "UNO Q application commands", NULL);

/* --- main ---------------------------------------------------------------- */

int main(void)
{
	const struct device *wdt = DEVICE_DT_GET_OR_NULL(DT_ALIAS(watchdog0));

	printk("\n=== UNO Q MCU up: %s ===\n", CONFIG_BOARD_TARGET);

	/* Persistent boot counter. */
	if (settings_subsys_init() == 0 && settings_load() == 0) {
		boot_count++;
		settings_save_one(APP_SETTINGS_BOOTS, &boot_count, sizeof(boot_count));
		printk("boot count: %u\n", boot_count);
	} else {
		printk("settings unavailable - boot count not persisted\n");
	}

	/* Task watchdog. Falls back to a pure software timer if the SoC
	 * watchdog is not exposed in the devicetree. */
	if (task_wdt_init(wdt) == 0) {
		wdt_channel = task_wdt_add(APP_WDT_TIMEOUT_MS, NULL, NULL);
		printk("watchdog armed (%dms), channel %d\n", APP_WDT_TIMEOUT_MS, wdt_channel);
	} else {
		printk("watchdog unavailable\n");
	}

	/* The panel stays dark until something draws on it, so a failure here
	 * costs the LED matrix and nothing else - the link, the shell and the
	 * watchdog all still come up. */
	if (matrix_init() == 0) {
		printk("LED matrix ready (%dx%d, flip=%d)\n", APP_MATRIX_ROWS, APP_MATRIX_COLS,
		       flip != 0);
	} else {
		printk("LED matrix unavailable\n");
	}

	if (!gpio_is_ready_dt(&led)) {
		printk("led0 not ready\n");
		return 0;
	}
	gpio_pin_configure_dt(&led, GPIO_OUTPUT_ACTIVE);

	while (1) {
		if (wdt_channel >= 0 && atomic_get(&feed_wdt)) {
			task_wdt_feed(wdt_channel);
		}
		gpio_pin_toggle_dt(&led);
		ticks++;
		k_msleep((int)atomic_get(&blink_ms));
	}
	return 0;
}
