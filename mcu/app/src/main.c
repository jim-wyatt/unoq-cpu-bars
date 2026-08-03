/*
 * MCU side of the UNO Q hybrid link.
 *
 * Console + interactive shell + SMP/MCUmgr all share lpuart1, the UART wired
 * to the Linux MPU (/dev/ttyHS1). See boards/arduino_uno_q.overlay.
 *
 * The main loop deliberately does NOT print on a timer - that would fight the
 * shell prompt. It blinks led0 as a liveness indicator and exposes an "app"
 * command group so the MPU can query state on demand.
 */
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/shell/shell.h>
#include <stdlib.h>

static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

static atomic_t blink_ms = ATOMIC_INIT(500);
static uint32_t ticks;

/* --- shell commands: the MPU drives these over the serial link ----------- */

static int cmd_app_status(const struct shell *sh, size_t argc, char **argv)
{
	ARG_UNUSED(argc);
	ARG_UNUSED(argv);
	shell_print(sh, "uptime_ms=%lld ticks=%u blink_ms=%d",
		    k_uptime_get(), ticks, (int)atomic_get(&blink_ms));
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

SHELL_STATIC_SUBCMD_SET_CREATE(app_cmds,
	SHELL_CMD(status, NULL, "Report uptime, tick count and blink period", cmd_app_status),
	SHELL_CMD_ARG(blink, NULL, "Set blink period: app blink <ms>", cmd_app_blink, 2, 0),
	SHELL_SUBCMD_SET_END
);
SHELL_CMD_REGISTER(app, &app_cmds, "UNO Q application commands", NULL);

/* --- main ---------------------------------------------------------------- */

int main(void)
{
	printk("\n=== UNO Q MCU up: %s ===\n", CONFIG_BOARD_TARGET);

	if (!gpio_is_ready_dt(&led)) {
		printk("led0 not ready\n");
		return 0;
	}
	gpio_pin_configure_dt(&led, GPIO_OUTPUT_ACTIVE);

	while (1) {
		gpio_pin_toggle_dt(&led);
		ticks++;
		k_msleep((int)atomic_get(&blink_ms));
	}
	return 0;
}
