/*
 * Host-runnable tests for logic shared with the MCU app.
 *
 * Runs on native_sim (i.e. natively on the UNO Q's own Linux side), so this
 * costs no flash cycle and no hardware. Run with:
 *   ~/hybrid/mcu/ztest.sh
 */
#include <zephyr/ztest.h>
#include <stdlib.h>

/* Mirror of the range check in the app's `app blink` shell command. */
static bool blink_ms_valid(int ms)
{
	return ms >= 10 && ms <= 10000;
}

ZTEST(link_protocol, test_blink_range_accepts_valid)
{
	zassert_true(blink_ms_valid(10), "lower bound should be accepted");
	zassert_true(blink_ms_valid(500), "typical value should be accepted");
	zassert_true(blink_ms_valid(10000), "upper bound should be accepted");
}

ZTEST(link_protocol, test_blink_range_rejects_invalid)
{
	zassert_false(blink_ms_valid(9), "below range must be rejected");
	zassert_false(blink_ms_valid(10001), "above range must be rejected");
	zassert_false(blink_ms_valid(-1), "negative must be rejected");
	zassert_false(blink_ms_valid(0), "zero would busy-spin the loop");
}

/* The status line the MPU parses: "key=value key=value ...". If this format
 * changes, unoq.MCU.status() breaks - so pin it here. */
ZTEST(link_protocol, test_status_line_is_parseable)
{
	const char *line = "uptime_ms=1234 ticks=5 blink_ms=500 boots=2 wdt=1";
	int seen = 0;
	char buf[128];
	strncpy(buf, line, sizeof(buf) - 1);
	buf[sizeof(buf) - 1] = '\0';

	for (char *tok = strtok(buf, " "); tok; tok = strtok(NULL, " ")) {
		char *eq = strchr(tok, '=');
		zassert_not_null(eq, "every token must be key=value");
		seen++;
	}
	zassert_equal(seen, 5, "expected 5 status fields, got %d", seen);
}

ZTEST_SUITE(link_protocol, NULL, NULL, NULL, NULL, NULL);
