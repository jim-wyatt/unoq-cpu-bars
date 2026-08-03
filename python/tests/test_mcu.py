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
    mcu = mcu_factory({"app status": ["uptime_ms=1 ticks=2"]})
    assert mcu.cmd("app status") == ["uptime_ms=1 ticks=2"]
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
    mcu = mcu_factory({"app blink 5": ["Error: range 10..10000"]})
    with pytest.raises(MCUError, match="range"):
        mcu.cmd("app blink 5")


# -- status -----------------------------------------------------------------


def test_status_parses_the_firmware_status_line(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["uptime_ms=12216 ticks=25 blink_ms=250 boots=7 wdt=1"]})
    assert mcu.status() == {
        "uptime_ms": 12216,
        "ticks": 25,
        "blink_ms": 250,
        "boots": 7,
        "wdt": 1,
    }


def test_status_keeps_unparseable_values_as_strings(mcu_factory: Any) -> None:
    # A firmware change should surface as an odd value, not a missing key.
    mcu = mcu_factory({"app status": ["ticks=25 mode=fast"]})
    assert mcu.status() == {"ticks": 25, "mode": "fast"}


def test_status_raises_when_the_mcu_says_nothing(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": []})
    with pytest.raises(MCUError, match="returned nothing"):
        mcu.status()


def test_status_raises_when_no_key_value_pairs_are_present(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["garbage output"]})
    with pytest.raises(MCUError, match="could not parse"):
        mcu.status()


# -- other application commands ---------------------------------------------


def test_blink_coerces_to_int_before_sending(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app blink 250": ["ok blink_ms=250"]})
    mcu.blink(250.9)  # a float must be coerced, not passed through
    assert mcu._s.written == ["app blink 250"]


def test_uptime_ms_extracts_the_first_number(mcu_factory: Any) -> None:
    mcu = mcu_factory({"kernel uptime": ["Uptime: 123456 ms"]})
    assert mcu.uptime_ms() == 123456


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


def test_uptime_ms_raises_when_there_is_no_number(mcu_factory: Any) -> None:
    mcu = mcu_factory({"kernel uptime": ["no idea"]})
    with pytest.raises(MCUError, match="could not parse kernel uptime"):
        mcu.uptime_ms()


def test_devices_parses_name_and_state(mcu_factory: Any) -> None:
    mcu = mcu_factory(
        {"device list": ["devices:", "- gpio@42000000 (READY)", "- lpuart1 (READY)", "noise"]}
    )
    assert mcu.devices() == [("gpio@42000000", "READY"), ("lpuart1", "READY")]


def test_devices_is_empty_when_nothing_matches(mcu_factory: Any) -> None:
    mcu = mcu_factory({"device list": ["devices:"]})
    assert mcu.devices() == []


# -- GPIO / I2C -------------------------------------------------------------


def test_gpio_conf_and_set_build_the_right_commands(mcu_factory: Any) -> None:
    mcu = mcu_factory({"gpio conf gpioh 11 o": [], "gpio set gpioh 11 1": []})
    mcu.gpio_conf("gpioh", 11)
    mcu.gpio_set("gpioh", 11, 5)  # any truthy value becomes 1
    assert mcu._s.written == ["gpio conf gpioh 11 o", "gpio set gpioh 11 1"]


def test_gpio_set_writes_zero_for_falsey_values(mcu_factory: Any) -> None:
    mcu = mcu_factory({"gpio set gpioh 11 0": []})
    mcu.gpio_set("gpioh", 11, 0)
    assert mcu._s.written == ["gpio set gpioh 11 0"]


def test_gpio_get_parses_the_trailing_value(mcu_factory: Any) -> None:
    mcu = mcu_factory({"gpio get gpioh 11": ["Value: 1"]})
    assert mcu.gpio_get("gpioh", 11) == 1


def test_gpio_get_raises_on_unparseable_output(mcu_factory: Any) -> None:
    mcu = mcu_factory({"gpio get gpioh 11": ["huh"]})
    with pytest.raises(MCUError, match="could not parse gpio get"):
        mcu.gpio_get("gpioh", 11)


def test_i2c_scan_collects_two_digit_hex_addresses(mcu_factory: Any) -> None:
    mcu = mcu_factory({"i2c scan i2c1": ["0 1 2 3", "00: -- -- 3c 4e", "2 devices found"]})
    # Only bare two-hex-digit tokens count: "3c" and "4e", not "0"/"1" or "00:".
    assert mcu.i2c_scan("i2c1") == [0x3C, 0x4E]


def test_i2c_scan_is_empty_when_no_devices_answer(mcu_factory: Any) -> None:
    mcu = mcu_factory({"i2c scan i2c1": ["0 devices found"]})
    assert mcu.i2c_scan("i2c1") == []


# -- lifecycle --------------------------------------------------------------


def test_reboot_swallows_the_expected_timeout(mcu_factory: Any) -> None:
    # The MCU resets instead of printing a prompt, so a timeout is success.
    mcu = mcu_factory(silent=True)
    mcu.reboot()


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
    mcu = mcu_factory({"app status": ["ticks=7"]}, chunk_size=3)
    assert mcu.cmd("app status") == ["ticks=7"]


def test_cmd_handles_a_shell_that_does_not_echo(mcu_factory: Any) -> None:
    mcu = mcu_factory({"app status": ["ticks=7"]}, echo=False)
    assert mcu.cmd("app status") == ["ticks=7"]


# -- echo() over SMP ---------------------------------------------------------


class _FakeSMPTransport:
    def __init__(self, baudrate: int = 0) -> None:
        self.disconnected = False

    async def disconnect(self) -> None:
        self.disconnected = True


class _FakeSMPClient:
    """Replies to EchoWrite, optionally failing the first N attempts."""

    fail_times = 0
    attempts = 0

    def __init__(self, transport: Any, port: str, timeout_s: float = 0) -> None:
        self.transport = transport
        self.port = port

    async def connect(self, connect_timeout_s: float = 0) -> None:
        return None

    async def request(self, req: Any, timeout_s: float = 0) -> Any:
        type(self).attempts += 1
        if type(self).attempts <= type(self).fail_times:
            raise TimeoutError("frame lost")
        return type("Reply", (), {"r": req.d})()


@pytest.fixture
def fake_smp(monkeypatch: pytest.MonkeyPatch) -> Any:
    """Patch the smpclient symbols echo() imports at call time."""
    import smpclient
    import smpclient.requests.os_management as os_mgmt
    import smpclient.transport.serial as smp_serial

    _FakeSMPClient.fail_times = 0
    _FakeSMPClient.attempts = 0
    monkeypatch.setattr(smpclient, "SMPClient", _FakeSMPClient)
    monkeypatch.setattr(smp_serial, "SMPSerialTransport", _FakeSMPTransport)
    monkeypatch.setattr(os_mgmt, "EchoWrite", lambda d: type("Echo", (), {"d": d})())
    return _FakeSMPClient


def test_echo_round_trips_through_smp(mcu_factory: Any, fake_smp: Any) -> None:
    mcu = mcu_factory({})
    assert mcu.echo("ping") == "ping"


def test_echo_reopens_the_shell_port_afterwards(mcu_factory: Any, fake_smp: Any) -> None:
    # The UART is one shared resource: echo() closes the shell handle, and the
    # caller must get a working handle back.
    mcu = mcu_factory({})
    mcu.echo("ping")
    assert mcu._s.is_open


def test_echo_retries_once_before_giving_up(mcu_factory: Any, fake_smp: Any) -> None:
    fake_smp.fail_times = 1
    mcu = mcu_factory({})
    assert mcu.echo("ping") == "ping"
    assert fake_smp.attempts == 2


def test_echo_raises_mcu_error_when_both_attempts_fail(mcu_factory: Any, fake_smp: Any) -> None:
    fake_smp.fail_times = 99
    mcu = mcu_factory({})
    with pytest.raises(MCUError, match="SMP echo failed after retry"):
        mcu.echo("ping")


def test_echo_leaves_a_closed_port_closed(mcu_factory: Any, fake_smp: Any) -> None:
    mcu = mcu_factory({})
    mcu.close()
    mcu.echo("ping")
    assert not mcu._s.is_open
