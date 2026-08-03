/*
 * The MPU <-> MCU contract, in one place.
 *
 * Everything here is consumed by three parties that must agree:
 *
 *   - mcu/app/src/main.c        produces the status line, validates blink
 *   - mcu/tests/link_protocol/  tests these definitions directly
 *   - python/unoq/mcu.py        parses the status line, calls `app blink`
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

/* Blink period accepted by `app blink <ms>`.
 *
 * The lower bound is not cosmetic: the main loop sleeps for this value, so 0
 * would busy-spin the CPU and starve the watchdog feed.
 */
#define APP_BLINK_MS_MIN 10
#define APP_BLINK_MS_MAX 10000

static inline bool app_blink_ms_valid(int ms)
{
	return ms >= APP_BLINK_MS_MIN && ms <= APP_BLINK_MS_MAX;
}

/* The `app status` line, parsed by unoq.MCU.status() into a dict.
 *
 * Format is "key=value" pairs separated by single spaces. The parser splits on
 * whitespace and then on the first '=', so a value must never contain either.
 */
#define APP_STATUS_FMT    "uptime_ms=%lld ticks=%u blink_ms=%d boots=%u wdt=%d"
#define APP_STATUS_FIELDS 5

/* Settings key holding the persistent boot counter (NVS, storage_partition). */
#define APP_SETTINGS_BOOTS "app/boots"

/* Task watchdog timeout. `app hang` stops the feed to prove it bites. */
#define APP_WDT_TIMEOUT_MS 4000

#endif /* APP_PROTO_H */
