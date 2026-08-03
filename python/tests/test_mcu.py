# Copyright (c) 2026 Jim Wyatt
# SPDX-License-Identifier: MIT
"""Tests for the Zephyr shell protocol and the parsing built on top of it.

The parsing is the fragile part of this package: it consumes text produced by
firmware that can change, over a UART that injects echo, ANSI colour and a
prompt. Each test below pins one of those behaviours.
"""

from __future__ import annotations

from typing import Any

import pytest

from unoq.mcu import MCU, MCUError, ShellTimeout, _clean

# -- _clean -----------------------------------------------------------------


def test_clean_strips_ansi_prompt_and_blanks() -> None:
    raw = "\x1b[1;32muno_q:~$ \x1b[0m\r\nhello\r\n\r\n  spaced  \r\nuno_q:~$ "
    assert _clean(raw) == ["hello", "spaced"]


def test_clean_treats_cr_as_a_line_break() -> None:
    # The shell terminates lines with \r\n; a lone \r must not glue lines.
    assert _clean("one\rtwo\r\nthree") == ["one", "two", "three"]


def test_clean_returns_nothing_for_prompt_only_output() -> None:
    assert _clean("uno_q:~$ ") == []


# -- cmd --------------------------------------------------------------------


def test_cmd_sends_crlf_and_strips_the_echo(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["uptime_ms=1 flip=0"]})
    assert mcu.cmd("app status") == ["uptime_ms=1 flip=0"]
    # The command itself is echoed by the shell and must not be returned.
    assert mcu._s.written == ["app status"]


def test_cmd_survives_ansi_colouring(mcu_factory: Any) -> None:
    mcu = mcu_factory({"device list": ["- gpio@1 (READY)"]}, ansi=True)
    assert mcu.cmd("device list") == ["- gpio@1 (READY)"]


def test_cmd_resets_the_input_buffer_before_writing(mcu_factory: Any) -> None:
    # Stale bytes from a previous command would otherwise be parsed as output.
    mcu = mcu_factory({"x": ["ok"]})
    before = mcu._s.reset_count
    mcu.cmd("x")
    assert mcu._s.reset_count > before


def test_cmd_raises_shell_timeout_when_no_prompt_comes_back(mcu_factory: Any) -> None:
    mcu = mcu_factory(silent=True)
    with pytest.raises(ShellTimeout, match="no prompt"):
        mcu.cmd("app status", timeout=0.05)


def test_cmd_raises_on_unknown_command(mcu_factory: Any) -> None:
    mcu = mcu_factory({"nope": ["nope: command not found"]})
    with pytest.raises(MCUError, match="command not found"):
        mcu.cmd("nope")


def test_cmd_raises_on_error_lines(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app bars 200": ["Error: bar 0: 200 outside 0..100"]})
    with pytest.raises(MCUError, match="outside"):
        mcu.cmd("app bars 200")


# -- status -----------------------------------------------------------------


def test_status_parses_the_firmware_status_line(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["uptime_ms=12216 flip=0 sweeps=1043712"]})
    assert mcu.status() == {"uptime_ms": 12216, "flip": 0, "sweeps": 1043712}


def test_status_keeps_unparseable_values_as_strings(mcu_factory: Any) -> None:
    # A firmware change should surface as an odd value, not a missing key.
    mcu = mcu_factory({"app status": ["uptime_ms=25 mode=fast"]})
    assert mcu.status() == {"uptime_ms": 25, "mode": "fast"}


def test_status_raises_when_the_mcu_says_nothing(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": []})
    with pytest.raises(MCUError, match="returned nothing"):
        mcu.status()


def test_status_raises_when_no_key_value_pairs_are_present(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["garbage output"]})
    with pytest.raises(MCUError, match="could not parse"):
        mcu.status()


# -- LED matrix -------------------------------------------------------------


def test_bars_sends_one_value_per_bar(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app bars 10 20 30 40": ["ok bars=4"]})
    mcu.bars([10, 20, 30, 40])
    assert mcu._s.written == ["app bars 10 20 30 40"]


def test_bars_rounds_floats(mcu_factory: Any) -> None:
    # The sampler produces percentages, and `app bars` takes integers.
    mcu = mcu_factory({"app bars 33 67": ["ok bars=2"]})
    mcu.bars([33.4, 66.6])
    assert mcu._s.written == ["app bars 33 67"]


def test_bars_clamps_rather_than_raising(mcu_factory: Any) -> None:
    # A live measurement that arrives as 100.4 should light a full bar. The
    # firmware rejects out-of-range values, so clamping has to happen here.
    mcu = mcu_factory({"app bars 0 100": ["ok bars=2"]})
    mcu.bars([-3, 104])
    assert mcu._s.written == ["app bars 0 100"]


def test_bars_rejects_a_count_the_panel_cannot_show(mcu_factory: Any) -> None:
    # Unlike a stray percentage, this is a programming error: it cannot come
    # from a noisy reading, only from asking for the wrong thing.
    mcu = mcu_factory({})
    with pytest.raises(ValueError, match=r"need 1\.\.7 values"):
        mcu.bars([50] * 8)


def test_bars_rejects_an_empty_reading(mcu_factory: Any) -> None:
    mcu = mcu_factory({})
    with pytest.raises(ValueError, match=r"need 1\.\.7 values"):
        mcu.bars([])


def test_matrix_px_coerces_its_coordinates(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix px 7 0 7": ["ok px row=7 col=0 level=7"]})
    mcu.matrix_px(7.0, 0.0)
    assert mcu._s.written == ["app matrix px 7 0 7"]


def test_matrix_flip_reports_the_new_state(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix flip": ["ok flip=1"]})
    assert mcu.matrix_flip() is True


def test_matrix_flip_reports_being_flipped_back(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix flip": ["ok flip=0"]})
    assert mcu.matrix_flip() is False


def test_matrix_flip_raises_on_an_unparseable_reply(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix flip": ["what"]})
    with pytest.raises(MCUError, match="could not parse matrix flip"):
        mcu.matrix_flip()


def test_matrix_flip_raises_on_no_reply(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix flip": []})
    with pytest.raises(MCUError, match="could not parse matrix flip"):
        mcu.matrix_flip()


def test_matrix_off_blanks_the_panel(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app matrix off": ["ok matrix off"]})
    mcu.matrix_off()
    assert mcu._s.written == ["app matrix off"]


# -- lifecycle --------------------------------------------------------------


def test_context_manager_closes_the_port(mcu_factory: Any) -> None:
    mcu = mcu_factory({})
    with mcu as handle:
        assert handle is mcu
        assert mcu._s.is_open
    assert not mcu._s.is_open


def test_close_is_idempotent(mcu_factory: Any) -> None:
    mcu = mcu_factory({})
    mcu.close()
    mcu.close()
    assert not mcu._s.is_open


def test_ensure_link_brings_the_link_up(
    monkeypatch: pytest.MonkeyPatch, serial_factory: Any
) -> None:
    import unoq.mcu

    called: list[bool] = []
    monkeypatch.setattr(unoq.mcu, "link_up", lambda: called.append(True))
    serial_factory(replies={})
    MCU(port="/dev/fake", ensure_link=True)
    assert called == [True]


def test_ensure_link_failure_is_not_fatal(
    monkeypatch: pytest.MonkeyPatch, serial_factory: Any
) -> None:
    # A board whose link is already up, or a user without gpiod rights, must
    # still get a usable MCU handle.
    import unoq.mcu

    def boom() -> None:
        raise PermissionError("no gpiod for you")

    monkeypatch.setattr(unoq.mcu, "link_up", boom)
    serial_factory(replies={})
    assert MCU(port="/dev/fake", ensure_link=True) is not None


# -- chunked / non-echoing shells -------------------------------------------


def test_cmd_reassembles_a_reply_that_arrives_in_pieces(mcu_factory: Any) -> None:
    # A real UART delivers a few bytes per read, so the prompt is usually not
    # in the first chunk. cmd() must keep reading until it sees one.
    mcu = mcu_factory({"app status": ["uptime_ms=7"]}, chunk_size=3)
    assert mcu.cmd("app status") == ["uptime_ms=7"]


def test_cmd_handles_a_shell_that_does_not_echo(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["uptime_ms=7"]}, echo=False)
    assert mcu.cmd("app status") == ["uptime_ms=7"]
