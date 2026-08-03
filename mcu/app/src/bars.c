/*
 * Percentages -> grayscale pixels. See include/bars.h for the contract.
 *
 * No Zephyr headers on purpose: mcu/tests/bars/ compiles this file directly
 * and runs it on the host.
 */
#include <string.h>

#include "bars.h"

bool app_bars_layout(int n, struct app_bars_layout *out)
{
	int width, used;

	if (!app_bars_count_valid(n)) {
		return false;
	}

	/* n bars plus n-1 single-column gaps have to fit in the panel. The
	 * APP_BARS_MAX cap guarantees this leaves at least one column per bar.
	 */
	width = (APP_MATRIX_COLS - (n - 1)) / n;
	used = n * width + (n - 1);

	out->width = width;
	out->left = (APP_MATRIX_COLS - used) / 2;
	return true;
}

/* Fill one bar's columns, bottom-up, in unrotated coordinates. */
static void draw_bar(uint8_t *frame, int col, int width, int pct)
{
	int units, full, part, row, c;

	if (pct < 0) {
		pct = 0;
	} else if (pct > APP_BARS_PCT_MAX) {
		pct = APP_BARS_PCT_MAX;
	}

	/* Height in units of one brightness step, so the division that loses
	 * precision happens once, here, rather than per row. */
	units = pct * APP_MATRIX_ROWS * APP_MATRIX_MAX_LEVEL / APP_BARS_PCT_MAX;
	full = units / APP_MATRIX_MAX_LEVEL;
	part = units % APP_MATRIX_MAX_LEVEL;

	for (row = 0; row < full; row++) {
		for (c = col; c < col + width; c++) {
			frame[(APP_MATRIX_ROWS - 1 - row) * APP_MATRIX_COLS + c] =
				APP_MATRIX_MAX_LEVEL;
		}
	}

	/* The partial row only exists below the top of the panel; at 100% the
	 * remainder is zero anyway, so this never clips a full bar. */
	if (part > 0 && full < APP_MATRIX_ROWS) {
		for (c = col; c < col + width; c++) {
			frame[(APP_MATRIX_ROWS - 1 - full) * APP_MATRIX_COLS + c] = (uint8_t)part;
		}
	}
}

void app_bars_render(const uint8_t *pct, int n, bool rotate180, uint8_t *frame)
{
	struct app_bars_layout layout;
	int i;

	memset(frame, 0, APP_MATRIX_LEDS);

	if (!app_bars_layout(n, &layout)) {
		return;
	}

	for (i = 0; i < n; i++) {
		draw_bar(frame, app_bars_column(&layout, i), layout.width, pct[i]);
	}

	/* Row-major indexing makes a 180-degree rotation a plain reversal. */
	if (rotate180) {
		for (i = 0; i < APP_MATRIX_LEDS / 2; i++) {
			uint8_t tmp = frame[i];

			frame[i] = frame[APP_MATRIX_LEDS - 1 - i];
			frame[APP_MATRIX_LEDS - 1 - i] = tmp;
		}
	}
}
