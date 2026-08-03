/*
 * Copyright (c) 2026 Jim Wyatt
 * SPDX-License-Identifier: MIT
 *
 * The MPU <-> MCU contract, in one place.
 *
 * Everything here is consumed by three parties that must agree:
 *
 *   - mcu/app/src/main.c        produces the status line, validates bars
 *   - mcu/tests/link_protocol/  tests these definitions directly
 *   - python/unoq/mcu.py        parses the status line, calls `app bars`
 *
 * The definitions used to be duplicated: main.c had the range check and the
 * format string, and the test had its own copy of both. A copy cannot fail
 * when the original changes, so the test proved nothing about the firmware.
 * Include this from both instead.
 *
 * A change here is a protocol change - update unoq/mcu.py and its tests too.
 */
#ifndef APP_PROTO_H
#define APP_PROTO_H

#include <stdbool.h>

/* The `app status` line, parsed by unoq.MCU.status() into a dict.
 *
 * Format is "key=value" pairs separated by single spaces. The parser splits on
 * whitespace and then on the first '=', so a value must never contain either.
 */
#define APP_STATUS_FMT    "uptime_ms=%lld flip=%d sweeps=%u"
#define APP_STATUS_FIELDS 3

/* --- LED matrix ----------------------------------------------------------
 *
 * 104 blue LEDs, charlieplexed on PF0..PF10 and refreshed by a timer ISR - see
 * mcu/app/src/matrix.c. Geometry is fixed by the panel, so it lives here where
 * both sides and the tests can see it.
 *
 * LED index i is row-major: row = i / APP_MATRIX_COLS, col = i % APP_MATRIX_COLS.
 * Row 0 / column 0 is the corner nearest the USB-C connectors; `app matrix px`
 * exists to confirm that on a board rather than trusting this comment.
 */
#define APP_MATRIX_ROWS 8
#define APP_MATRIX_COLS 13
#define APP_MATRIX_LEDS (APP_MATRIX_ROWS * APP_MATRIX_COLS)

/* 3-bit grayscale: 0 is off, APP_MATRIX_MAX_LEVEL is fully on. */
#define APP_MATRIX_MAX_LEVEL 7

/* Refresh sweeps per second while the panel is on - one sweep per pass over
 * all 104 LEDs, at the 10us slot matrix.c programs. `app status` reports the
 * running count, and this is what to expect it to climb by each second: it is
 * the only evidence from the far end of a serial cable that the panel is
 * really being driven. See matrix.h. */
#define APP_MATRIX_SWEEPS_PER_S 962

static inline bool app_matrix_level_valid(int level)
{
	return level >= 0 && level <= APP_MATRIX_MAX_LEVEL;
}

static inline bool app_matrix_pixel_valid(int row, int col)
{
	return row >= 0 && row < APP_MATRIX_ROWS && col >= 0 && col < APP_MATRIX_COLS;
}

/* --- CPU bars -------------------------------------------------------------
 *
 * `app bars <pct> [pct ...]` draws one vertical bar per value. The MPU sends
 * whole percentages - it owns the measurement (python/unoq/cpu.py), the MCU
 * owns the pixels. Keeping the wire format integer percent means the shell
 * command is still something a human can type by hand while debugging.
 *
 * The cap is the panel's, not the host's. Bars are one column wide at minimum
 * and always separated by one blank column, so n bars need 2n-1 columns: 7 is
 * the most that fit. A host with more cores than that has to aggregate.
 */
#define APP_BARS_MAX     ((APP_MATRIX_COLS + 1) / 2)
#define APP_BARS_PCT_MAX 100

static inline bool app_bars_pct_valid(int pct)
{
	return pct >= 0 && pct <= APP_BARS_PCT_MAX;
}

static inline bool app_bars_count_valid(int n)
{
	return n >= 1 && n <= APP_BARS_MAX;
}

/* Settings key (NVS, storage_partition).
 *
 * The panel's orientation is persisted because it is a property of how the
 * board is mounted, not of the running session: whoever fits the board decides
 * it once with `app matrix flip` and it survives power cycles and updates.
 */
#define APP_SETTINGS_FLIP "app/flip"

#endif /* APP_PROTO_H */
