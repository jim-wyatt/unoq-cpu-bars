/* MCU side of the hybrid link: prints over the UART wired to the Linux MPU. */
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>

static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

int main(void)
{
	printk("\n=== UNO Q MCU alive: %s ===\n", CONFIG_BOARD_TARGET);

	if (gpio_is_ready_dt(&led)) {
		gpio_pin_configure_dt(&led, GPIO_OUTPUT_ACTIVE);
	}

	for (uint32_t i = 0;; i++) {
		printk("mcu tick %u  uptime=%lldms\n", i, k_uptime_get());
		if (gpio_is_ready_dt(&led)) {
			gpio_pin_toggle_dt(&led);
		}
		k_msleep(1000);
	}
	return 0;
}
