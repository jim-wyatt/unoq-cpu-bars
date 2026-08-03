"""Tests for the two MPU GPIO lines the MCU depends on.

These are the highest-consequence constants in the project: with either line
wrong, a board with perfect firmware looks dead. The tests below pin both the
numbers and the request shape.
"""

from __future__ import annotations

from typing import Any

import pytest
from gpiod.line import Direction, Value

from unoq.link import (
    BOOT0_LINE,
    GPIOCHIP,
    LINK_ENABLE_LINE,
    SWD_LINES,
    link_state,
    link_up,
)

# -- the constants themselves ------------------------------------------------


def test_line_numbers_are_the_documented_ones() -> None:
    """Guard the magic numbers.

    Nothing in the Zephyr board definition or Arduino's docs records these.
    They were recovered by tracing arduino-router, so a well-meaning "tidy up"
    has no source of truth to check against except this test.
    """
    assert BOOT0_LINE == 37
    assert LINK_ENABLE_LINE == 70
    assert GPIOCHIP == "/dev/gpiochip1"
    assert SWD_LINES == {"swdio": 25, "swclk": 26, "srst": 38}


def test_link_lines_do_not_collide_with_swd() -> None:
    assert BOOT0_LINE not in SWD_LINES.values()
    assert LINK_ENABLE_LINE not in SWD_LINES.values()


# -- link_up -----------------------------------------------------------------


def test_link_up_drives_boot0_low_and_link_enable_high(fake_gpiod: dict[str, Any]) -> None:
    link_up()

    (call,) = fake_gpiod["calls"]
    assert call["chip"] == GPIOCHIP
    assert call["consumer"] == "unoq-link"

    boot0 = call["config"][BOOT0_LINE]
    link_en = call["config"][LINK_ENABLE_LINE]
    # BOOT0 high at reset boots the STM32 ROM bootloader instead of our image.
    assert boot0.direction is Direction.OUTPUT
    assert boot0.output_value is Value.INACTIVE
    # Link-enable low means the MCU transmits into a disconnected path.
    assert link_en.direction is Direction.OUTPUT
    assert link_en.output_value is Value.ACTIVE


def test_link_up_releases_the_request(fake_gpiod: dict[str, Any]) -> None:
    """The one-shot only works because the pin keeps its value after release.

    If this ever stopped releasing, the lines would stay held by a dead process
    and every later consumer would get EBUSY.
    """
    link_up()
    assert fake_gpiod["request"].released is True


def test_link_up_accepts_a_different_chip(fake_gpiod: dict[str, Any]) -> None:
    link_up("/dev/gpiochip9")
    assert fake_gpiod["calls"][0]["chip"] == "/dev/gpiochip9"


def test_link_up_is_idempotent(fake_gpiod: dict[str, Any]) -> None:
    link_up()
    link_up()
    assert len(fake_gpiod["calls"]) == 2  # no state kept between calls


# -- link_state --------------------------------------------------------------


def test_link_state_reports_output_when_the_link_is_up(fake_gpiod: dict[str, Any]) -> None:
    fake_gpiod["directions"] = {BOOT0_LINE: "OUTPUT", LINK_ENABLE_LINE: "OUTPUT"}
    assert link_state() == {"boot0": "OUTPUT", "link_enable": "OUTPUT"}


def test_link_state_reports_input_when_a_line_is_floating(fake_gpiod: dict[str, Any]) -> None:
    # INPUT is the broken state: reading the value with gpioget causes exactly
    # this, which is why link_state inspects direction instead.
    fake_gpiod["directions"] = {BOOT0_LINE: "OUTPUT"}
    assert link_state() == {"boot0": "OUTPUT", "link_enable": "INPUT"}


def test_link_state_closes_the_chip(fake_gpiod: dict[str, Any]) -> None:
    link_state()
    assert fake_gpiod["chip"].closed is True


def test_link_state_closes_the_chip_even_when_reading_fails(
    fake_gpiod: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    chips: list[Any] = []

    class ExplodingChip:
        def __init__(self, path: str) -> None:
            self.closed = False
            chips.append(self)

        def get_line_info(self, offset: int) -> None:
            raise OSError("chip went away")

        def close(self) -> None:
            self.closed = True

    monkeypatch.setattr("unoq.link.gpiod.Chip", ExplodingChip)
    with pytest.raises(OSError, match="chip went away"):
        link_state()
    assert chips[0].closed is True
