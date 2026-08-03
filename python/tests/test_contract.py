"""The MPU<->MCU contract, checked against the firmware's own header.

unoq/mcu.py has to know the panel's limits, and there is no way to import a C
macro into Python - so those numbers exist twice. This file is what makes the
duplicate safe: it parses mcu/app/include/app_proto.h and fails if the two
copies disagree. Change the firmware's geometry and this test breaks before the
board does.

The same reasoning is written up in app_proto.h itself, which explains why the
C-side definitions were pulled out of main.c and into a shared header.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from unoq import mcu

HEADER = Path(__file__).resolve().parents[2] / "mcu" / "app" / "include" / "app_proto.h"

# `#define NAME value` - object-like macros only. The function-like ones in the
# header (the app_*_valid inline helpers are C functions, not macros) are not
# constants and have nothing to compare against.
_DEFINE = re.compile(r"^#define\s+(\w+)\s+(.+?)\s*$", re.MULTILINE)
# Guards how much of a #define body we are willing to hand to eval(): integers,
# arithmetic, parentheses and names we have already resolved.
_ARITHMETIC = re.compile(r"^[\w\s()+\-*/]+$")


def macros() -> dict[str, int]:
    """Every integer #define in app_proto.h, with expressions resolved.

    APP_BARS_MAX is defined in terms of APP_MATRIX_COLS, so a plain int() will
    not do; values are substituted and evaluated in definition order.
    """
    if not HEADER.exists():  # pragma: no cover - only if the tree is cut up
        pytest.skip(f"firmware header not found at {HEADER}")

    found: dict[str, int] = {}
    for name, body in _DEFINE.findall(HEADER.read_text()):
        body = body.split("/*")[0].strip()
        if not body or not _ARITHMETIC.match(body):
            continue  # a string, a format specifier, or a multi-line macro
        expanded = re.sub(r"\b[A-Za-z_]\w*\b", lambda m: str(found.get(m.group(), "?")), body)
        try:
            # eval() on a string already screened by _ARITHMETIC: digits,
            # operators and names that resolved to digits, nothing else.
            found[name] = int(eval(expanded))
        except (SyntaxError, NameError, ValueError, ZeroDivisionError):
            continue
    return found


@pytest.fixture(scope="module")
def firmware() -> dict[str, int]:
    values = macros()
    assert values, f"parsed no constants out of {HEADER} - has the format changed?"
    return values


@pytest.mark.parametrize(
    ("python_name", "c_name"),
    [
        ("BARS_MAX", "APP_BARS_MAX"),
        ("BARS_PCT_MAX", "APP_BARS_PCT_MAX"),
        ("MATRIX_ROWS", "APP_MATRIX_ROWS"),
        ("MATRIX_COLS", "APP_MATRIX_COLS"),
        ("MATRIX_MAX_LEVEL", "APP_MATRIX_MAX_LEVEL"),
    ],
)
def test_python_constants_match_the_firmware(
    firmware: dict[str, int], python_name: str, c_name: str
) -> None:
    assert c_name in firmware, f"{c_name} is gone from app_proto.h"
    assert getattr(mcu, python_name) == firmware[c_name], (
        f"unoq.mcu.{python_name} is {getattr(mcu, python_name)} but the firmware "
        f"says {c_name} is {firmware[c_name]} - update python/unoq/mcu.py"
    )


def test_the_parser_resolves_expressions_not_just_literals(firmware: dict[str, int]) -> None:
    """APP_BARS_MAX is `((APP_MATRIX_COLS + 1) / 2)`. If the parser silently
    skipped expressions, the check above would pass by never running."""
    assert firmware["APP_BARS_MAX"] == (firmware["APP_MATRIX_COLS"] + 1) // 2


def test_led_count_is_the_grid(firmware: dict[str, int]) -> None:
    assert firmware["APP_MATRIX_LEDS"] == firmware["APP_MATRIX_ROWS"] * firmware["APP_MATRIX_COLS"]
