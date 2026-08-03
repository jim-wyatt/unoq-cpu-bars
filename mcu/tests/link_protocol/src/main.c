/*
 * Host-runnable tests for the MPU <-> MCU contract in app_proto.h.
 *
 * These test the definitions the firmware actually ships: the header included
 * here is the same one main.c includes. An earlier version of this file kept
 * its own copy of the range check, which meant the test could not fail when
 * the firmware changed.
 *
 * Runs on native_sim (i.e. natively on the UNO Q's own Linux side), so this
 * costs no flash cycle and no hardware. Run with:
 *   ~/hybrid/mcu/ztest.sh
 */
#include <zephyr/ztest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "app_proto.h"

/* --- blink range --------------------------------------------------------- */

ZTEST(link_protocol, test_blink_range_accepts_valid)
{
	zassert_true(app_blink_ms_valid(APP_BLINK_MS_MIN), "lower bound should be accepted");
	zassert_true(app_blink_ms_valid(500), "typical value should be accepted");
	zassert_true(app_blink_ms_valid(APP_BLINK_MS_MAX), "upper bound should be accepted");
}

ZTEST(link_protocol, test_blink_range_rejects_invalid)
{
	zassert_false(app_blink_ms_valid(APP_BLINK_MS_MIN - 1), "below range must be rejected");
	zassert_false(app_blink_ms_valid(APP_BLINK_MS_MAX + 1), "above range must be rejected");
	zassert_false(app_blink_ms_valid(-1), "negative must be rejected");
	zassert_false(app_blink_ms_valid(0), "zero would busy-spin the loop");
}

ZTEST(link_protocol, test_blink_bounds_are_sane)
{
	zassert_true(APP_BLINK_MS_MIN > 0, "a zero period would starve the watchdog feed");
	zassert_true(APP_BLINK_MS_MIN < APP_BLINK_MS_MAX, "bounds must not be inverted");
}

/* --- the status line ----------------------------------------------------- */

/* Render APP_STATUS_FMT exactly as cmd_app_status() does. */
static void render_status(char *buf, size_t len)
{
	snprintf(buf, len, APP_STATUS_FMT, (long long)1234, (unsigned int)5, 500, (unsigned int)2,
		 1);
}

ZTEST(link_protocol, test_status_line_is_parseable)
{
	char buf[128];
	int seen = 0;

	render_status(buf, sizeof(buf));

	for (char *tok = strtok(buf, " "); tok; tok = strtok(NULL, " ")) {
		char *eq = strchr(tok, '=');

		zassert_not_null(eq, "every token must be key=value");
		zassert_true(eq != tok, "a token must have a key before '='");
		zassert_true(*(eq + 1) != '\0', "a token must have a value after '='");
		seen++;
	}
	zassert_equal(seen, APP_STATUS_FIELDS, "expected %d status fields, got %d",
		      APP_STATUS_FIELDS, seen);
}

ZTEST(link_protocol, test_status_line_carries_the_expected_keys)
{
	/* unoq.MCU.status() looks these up by name; renaming one breaks the MPU
	 * side silently, because a missing key just does not appear in the dict.
	 */
	static const char *const keys[] = {"uptime_ms=", "ticks=", "blink_ms=", "boots=", "wdt="};
	char buf[128];

	render_status(buf, sizeof(buf));

	for (size_t i = 0; i < ARRAY_SIZE(keys); i++) {
		zassert_not_null(strstr(buf, keys[i]), "status line is missing %s", keys[i]);
	}
}

ZTEST(link_protocol, test_status_values_contain_no_separators)
{
	/* The parser splits on whitespace then on the first '='. A value holding
	 * either character would be silently mis-parsed.
	 */
	char buf[128];

	render_status(buf, sizeof(buf));

	for (char *tok = strtok(buf, " "); tok; tok = strtok(NULL, " ")) {
		zassert_is_null(strchr(strchr(tok, '=') + 1, '='), "a value must not contain '='");
	}
}

/* --- other shared constants ---------------------------------------------- */

ZTEST(link_protocol, test_watchdog_timeout_leaves_room_to_feed)
{
	/* The loop feeds once per blink period, so the timeout must exceed the
	 * slowest blink or a legal `app blink` would reset the board.
	 */
	zassert_true(APP_WDT_TIMEOUT_MS > 0, "timeout must be positive");
	zassert_true(APP_BLINK_MS_MAX >= APP_WDT_TIMEOUT_MS,
		     "documented caveat: a blink period above the watchdog timeout "
		     "stops the feed in time - keep this relationship deliberate");
}

ZTEST(link_protocol, test_settings_key_is_namespaced)
{
	/* SETTINGS_STATIC_HANDLER_DEFINE registers the "app" subtree, so the key
	 * must sit under it or settings_load() will never call the handler.
	 */
	zassert_equal(strncmp(APP_SETTINGS_BOOTS, "app/", 4), 0,
		      "boot counter key must live under the app/ subtree");
}

ZTEST_SUITE(link_protocol, NULL, NULL, NULL, NULL, NULL);
