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

static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

static atomic_t blink_ms = ATOMIC_INIT(250);  /* v2 marker for FOTA test */
static uint32_t ticks;
static uint32_t boot_count;   /* persisted in NVS across power cycles */
static atomic_t feed_wdt = ATOMIC_INIT(1);
static int wdt_channel = -1;

/* --- persistent settings ------------------------------------------------- */

static int app_settings_set(const char *name, size_t len,
			    settings_read_cb read_cb, void *cb_arg)
{
	if (settings_name_steq(name, "boots", NULL) && len == sizeof(boot_count)) {
		return read_cb(cb_arg, &boot_count, sizeof(boot_count)) > 0 ? 0 : -EINVAL;
	}
	return -ENOENT;
}

SETTINGS_STATIC_HANDLER_DEFINE(app, "app", NULL, app_settings_set, NULL, NULL);

/* --- shell commands: the MPU drives these over the serial link ----------- */

static int cmd_app_status(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	shell_print(sh, "uptime_ms=%lld ticks=%u blink_ms=%d boots=%u wdt=%d",
		    k_uptime_get(), ticks, (int)atomic_get(&blink_ms),
		    boot_count, wdt_channel >= 0);
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
	if (ms < 10 || ms > 10000) {
		shell_error(sh, "range 10..10000");
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

SHELL_STATIC_SUBCMD_SET_CREATE(app_cmds,
	SHELL_CMD(status, NULL, "uptime, ticks, blink period, boot count", cmd_app_status),
	SHELL_CMD_ARG(blink, NULL, "Set blink period: app blink <ms>", cmd_app_blink, 2, 0),
	SHELL_CMD(hang, NULL, "Stop feeding the watchdog (forces a reset)", cmd_app_hang),
	SHELL_SUBCMD_SET_END
);
SHELL_CMD_REGISTER(app, &app_cmds, "UNO Q application commands", NULL);

/* --- main ---------------------------------------------------------------- */

int main(void)
{
	const struct device *wdt = DEVICE_DT_GET_OR_NULL(DT_ALIAS(watchdog0));

	printk("\n=== UNO Q MCU up: %s ===\n", CONFIG_BOARD_TARGET);

	/* Persistent boot counter. */
	if (settings_subsys_init() == 0 && settings_load() == 0) {
		boot_count++;
		settings_save_one("app/boots", &boot_count, sizeof(boot_count));
		printk("boot count: %u\n", boot_count);
	} else {
		printk("settings unavailable - boot count not persisted\n");
	}

	/* Task watchdog. Falls back to a pure software timer if the SoC
	 * watchdog is not exposed in the devicetree. */
	if (task_wdt_init(wdt) == 0) {
		wdt_channel = task_wdt_add(4000, NULL, NULL);
		printk("watchdog armed (4s), channel %d\n", wdt_channel);
	} else {
		printk("watchdog unavailable\n");
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
